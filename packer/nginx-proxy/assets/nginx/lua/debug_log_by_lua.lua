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
        'lua="debug-log"',
        ' event="session_summary"',
        ' phase=', q(ngx.get_phase()),
        ' client=', q(ngx.var.remote_addr or ""),
        ' client_sni=', q(ngx.var.client_sni or ""),
        ' dst_ip=', q(ngx.var.dst_ip or ""),
        ' resolved_ips=', q(ngx.var.resolved_ips or ""),
        ' original_dst=', q(ngx.var.original_dst or ""),
        ' status=', q(ngx.var.status or ""),
        ' proxy_decision=', q(ngx.var.proxy_decision or ""))
