-- Data for test_sqlx_pg.lua. SQL fragments below are test constants, never user input.
-- A field test checks stored data, SQL NULL, and a bound-parameter round trip.
return function(sqlx, null)
    local uuid = "a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11"
    local binary = string.char(0, 1, 39, 92, 127, 128, 255)
    local object = { name = "中文", active = false, nested = { 1, null, "three" } }
    local fields = {}
    local function field(name, sql_type, literal, expected, param, bind, epsilon)
        fields[#fields + 1] = {
            name = name, sql_type = sql_type, literal = literal, expected = expected,
            param = param, bind = bind, epsilon = epsilon,
        }
    end
    -- Lua integers bind as INT8 and Lua non-integer numbers as FLOAT8. Explicit
    -- intermediate casts keep PostgreSQL's binary parameter format unambiguous.
    field("int2", "INT2", "-32768", -32768, 32767, "$1::INT8::INT2")
    field("smallint", "SMALLINT", "32767", 32767, -32768, "$1::INT8::SMALLINT")
    field("int4", "INT4", "-2147483648", -2147483648, 2147483647, "$1::INT8::INT4")
    field("integer", "INTEGER", "2147483647", 2147483647, -2147483648, "$1::INT8::INTEGER")
    field("int8", "INT8", "-9223372036854775808", math.mininteger, math.maxinteger, "$1::INT8")
    field("bigint", "BIGINT", "9223372036854775807", math.maxinteger, math.mininteger, "$1::INT8")
    field("float4", "FLOAT4", "3.1415927", 3.1415927, -0.125, "$1::FLOAT8::FLOAT4", 1e-6)
    field("real", "REAL", "-123.25", -123.25, 0.125, "$1::FLOAT8::REAL", 1e-6)
    field("float8", "FLOAT8", "3.141592653589793", math.pi, -1.23456789012345, "$1::FLOAT8", 1e-14)
    field("double_precision", "DOUBLE PRECISION", "1.23456789012345", 1.23456789012345,
        2.718281828459045, "$1::FLOAT8", 1e-14)
    field("bool", "BOOL", "TRUE", true, false, "$1::BOOL")
    field("boolean", "BOOLEAN", "FALSE", false, true, "$1::BOOL")
    field("text", "TEXT", "'中文 ''quote'' [not json]'", "中文 'quote' [not json]",
        "{not json}", "$1::TEXT")
    field("varchar", "VARCHAR(100)", "'varchar 中文'", "varchar 中文", "", "$1::TEXT::VARCHAR(100)")
    field("char", "CHAR(8)", "'char'", "char    ", "12345678", "$1::TEXT::CHAR(8)")
    field("bpchar", "BPCHAR(8)", "'bpchar'", "bpchar  ", "abcdefgh", "$1::TEXT::BPCHAR(8)")
    field("name", "NAME", "'sqlx_name'", "sqlx_name", "bound_name", "$1::TEXT::NAME")
    field("bytea", "BYTEA", "decode('0001275c7f80ff', 'hex')", binary, sqlx.bytes(binary), "$1::BYTEA")
    field("date", "DATE", "'2024-02-29'", "2024-02-29", "2024-02-29", "$1::TEXT::DATE")
    field("time", "TIME(6)", "'23:59:59.123456'", "23:59:59.123456",
        "23:59:59.123456", "$1::TEXT::TIME(6)")
    field("timestamp", "TIMESTAMP(6)", "'2024-02-29 23:59:59.123456'", "2024-02-29 23:59:59.123456",
        "2024-02-29 23:59:59.123456", "$1::TEXT::TIMESTAMP(6)")
    field("timestamptz", "TIMESTAMPTZ(6)", "'2024-03-01 07:59:59.123456+08'",
        "2024-02-29T23:59:59.123456Z", "2024-02-29T23:59:59.123456Z", "$1::TEXT::TIMESTAMPTZ(6)")
    field("timetz", "TIMETZ(6)", "'12:34:56.123456-03:30'", "12:34:56.123456-03:30",
        "12:34:56.123456-03:30", "$1::TEXT::TIMETZ(6)")
    field("uuid", "UUID", "'" .. uuid .. "'", uuid, uuid, "$1::TEXT::UUID")
    local json_literal = [['{"name":"中文","active":false,"nested":[1,null,"three"]}']]
    field("json", "JSON", json_literal, object, sqlx.json(object), "$1::JSONB::JSON")
    field("jsonb", "JSONB", json_literal, object, sqlx.json(object), "$1::JSONB")

    local arrays = {
        { "bool", "BOOL[]", { true, null, false } },
        { "int2", "INT2[]", { -32768, null, 32767 } },
        { "int4", "INT4[]", { -2147483648, null, 2147483647 } },
        { "int8", "INT8[]", { math.mininteger, null, math.maxinteger } },
        { "float4", "FLOAT4[]", { -1.25, null, 3.1415927 }, 1e-6 },
        { "float8", "FLOAT8[]", { -math.pi, null, 1.23456789012345 }, 1e-14 },
        { "text", "TEXT[]", { "", null, "中文", "{literal}" } },
        { "varchar", "VARCHAR[]", { "varchar", null, "" }, nil, "$1::TEXT[]::VARCHAR[]" },
        { "name", "NAME[]", { "one", null, "two" }, nil, "$1::TEXT[]::NAME[]" },
        { "bytea", "BYTEA[]", { binary, null, "" } },
        { "uuid", "UUID[]", { uuid, null, "00000000-0000-0000-0000-000000000000" } },
        { "json", "JSON[]", { object, null, false, "string", 1.25 }, nil, "$1::JSONB[]::JSON[]" },
        { "jsonb", "JSONB[]", { object, null, false, "string", 1.25 } },
    }
    -- These are CAST-to-TEXT tests, NOT claims of native typed decoding support.
    -- PostgreSQL extensions (PostGIS etc.) and user-defined types are not enumerated.
    local text_only = {
        { "numeric", "NUMERIC(38,10)", "'12345678901234567890.1234567890'" },
        { "decimal", "DECIMAL(20,4)", "'-1234567890123456.7890'" },
        { "money", "MONEY", "12.34" },
        { "interval", "INTERVAL", "'2 days 03:04:05.123456'" },
        { "bit", "BIT(5)", "B'10101'" },
        { "varbit", "VARBIT", "B'101001'" },
        { "inet", "INET", "'2001:db8::1/64'" },
        { "cidr", "CIDR", "'192.168.0.0/24'" },
        { "macaddr", "MACADDR", "'08:00:2b:01:02:03'" },
        { "macaddr8", "MACADDR8", "'08:00:2b:01:02:03:04:05'" },
        { "point", "POINT", "'(1.5,2.5)'" },
        { "line", "LINE", "'{1,2,3}'" },
        { "lseg", "LSEG", "'[(1,2),(3,4)]'" },
        { "box", "BOX", "'(3,4),(1,2)'" },
        { "path", "PATH", "'[(1,2),(3,4)]'" },
        { "polygon", "POLYGON", "'((0,0),(1,0),(1,1))'" },
        { "circle", "CIRCLE", "'<(1,2),3>'" },
        { "int4range", "INT4RANGE", "'[1,10)'" },
        { "int8range", "INT8RANGE", "'[1,9223372036854775807)'" },
        { "numrange", "NUMRANGE", "'[1.25,2.75)'" },
        { "daterange", "DATERANGE", "'[2024-01-01,2025-01-01)'" },
        { "tsrange", "TSRANGE", "'[2024-01-01 00:00:00,2025-01-01 00:00:00)'" },
        { "tstzrange", "TSTZRANGE", "'[2024-01-01 00:00:00+00,2025-01-01 00:00:00+00)'" },
        { "int4multirange", "INT4MULTIRANGE", "'{[1,3),[5,9)}'" },
        { "int8multirange", "INT8MULTIRANGE", "'{[1,3),[5,9)}'" },
        { "nummultirange", "NUMMULTIRANGE", "'{[1.25,2.75)}'" },
        { "datemultirange", "DATEMULTIRANGE", "'{[2024-01-01,2025-01-01)}'" },
        { "tsmultirange", "TSMULTIRANGE", "'{[2024-01-01 00:00:00,2025-01-01 00:00:00)}'" },
        { "tstzmultirange", "TSTZMULTIRANGE", "'{[2024-01-01 00:00:00+00,2025-01-01 00:00:00+00)}'" },
        { "xml", "XML", "'<root><v>中文</v></root>'" },
        { "tsvector", "TSVECTOR", "'''cat'':1 ''dog'':2'" },
        { "tsquery", "TSQUERY", "'''cat'' & ''dog'''" },
        { "oid", "OID", "'12345'" },
        { "pg_lsn", "PG_LSN", "'0/16B6C50'" },
        { "date_array", "DATE[]", "ARRAY['2024-02-29'::DATE, NULL]" },
        { "timestamp_array", "TIMESTAMP[]", "ARRAY['2024-02-29 12:00:00'::TIMESTAMP, NULL]" },
        { "numeric_array", "NUMERIC[]", "ARRAY[1.25::NUMERIC, NULL]" },
        { "bpchar_array", "CHAR(3)[]", "ARRAY['abc'::CHAR(3), NULL]" },
    }
    return { fields = fields, arrays = arrays, text_only = text_only, binary = binary, uuid = uuid }
end
