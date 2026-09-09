-- Benchmark-only normalization of the two existing public APIs. Production modules stay unchanged.
local M = {}

function M.open(moon, common, cfg, implementation, mode, root, tag)
    local api={implementation=implementation,mode=mode,connections={}}
    local module=implementation=="libpq" and require("moon.db.libpq") or require("ext.sqlx")
    local client
    if mode=="driver" then
        client=require(implementation=="libpq" and "libpq_sqldriver.client" or "lrust_sqldriver.client")
    end
    local options={host=cfg.host,port=cfg.port,dbname=cfg.database,user=cfg.user,password=cfg.password,
        sslmode=cfg.sslmode,sslrootcert=cfg.sslrootcert,sslcert=cfg.sslcert,sslkey=cfg.sslkey,
        options=cfg.options,application_name="moon_pg_benchmark",timeout=cfg.timeout,
        max_rows=math.max(cfg.rows,cfg.concurrency)+100,max_result_bytes=0,statement_cache_capacity=cfg.cache,
        library=cfg.library or (package.config:sub(1,1)=="\\" and root.."/clib/libpq/libpq.dll" or nil)}
    local rust_options={connect_timeout=cfg.timeout,request_timeout=cfg.timeout,
        max_rows=options.max_rows,queue_capacity=math.max(100,cfg.concurrency+1)}

    function api:query(sql, params, lane)
        params=params or {}; lane=lane or 1
        local result
        if implementation=="libpq" then
            if mode=="driver" then result=client.query(self.service,sql,params,lane-1)
            else result=self.connections[lane]:query(sql,params) end
            return common.ok(result).rows
        end
        if mode=="driver" then
            result=client.query_params_on(self.service,lane-1,sql,table.unpack(params))
            return common.ok(result).data
        end
        return common.ok(self.connections[lane]:query(sql,table.unpack(params)))
    end
    function api:write(sql, params, lane)
        params=params or {}; lane=lane or 1
        local result
        if implementation=="libpq" then
            -- libpq client.execute is fire-and-forget: never benchmark it as a completed write.
            if mode=="driver" then result=client.query(self.service,sql,params,lane-1)
            else result=self.connections[lane]:execute(sql,params) end
        elseif mode=="driver" then
            result=client.execute_params_wait_on(self.service,lane-1,sql,table.unpack(params))
        else result=self.connections[lane]:execute_wait(sql,table.unpack(params)) end
        return common.ok(result).rows_affected
    end
    function api:transaction(statements, lane)
        lane=lane or 1
        local result
        if implementation=="libpq" then
            if mode=="driver" then result=client.transaction(self.service,statements,lane-1)
            else result=self.connections[lane]:transaction(statements) end
            local affected=0
            for _, r in ipairs(common.ok(result).results) do affected=affected+r.rows_affected end
            return affected
        end
        local packed={}
        for i,s in ipairs(statements) do packed[i]={s.sql,table.unpack(s.params or {})} end
        if mode=="driver" then result=client.transaction_on(self.service,lane-1,packed)
        else result=self.connections[lane]:transaction(packed) end
        return common.ok(result).rows_affected
    end
    function api:batch(sql,lane)
        lane=lane or 1
        local result
        if mode=="driver" then
            if implementation=="libpq" then result=client.batch(self.service,sql,lane-1)
            else result=client.batch_on(self.service,lane-1,sql) end
        else result=self.connections[lane]:batch(sql) end
        common.ok(result)
        if implementation=="sqlx" then return result.rows_affected end
        local affected=0; for _, r in ipairs(result.results) do affected=affected+r.rows_affected end
        return affected
    end
    function api:bytes(value)
        local t=client or module
        return implementation=="libpq" and t.bytea(value) or t.bytes(value)
    end
    function api:json(value)
        local t=client or module
        return implementation=="libpq" and t.jsonb(value) or t.json(value)
    end
    function api:array(kind,value) return (client or module).array(kind,value) end

    function api:close()
        if self.service then
            if implementation=="libpq" then
                assert(common.ok(client.save_then_quit(self.service)).closed==true,"libpq driver did not acknowledge shutdown")
            else client.save_then_quit(self.service) end
            -- Rust's shutdown API has no acknowledgment; confirm actual service destruction.
            -- queryservice(name) is not used: this framework retains unique-name registrations.
            local deadline=moon.clock()+cfg.timeout/1000+5
            while true do
                local raw=moon.scan_services(cfg.driver_thread)
                assert(type(raw)=="string","could not confirm benchmark driver shutdown")
                local alive=false
                for _, s in ipairs(raw~="" and require("json").decode(raw) or {}) do
                    if tonumber(s.serviceid,16)==self.service then alive=true; break end
                end
                if not alive then break end
                assert(moon.clock()<deadline,"benchmark driver did not finish shutdown")
                moon.sleep(20)
            end
            self.service=nil
        end
        for i,db in pairs(self.connections) do
            local closed,err=db:close()
            assert(closed==true or implementation=="libpq", type(err)=="table" and err.message or "connection close failed")
            self.connections[i]=nil
        end
    end

    local ok,err=pcall(function()
        if mode=="driver" then
            local conf={name=tag.."_"..implementation,file=root.."/service/"..
                (implementation=="libpq" and "libpq_sqldriver.lua" or "lrust_sqldriver.lua"),
                threadid=cfg.driver_thread,poolsize=cfg.poolsize,max_queue=0}
            if implementation=="libpq" then conf.opts=options
            else
                conf.url=cfg.url; conf.opts=rust_options; conf.eager_connect=false
            end
            local service=moon.new_service(conf)
            assert(service and service>0,"benchmark driver creation failed; inspect Moon startup log")
            api.service=service
        else
            for i=1,cfg.poolsize do
                if implementation=="libpq" then api.connections[i]=common.ok(module.connect(options))
                else
                    local db,why=module.try_connect(cfg.url,tag.."_sqlx_"..i,rust_options)
                    assert(db,type(why)=="table" and why.message or "SQLx connect failed")
                    api.connections[i]=db
                end
            end
        end
    end)
    if not ok then pcall(api.close,api); error(err,0) end
    return api
end
return M
