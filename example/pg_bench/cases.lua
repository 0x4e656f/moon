local M = {}
local names={"tiny","point","mixed_rows","bytea","bytea_send","bytea_read","json_array","write","transaction","batch","hot_lane"}

--- Validate selections before opening any connection, and retain the expected report matrix.
function M.plan(cfg,profiles)
    local known,selected={},{}
    for _,name in ipairs(names) do known[name]=true end
    for _,name in ipairs(cfg.cases or names) do
        assert(known[name],"unknown config.cases entry: "..name); selected[name]=true
    end
    local minimum_ms=0
    for _,profile in ipairs(profiles) do
        profile.cases={}
        for _,name in ipairs(names) do
            if selected[name] and (name~="hot_lane" or profile.mode=="driver") then
                profile.cases[#profile.cases+1]=name
            end
        end
        assert(#profile.cases>0,"no applicable cases selected for "..profile.name)
        minimum_ms=minimum_ms+#profile.cases*#cfg.implementations*cfg.rounds*(cfg.min_duration_ms+cfg.warmup_duration_ms)
    end
    assert(minimum_ms<cfg.deadline,"deadline_ms is shorter than the minimum measurement + warmup plan")
    return profiles,minimum_ms
end

local function payload(cfg) return string.rep("\0\1\127\255abcd",math.ceil(cfg.bytes/8)):sub(1,cfg.bytes) end

function M.build(cfg, prefix, common, null)
    local function lane(worker) return (worker-1)%cfg.poolsize+1 end
    local function single(rows) common.equal(#rows,1,"expected exactly one row"); return rows[1] end
    local update="UPDATE "..prefix.."counters SET n=n+1 WHERE id=$1::bigint"
    local bytes=payload(cfg)
    local doc={id=123,name="中文 benchmark",enabled=true,missing=null,nested={1,2,3}}
    local ids={math.mininteger,0,math.maxinteger}
    local batch_sql,transactions={},{}
    for worker=1,cfg.concurrency do
        local statements={}
        for _=1,cfg.tx_size do
            statements[#statements+1]="UPDATE "..prefix.."counters SET n=n+1 WHERE id="..worker
        end
        batch_sql[worker]=table.concat(statements,";")
        transactions[worker]={}
        for i=1,cfg.tx_size do transactions[worker][i]={sql=update,params={worker}} end
    end
    return {
        {name="tiny",count=cfg.iterations,sql_per_request=1,
            request=function(api,i,w) return api:query("SELECT $1::bigint AS value",{i},lane(w)) end,
            check=function(rows,i) common.equal(single(rows).value,i,"tiny result mismatch") end},
        {name="point",count=cfg.iterations,sql_per_request=1,
            request=function(api,i,w)
                return api:query("SELECT id,score,enabled,label FROM "..prefix.."samples WHERE id=$1::bigint",
                    {(i-1)%cfg.data_rows+1},lane(w))
            end,
            check=function(rows,i)
                local r=single(rows); local id=(i-1)%cfg.data_rows+1
                common.equal(r.id,id); common.equal(r.score,id*7)
                common.equal(r.enabled,id%2==0); common.equal(r.label,"row-"..id)
            end},
        {name="mixed_rows",count=cfg.bulk_iterations,sql_per_request=1,rows_per_request=cfg.rows,
            check_fast=function(rows) common.equal(#rows,cfg.rows,"large result row count mismatch") end,
            request=function(api,_,w)
                return api:query("SELECT id,score,ratio,enabled,label,document,octets,ids,decimal_value::text AS decimal_value,"
                    .. "NULL::text AS absent FROM "..prefix.."samples WHERE id<=$1::bigint ORDER BY id",{cfg.rows},lane(w))
            end,
            check=function(rows)
                common.equal(#rows,cfg.rows,"large result row count mismatch")
                for i,r in ipairs(rows) do
                    common.equal(r.id,i); common.equal(r.score,i*7); common.equal(r.ratio,i*.5)
                    common.equal(r.enabled,i%2==0); common.equal(r.label,"row-"..i)
                    common.equal(r.document.i,i); common.equal(r.document.ok,true)
                    common.equal(r.octets,"\0\1\127\255"); common.equal(#r.ids,2)
                    common.equal(r.ids[1],i); common.equal(r.ids[2],-i)
                    common.equal(r.absent,null); common.equal(type(r.decimal_value),"string")
                    assert(tonumber(r.decimal_value)==i/8,"numeric text value mismatch")
                end
            end},
        {name="bytea",count=cfg.bulk_iterations,sql_per_request=1,bytes_sent=cfg.bytes,bytes_received=cfg.bytes,
            check_fast=function(rows) common.equal(#single(rows).payload,cfg.bytes,"bytea length mismatch") end,
            request=function(api,_,w) return api:query("SELECT $1::bytea AS payload",{api:bytes(bytes)},lane(w)) end,
            check=function(rows) common.equal(single(rows).payload,bytes,"bytea data corrupted") end},
        {name="bytea_send",count=cfg.bulk_iterations,sql_per_request=1,bytes_sent=cfg.bytes,
            request=function(api,_,w)
                return api:query("SELECT octet_length($1::bytea)::bigint AS size",{api:bytes(bytes)},lane(w))
            end,
            check=function(rows) common.equal(single(rows).size,cfg.bytes,"bytea send length mismatch") end},
        {name="bytea_read",count=cfg.bulk_iterations,sql_per_request=1,bytes_received=cfg.bytes,
            request=function(api,_,w)
                return api:query("SELECT payload FROM "..prefix.."binary_sample WHERE id=$1::bigint",{1},lane(w))
            end,
            check_fast=function(rows) common.equal(#single(rows).payload,cfg.bytes,"bytea length mismatch") end,
            check=function(rows) common.equal(single(rows).payload,bytes,"stored bytea data corrupted") end},
        {name="json_array",count=cfg.iterations,sql_per_request=1,
            request=function(api,_,w)
                return api:query("SELECT $1::jsonb AS document,$2::bigint[] AS ids",
                    {api:json(doc),api:array("int8",ids)},lane(w))
            end,
            check=function(rows)
                local r=single(rows)
                common.equal(r.document.id,doc.id); common.equal(r.document.name,doc.name)
                common.equal(r.document.enabled,true); common.equal(r.document.missing,null)
                common.equal(#r.document.nested,3); common.equal(r.document.nested[3],3)
                common.equal(#r.ids,#ids)
                for i,v in ipairs(ids) do common.equal(r.ids[i],v,"bigint array precision lost") end
            end},
        {name="write",count=cfg.iterations,sql_per_request=1,writes_per_request=1,
            request=function(api,_,w) return api:write(update,{w},lane(w)) end,
            check=function(affected) common.equal(affected,1,"write affected rows mismatch") end},
        {name="transaction",count=cfg.bulk_iterations,sql_per_request=cfg.tx_size,writes_per_request=cfg.tx_size,
            request=function(api,_,w)
                return api:transaction(transactions[w],lane(w))
            end,
            check=function(affected) common.equal(affected,cfg.tx_size,"transaction affected rows mismatch") end},
        {name="batch",count=cfg.bulk_iterations,sql_per_request=cfg.tx_size,writes_per_request=cfg.tx_size,
            request=function(api,_,w) return api:batch(batch_sql[w],lane(w)) end,
            check=function(affected) common.equal(affected,cfg.tx_size,"batch affected rows mismatch") end},
        {name="hot_lane",count=cfg.iterations,sql_per_request=1,driver_only=true,
            request=function(api,i) return api:query("SELECT $1::bigint AS value",{i},1) end,
            check=function(rows,i) common.equal(single(rows).value,i) end},
    }
end

function M.setup(api,cfg,prefix)
    api:write("CREATE TABLE "..prefix.."samples (id bigint PRIMARY KEY,score bigint,ratio double precision,enabled boolean,"
        .."label text,document jsonb,octets bytea,ids bigint[],decimal_value numeric)")
    api:write("INSERT INTO "..prefix.."samples SELECT i,i*7,i*.5,(i%2=0),'row-'||i,"
        .."jsonb_build_object('i',i,'ok',true),decode('00017fff','hex'),ARRAY[i,-i],i::numeric/8"
        .." FROM generate_series(1,$1::bigint) i",{cfg.data_rows})
    api:write("CREATE TABLE "..prefix.."counters (id bigint PRIMARY KEY,n bigint NOT NULL)")
    api:write("INSERT INTO "..prefix.."counters SELECT i,0 FROM generate_series(1,$1::bigint) i",{cfg.concurrency})
    api:write("CREATE TABLE "..prefix.."binary_sample (id bigint PRIMARY KEY,payload bytea NOT NULL)")
    api:write("INSERT INTO "..prefix.."binary_sample VALUES (1,$1::bytea)",{api:bytes(payload(cfg))})
    api:write("ANALYZE "..prefix.."samples")
    api:write("ANALYZE "..prefix.."counters")
    api:write("ANALYZE "..prefix.."binary_sample")
end
function M.reset(api,cfg,prefix)
    -- No TRUNCATE/DDL here: preserve warmed server plans across reset and measurement.
    local affected=api:write("UPDATE "..prefix.."counters SET n=0")
    assert(affected==cfg.concurrency,"counter reset row count mismatch")
end
function M.check_writes(api,prefix,expected,common,workers,writes_per_request)
    if workers then
        local rows=api:query("SELECT id,n FROM "..prefix.."counters ORDER BY id")
        common.equal(#rows,#workers,"counter row count mismatch")
        for w,n in ipairs(workers) do
            common.equal(rows[w].id,w,"counter worker mismatch")
            common.equal(rows[w].n,n*writes_per_request,"persisted per-worker counter mismatch")
        end
    end
    local rows=api:query("SELECT COALESCE(SUM(n),0)::bigint AS n FROM "..prefix.."counters")
    common.equal(rows[1].n,expected,"final persisted counter does not match acknowledged writes")
end
function M.fifo(api,moon,cfg,prefix,common)
    -- The caller resets counters through the separate admin connection before this probe.
    local count=math.max(cfg.concurrency,math.min(100,cfg.iterations))
    local result=common.run(moon,count,cfg.concurrency,function(i)
        return api:query("UPDATE "..prefix.."counters SET n=$1::bigint WHERE id=1 AND n=$1::bigint-1 RETURNING n",{i},1)
    end,function(rows,i)
        common.equal(#rows,1,"same-key FIFO broken (conditional update skipped)")
        common.equal(rows[1].n,i,"same-key FIFO broken")
    end)
    assert(not result.error,result.error)
    M.check_writes(api,prefix,count,common)
end
return M
