-- PG 14+ statistics; read-only, no extension, RESET, ALTER SYSTEM or superuser required.
-- Monitor queries use a separate connection and only own load backend PIDs for waits.
local M={}
function M.environment(api)
    return api:query([[SELECT jsonb_build_object(
        'version',current_setting('server_version_num'),
        'server_addr',inet_server_addr()::text,'server_port',inet_server_port(),
        'fsync',current_setting('fsync'),'synchronous_commit',current_setting('synchronous_commit'),
        'full_page_writes',current_setting('full_page_writes'),
        'track_activities',current_setting('track_activities'),'track_counts',current_setting('track_counts'),
        'track_io_timing',current_setting('track_io_timing'),
        'shared_buffers',current_setting('shared_buffers'),'max_connections',current_setting('max_connections')) AS data]])[1].data
end
function M.snapshot(api,schema,pids,version)
    local ids={}
    for _,pid in ipairs(pids) do
        assert(math.type(pid)=="integer" and pid>0,"invalid backend PID")
        ids[#ids+1]=tostring(pid)
    end
    local sql=[[SELECT jsonb_build_object(
        'database',(SELECT to_jsonb(d) FROM pg_stat_database d WHERE datname=current_database()),
        'waits',COALESCE((SELECT jsonb_agg(jsonb_build_object('pid',pid,'state',state,
            'wait_event_type',wait_event_type,'wait_event',wait_event))
            FROM pg_stat_activity WHERE pid IN (]]..(#ids>0 and table.concat(ids,",") or "0")..[[)), '[]'::jsonb),
        'tables',COALESCE((SELECT jsonb_agg(jsonb_build_object('name',relname,'live',n_live_tup,'dead',n_dead_tup,
            'updates',n_tup_upd,'hot_updates',n_tup_hot_upd,'autovacuum_count',autovacuum_count))
            FROM pg_stat_user_tables WHERE schemaname=$1::text),'[]'::jsonb),
        'bgwriter',(SELECT to_jsonb(b) FROM pg_stat_bgwriter b)]]
    if version>=140000 then sql=sql..",'wal',(SELECT to_jsonb(w) FROM pg_stat_wal w)" end
    if version>=170000 then sql=sql..",'checkpointer',(SELECT to_jsonb(c) FROM pg_stat_checkpointer c)" end
    return api:query(sql..") AS data",{schema})[1].data
end
return M
