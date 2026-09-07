local moon = require("moon")
local dbclient = require("lrust_sqldriver")

local startup = ...
local database_url = type(startup) == "table" and startup.url or os.getenv("DATABASE_URL")
assert(database_url,
    "set DATABASE_URL or start with { url = 'postgres://user:password@host/database' }")

local db = moon.new_service {
    unique = true,
    name = "db_lrust_example",
    file = "lrust_sqldriver.lua",
    threadid = 2,
    url = database_url,
    poolsize = 4,
    max_queue = 1000,
    request_timeout = 30000,
    max_rows = 100000,
}

assert(db > 0)

moon.async(function()
    -- No ordering requirement: pick the least-loaded lane.
    local health = dbclient.query_any(db, "SELECT 1 AS value")
    assert(not health.code, health.message)
    print_r(health)

    -- Requests with the same affinity key always use the same FIFO lane.
    local user_id = 233
    local user = dbclient.query_params_on(
        db,
        user_id,
        "SELECT $1::BIGINT AS user_id",
        user_id)
    assert(not user.code, user.message)
    print_r(user)

    local transaction = dbclient.transaction_on(db, user_id, {
        { "SELECT $1::BIGINT", user_id },
        { "SELECT $1::TEXT", "serialized" },
    })
    assert(not transaction.code, transaction.message)

    print_r(dbclient.stats(db))
    dbclient.save_then_quit(db)
end)
