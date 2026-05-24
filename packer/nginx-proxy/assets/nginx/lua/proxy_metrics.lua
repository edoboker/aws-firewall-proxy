local _M = {}

local dict = ngx.shared.proxy_metrics
local statsd_host = "127.0.0.1"
local statsd_port = 8125
local default_interval = 60

local histogram_specs = {
    ProxyDecisionLatencyMs = {
        buckets = {0.5, 1, 2, 5, 10, 25, 50, 100, 250, 500, 1000, 2500, 5000},
    },
    UpstreamConnectLatencyMs = {
        buckets = {1, 5, 10, 25, 50, 100, 250, 500, 1000, 2500, 5000, 10000},
    },
}

local function publish_interval()
    local value = tonumber(os.getenv("METRICS_PUBLISH_INTERVAL_SECONDS"))
    if not value or value < 10 then
        return default_interval
    end

    return math.floor(value)
end

local function current_window(now)
    return math.floor((now or ngx.now()) / publish_interval())
end

local function counter_key(window_id, name)
    return string.format("counter:%d:%s", window_id, name)
end

local function histogram_bucket_key(window_id, name, bucket)
    return string.format("hist:%d:%s:%s", window_id, name, bucket)
end

local function histogram_count_key(window_id, name)
    return string.format("histcount:%d:%s", window_id, name)
end

local function histogram_max_key(window_id, name)
    return string.format("histmax:%d:%s", window_id, name)
end

local function ensure_counter(key, delta)
    local ok, err = dict:incr(key, delta, 0)
    if not ok then
        ngx.log(ngx.ERR, 'lua="proxy-metrics" event="dict_incr_failed" key=', key, ' err=', tostring(err))
    end
end

local function set_gauge(key, value)
    local ok, err = dict:set(key, value)
    if not ok then
        ngx.log(ngx.ERR, 'lua="proxy-metrics" event="dict_set_failed" key=', key, ' err=', tostring(err))
    end
end

local function update_max(key, value)
    local current = dict:get(key)
    if not current or value > current then
        set_gauge(key, value)
    end
end

local function active_connections_key()
    return "gauge:active_connections"
end

local function increment_counter(name, delta)
    ensure_counter(counter_key(current_window(), name), delta or 1)
end

local function classify_reason_metric(reason)
    if reason == "sni_mismatch" then
        increment_counter("SniMismatchCount", 1)
    elseif reason == "dns_failure" then
        increment_counter("DnsResolutionFailureCount", 1)
    elseif reason == "internal_error" then
        increment_counter("InternalFailureCount", 1)
    end
end

local function observe_histogram(name, milliseconds)
    if not milliseconds or milliseconds < 0 then
        return
    end

    local spec = histogram_specs[name]
    if not spec then
        return
    end

    local window_id = current_window()
    local bucket_label = "inf"

    for _, bucket in ipairs(spec.buckets) do
        if milliseconds <= bucket then
            bucket_label = tostring(bucket)
            break
        end
    end

    ensure_counter(histogram_bucket_key(window_id, name, bucket_label), 1)
    ensure_counter(histogram_count_key(window_id, name), 1)
    update_max(histogram_max_key(window_id, name), milliseconds)
end

local function parse_first_number(raw_value)
    if not raw_value or raw_value == "" or raw_value == "-" then
        return nil
    end

    local token = tostring(raw_value):match("([^,]+)")
    local value = tonumber(token)
    if not value then
        return nil
    end

    return value
end

local function percentile_from_histogram(window_id, name, quantile)
    local spec = histogram_specs[name]
    if not spec then
        return nil
    end

    local total = tonumber(dict:get(histogram_count_key(window_id, name)) or 0)
    if total <= 0 then
        return nil
    end

    local target = total * quantile
    local running = 0

    for _, bucket in ipairs(spec.buckets) do
        running = running + tonumber(dict:get(histogram_bucket_key(window_id, name, tostring(bucket))) or 0)
        if running >= target then
            return bucket
        end
    end

    return tonumber(dict:get(histogram_max_key(window_id, name)))
end

local function emit_statsd_lines(lines)
    if #lines == 0 then
        return
    end

    local sock, err = ngx.socket.udp()
    if not sock then
        ngx.log(ngx.ERR, 'lua="proxy-metrics" event="udp_socket_failed" err=', tostring(err))
        return
    end

    local ok, setpeer_err = sock:setpeername(statsd_host, statsd_port)
    if not ok then
        ngx.log(ngx.ERR, 'lua="proxy-metrics" event="udp_setpeer_failed" err=', tostring(setpeer_err))
        return
    end

    local payload = table.concat(lines, "\n")
    local _, send_err = sock:send(payload)
    if send_err then
        ngx.log(ngx.ERR, 'lua="proxy-metrics" event="udp_send_failed" err=', tostring(send_err))
    end
end

local function keys_for_closed_windows()
    local keys = dict:get_keys(0)
    local closed = {}
    local open_window = current_window()

    for _, key in ipairs(keys) do
        local window_id = tonumber(key:match("^[^:]+:(%d+):"))
        if window_id and window_id < open_window then
            closed[window_id] = true
        end
    end

    return closed
end

local function publish_window(window_id)
    local lines = {}
    local metric_names = {
        "Requests",
        "AcceptedConnections",
        "BlockedConnections",
        "SniMismatchCount",
        "DnsResolutionFailureCount",
        "UpstreamConnectFailureCount",
        "InternalFailureCount",
    }

    for _, name in ipairs(metric_names) do
        local value = tonumber(dict:get(counter_key(window_id, name)) or 0)
        if value > 0 then
            lines[#lines + 1] = string.format("%s:%s|c", name, value)
        end
    end

    local active = tonumber(dict:get(active_connections_key()) or 0)
    lines[#lines + 1] = string.format("ActiveConnections:%s|g", active)

    local histogram_names = {
        "ProxyDecisionLatencyMs",
        "UpstreamConnectLatencyMs",
    }
    local quantiles = {
        {suffix = "P50", value = 0.50},
        {suffix = "P95", value = 0.95},
        {suffix = "P99", value = 0.99},
    }

    for _, histogram_name in ipairs(histogram_names) do
        for _, quantile in ipairs(quantiles) do
            local percentile = percentile_from_histogram(window_id, histogram_name, quantile.value)
            if percentile then
                local metric_name = string.format("%s%s", quantile.suffix, histogram_name)
                lines[#lines + 1] = string.format("%s:%s|g", metric_name, percentile)
            end
        end
    end

    emit_statsd_lines(lines)

    local keys = dict:get_keys(0)
    for _, key in ipairs(keys) do
        if key:find(":" .. window_id .. ":", 1, true) then
            dict:delete(key)
        end
    end
end

local function flush_closed_windows(premature)
    if premature then
        return
    end

    for window_id, _ in pairs(keys_for_closed_windows()) do
        publish_window(window_id)
    end

    local ok, err = ngx.timer.at(publish_interval(), flush_closed_windows)
    if not ok then
        ngx.log(ngx.ERR, 'lua="proxy-metrics" event="flush_timer_reschedule_failed" err=', tostring(err))
    end
end

function _M.start_flush_timer()
    if ngx.worker.id() ~= 0 then
        return
    end

    local ok, err = ngx.timer.at(publish_interval(), flush_closed_windows)
    if not ok then
        ngx.log(ngx.ERR, 'lua="proxy-metrics" event="flush_timer_start_failed" err=', tostring(err))
    end
end

function _M.record_session_start()
    if ngx.ctx.proxy_metrics_started then
        return
    end

    ngx.ctx.proxy_metrics_started = ngx.now()
    ngx.ctx.proxy_metrics_active = true
    ensure_counter(active_connections_key(), 1)
    increment_counter("Requests", 1)
end

local function record_terminal_decision(accepted, reason)
    if ngx.ctx.proxy_metrics_decision_recorded then
        return
    end

    ngx.ctx.proxy_metrics_decision_recorded = true
    if accepted then
        ngx.ctx.proxy_metrics_forwarded = true
        increment_counter("AcceptedConnections", 1)
    else
        increment_counter("BlockedConnections", 1)
    end

    classify_reason_metric(reason)

    if ngx.ctx.proxy_metrics_started then
        local elapsed_ms = (ngx.now() - ngx.ctx.proxy_metrics_started) * 1000
        observe_histogram("ProxyDecisionLatencyMs", elapsed_ms)
    end
end

function _M.record_allow()
    record_terminal_decision(true, nil)
end

function _M.record_block(reason)
    record_terminal_decision(false, reason)
end

function _M.record_mismatch(enforced)
    record_terminal_decision(not enforced, "sni_mismatch")
end

function _M.finalize_session()
    if ngx.ctx.proxy_metrics_active then
        ngx.ctx.proxy_metrics_active = nil
        ensure_counter(active_connections_key(), -1)
    end

    if not ngx.ctx.proxy_metrics_forwarded then
        return
    end

    local upstream_connect_time = parse_first_number(ngx.var.upstream_connect_time)
    if upstream_connect_time then
        observe_histogram("UpstreamConnectLatencyMs", upstream_connect_time * 1000)
    end

    local status = tostring(ngx.var.status or "")
    if status ~= "" and status ~= "200" then
        increment_counter("UpstreamConnectFailureCount", 1)
    end
end

return _M
