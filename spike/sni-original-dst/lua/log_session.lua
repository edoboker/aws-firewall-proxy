-- log_session.lua
--
-- Emits a per-session Lua log line even if preread_by_lua did not run.
-- This gives us a reliable place to inspect final stream variables while
-- debugging the preread path.

local function q(value)
    if value == nil then
        return '""'
    end

    return string.format("%q", tostring(value))
end

ngx.log(ngx.WARN,
        'spike_lua="log_session"',
        ' phase=', q(ngx.get_phase()),
        ' client=', q(ngx.var.remote_addr or ""),
        ' sni=', q(ngx.var.ssl_preread_server_name or ""),
        ' spike_sni=', q(ngx.var.spike_sni or ""),
        ' spike_sni_source=', q(ngx.var.spike_sni_source or ""),
        ' spike_dst_ip=', q(ngx.var.spike_dst_ip or ""),
        ' spike_resolved=', q(ngx.var.spike_resolved or ""),
        ' original_dst=', q(ngx.var.original_dst or ""),
        ' status=', q(ngx.var.status or ""),
        ' spike_decision=', q(ngx.var.spike_decision or ""),
        ' spike_trace=', q(ngx.var.spike_trace or ""),
        ' ctx_trace=', q(ngx.ctx.spike_trace or ""))
