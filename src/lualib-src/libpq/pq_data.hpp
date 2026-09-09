#pragma once
#include "libpq/include/libpq-fe.h"
#include <cctype>
#include <limits>
#include <optional>
#include <stdexcept>
#include <string>
#include <string_view>
#include <vector>

namespace moon::pq {
struct error {
    std::string code, message, sqlstate, detail, hint, constraint, table;
    bool connect_failed = false;
    size_t statement_index = 0;
};
struct parameter {
    Oid oid = 0;
    int format = 0;
    std::optional<std::string> value;
};
struct statement {
    std::string sql;
    std::vector<parameter> params;
};
struct column {
    std::string name;
    Oid oid = 0;
};
struct cell {
    size_t offset = 0;
    size_t length = (std::numeric_limits<size_t>::max)();
    bool is_null() const {
        return length == (std::numeric_limits<size_t>::max)();
    }
};
// Keep metadata once and compact field bytes, not one heavyweight PGresult per row.
// No Lua state is retained by the asynchronous engine.
struct result_set {
    std::vector<column> columns;
    std::vector<cell> cells;
    std::string data, command, affected;
    size_t row_count = 0;
    std::string_view value(const cell& c) const {
        return { data.data() + c.offset, c.length };
    }
};

// Used for transaction ownership and conservative automatic statement caching.
inline std::string sql_keyword(std::string_view sql) {
    size_t i = 0;
    while (i < sql.size()) {
        if (std::isspace(static_cast<unsigned char>(sql[i]))) {
            ++i;
            continue;
        }
        if (sql.substr(i, 2) == "--") {
            auto end = sql.find('\n', i + 2);
            i = end == sql.npos ? sql.size() : end + 1;
        } else if (sql.substr(i, 2) == "/*") {
            size_t depth = 1;
            i += 2;
            while (i < sql.size() && depth) {
                if (sql.substr(i, 2) == "/*") {
                    ++depth;
                    i += 2;
                } else if (sql.substr(i, 2) == "*/") {
                    --depth;
                    i += 2;
                } else
                    ++i;
            }
            if (depth)
                throw std::runtime_error("unterminated SQL comment");
        } else
            break;
    }
    std::string word;
    while (i < sql.size() && std::isalpha(static_cast<unsigned char>(sql[i])))
        word.push_back(static_cast<char>(std::toupper(static_cast<unsigned char>(sql[i++]))));
    return word;
}
inline void validate_transaction_sql(std::string_view sql) {
    const auto word = sql_keyword(sql);
    for (auto forbidden: { "BEGIN",
                           "START",
                           "COMMIT",
                           "END",
                           "ROLLBACK",
                           "ABORT",
                           "SAVEPOINT",
                           "RELEASE",
                           "PREPARE" })
        if (word == forbidden)
            throw std::runtime_error("transaction control SQL is owned by transaction()");
}
inline bool cacheable_sql(std::string_view sql) {
    const auto word = sql_keyword(sql);
    return word == "SELECT" || word == "INSERT" || word == "UPDATE" || word == "DELETE"
        || word == "WITH" || word == "VALUES" || word == "MERGE";
}
inline std::string statement_key(const statement& s) {
    auto key = s.sql;
    key.push_back('\0');
    for (const auto& p: s.params)
        for (int shift = 24; shift >= 0; shift -= 8)
            key.push_back(static_cast<char>(p.oid >> shift));
    return key;
}
} // namespace moon::pq
