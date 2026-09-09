-- 独立的 libpq 服务入口。业务只 require("libpq_sqldriver.client")。
local moon = require("moon")
local pg = require("moon.db.libpq")
local conf = ...
assert(type(conf) == "table" and type(conf.opts) == "table", "libpq_sqldriver requires opts")

---@class LibpqDriverConfig : service_params
---@field opts LibpqOptions 连接配置，每条 lane 维护一个独立连接，按需建立
---@field poolsize? integer 固定队列/连接上限，默认 1
---@field max_queue? integer 每条 lane 等待队列上限，0 不限；默认 0，由业务决定容量
---@field reconnect_delay? integer 连续连接失败后的退避毫秒数，默认 1000

local function nonnegative(n)
    assert(math.type(n) == "integer" and n >= 0, "expected nonnegative integer")
    return n
end
local count = nonnegative(conf.poolsize or 1)
assert(count > 0 and count <= 1024, "poolsize must be between 1 and 1024")
local max_queue = nonnegative(conf.max_queue or 0)
local reconnect_delay = nonnegative(conf.reconnect_delay or 1000)
local lanes, accepting, stopping, round = {}, true, false, 0
for i = 1, count do lanes[i] = { queue={}, head=1, tail=0, running=false, db=nil, retry_at=0 } end

local function reply(sender, session, result)
    if session == 0 then
        if result.code then moon.error("libpq_sqldriver", result.code, result.sqlstate or "") end
        return
    end
    local ok = pcall(moon.response, "lua", sender, session, result)
    if not ok then
        -- Large/unsupported serialized results must not terminate the queue worker.
        pcall(moon.response, "lua", sender, session, {code="RESPONSE", message="could not serialize libpq result"})
    end
end

local function choose(key)
    if key == false then
        local best, load
        for offset = 1, count do
            local index = (round + offset - 1) % count + 1
            local lane = lanes[index]
            local n = lane.tail - lane.head + 1 + (lane.running and 1 or 0)
            if not load or n < load then best, load = index, n end
        end
        round = best
        return lanes[best]
    end
    local hash
    if math.type(key) == "integer" then hash = key
    elseif type(key) == "string" then
        hash = 5381
        for i = 1, #key do hash = (hash * 33 + key:byte(i)) & 0xffffffff end
    else return nil end
    return lanes[hash % count + 1]
end

local function discard(lane)
    if lane.db then pcall(lane.db.close, lane.db); lane.db = nil end
end

local function run(lane, request)
    if lane.db and not lane.db:connected() then discard(lane) end
    if not lane.db then
        if moon.clock() < lane.retry_at then
            return {code="CONNECT_BACKOFF", message="previous connect failed; retry later", connect_failed=true}
        end
        local db = pg.connect(conf.opts)
        if db.code then lane.retry_at = moon.clock() + reconnect_delay/1000; return db end
        lane.db = db
        lane.retry_at = 0
    end
    local result = lane.db[request.op](lane.db, table.unpack(request.args, 1, request.args.n))
    if not lane.db:connected() then discard(lane) end
    -- Deliberately no retry here: a disconnected write may already have committed.
    return result
end

local function enqueue(sender, session, op, key, ...)
    if not accepting then reply(sender, session, {code="CLOSING", message="driver is draining"}); return end
    local lane = choose(key)
    if not lane then reply(sender, session, {code="INVALID", message="lane key must be integer, string or false"}); return end
    if max_queue > 0 and lane.tail - lane.head + 1 >= max_queue then
        reply(sender, session, {code="QUEUE_FULL", message="lane waiting queue is full"}); return
    end
    lane.tail = lane.tail + 1
    lane.queue[lane.tail] = {sender=sender, session=session, op=op, args=table.pack(...)}
    if lane.running then return end
    lane.running = true
    moon.async(function()
        while lane.head <= lane.tail do
            local request = lane.queue[lane.head]
            lane.queue[lane.head] = nil; lane.head = lane.head + 1
            local ok, result = pcall(run, lane, request)
            if not ok then
                discard(lane)
                result = {code="ERROR", message="driver request failed unexpectedly"}
                moon.error("libpq_sqldriver request failed")
            end
            reply(request.sender, request.session, result)
        end
        lane.head, lane.tail, lane.running = 1, 0, false
    end)
end

local function stop(sender, session)
    if stopping then reply(sender, session, {code="CLOSING", message="driver is already draining"}); return end
    stopping, accepting = true, false
    moon.async(function()
        while true do
            local busy = false
            for _, lane in ipairs(lanes) do
                if lane.running or lane.head <= lane.tail then busy = true; break end
            end
            if not busy then break end
            moon.sleep(10)
        end
        for _, lane in ipairs(lanes) do discard(lane) end
        reply(sender, session, {closed=true})
        moon.quit()
    end)
end

local operations = {query=true, execute=true, batch=true, transaction=true}
moon.dispatch("lua", function(sender, session, op, ...)
    if operations[op] then enqueue(sender, session, op, ...)
    elseif op == "stats" then
        local result = {accepting=accepting, lanes={}}
        for i, lane in ipairs(lanes) do
            result.lanes[i] = {waiting=lane.tail-lane.head+1, running=lane.running,
                connected=lane.db ~= nil and lane.db:connected()}
        end
        reply(sender, session, result)
    elseif op == "save_then_quit" then stop(sender, session)
    else reply(sender, session, {code="INVALID", message="unknown libpq driver operation"}) end
end)
moon.shutdown(function() stop(0, 0) end)
