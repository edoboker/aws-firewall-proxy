-- debug_log_by_lua.lua
--
-- Debug-only hook. Uncomment the corresponding log_by_lua_file directive in
-- nginx.conf when you want one extra per-session summary line.

local function q(value)
    if value == nil then
        return '""'
    end

    return string.format("%q", tostring(value))
end

ngx.log(ngx.NOTICE,
        'spike_lua="debug_log_by_lua"',
        ' event="session_summary"',
        ' phase=', q(ngx.get_phase()),
        ' client=', q(ngx.var.remote_addr or ""),
        ' spike_sni=', q(ngx.var.spike_sni or ""),
        ' spike_dst_ip=', q(ngx.var.spike_dst_ip or ""),
        ' spike_resolved=', q(ngx.var.spike_resolved or ""),
        ' original_dst=', q(ngx.var.original_dst or ""),
        ' status=', q(ngx.var.status or ""),
        ' spike_decision=', q(ngx.var.spike_decision or ""))
