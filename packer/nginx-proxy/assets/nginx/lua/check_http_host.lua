-- Experimental HTTP/1.x Host/original-dst guard.
--
-- Narrow prototype scope:
--   * cleartext HTTP on port 80 only
--   * require exactly one Host header
--   * reject CONNECT and absolute-form host disagreement
--   * resolve Host through the AppConfig-backed HTTP runtime DNS policy
--   * verify original destination IP is in the Host RRset
--   * forward to one resolved Host IP on port 80, preserving the HTTP Host header

local DEBUG = (os.getenv("PROXY_DEBUG") or "0") == "1"
local MAX_HEADER_BYTES = 8192
local MAX_CNAME_DEPTH = 5
local RUNTIME_POLICY_PATH = "/etc/nginx/lua/proxy_runtime_policy.lua"

local function q(value)
    if value == nil then
        return '""'
    end
    return string.format("%q", tostring(value))
end

local function set_var(name, value)
    local ok, err = pcall(function()
        ngx.var[name] = value
    end)
    if not ok then
        ngx.log(ngx.ERR, 'lua="http-host-guard" event="set_var_failed" name=', q(name), ' err=', q(err))
    end
end

local function log_event(level, event, fields)
    local parts = { 'lua="http-host-guard"', 'event=' .. q(event) }
    local keys = { "decision", "host", "method", "target", "original_dst", "dst_ip", "resolved", "proxy_target", "err" }
    if fields then
        for _, key in ipairs(keys) do
            if fields[key] ~= nil and fields[key] ~= "" then
                parts[#parts + 1] = key .. "=" .. q(fields[key])
            end
        end
    end
    ngx.log(level, table.concat(parts, " "))
end

local function debug_log(event, fields)
    if DEBUG then
        log_event(ngx.NOTICE, event, fields)
    end
end

local function set_decision(decision)
    set_var("http_proxy_decision", decision)
end

local function fail_internal(event, fields)
    set_decision(event)
    log_event(ngx.ERR, event, fields)
    return ngx.exit(ngx.ERROR)
end

local function fail_quiet(decision, reason)
    set_decision(decision)
    debug_log(decision, nil)
    return ngx.exit(ngx.ERROR)
end

local function build_nameserver_list(resolvers)
    local nameservers = {}
    local seen = {}
    if type(resolvers) == "table" then
        for _, resolver in ipairs(resolvers) do
            local value = tostring(resolver)
            if value ~= "" and not seen[value] then
                seen[value] = true
                nameservers[#nameservers + 1] = value
            end
        end
    end
    return nameservers
end

local function load_runtime_policy()
    local loader, load_err = loadfile(RUNTIME_POLICY_PATH)
    if not loader then
        return nil, "runtime_policy_load_failed:" .. tostring(load_err)
    end

    local ok, policy = pcall(loader)
    if not ok or type(policy) ~= "table" then
        return nil, "runtime_policy_invalid"
    end

    local dns = policy.dns
    if type(dns) ~= "table" then
        return nil, "runtime_policy_missing_dns"
    end

    local nameservers = build_nameserver_list(dns.resolvers)
    if #nameservers == 0 then
        return nil, "runtime_policy_missing_resolvers"
    end

    local queries_per_host = tonumber(dns.queries_per_host)
    if not queries_per_host or queries_per_host < 1 or queries_per_host > 16 or queries_per_host % 1 ~= 0 then
        return nil, "runtime_policy_invalid_queries_per_host"
    end

    local mode = tostring(policy.enforcement and policy.enforcement.mode or "")
    if mode ~= "strict" and mode ~= "audit" then
        return nil, "runtime_policy_invalid_mode"
    end

    return {
        dns_resolvers = table.concat(nameservers, ","),
        enforce = mode == "strict",
        nameservers = nameservers,
        queries_per_host = queries_per_host,
    }
end

local function require_resolver_module()
    local ok, resolver_mod = pcall(require, "resty.dns.resolver")
    if not ok then
        return nil, tostring(resolver_mod)
    end
    return resolver_mod
end

local function query_a_records(resolver_mod, nameserver, hostname, depth)
    if depth > MAX_CNAME_DEPTH then
        return nil, "cname_depth_exceeded"
    end

    local resolver, resolver_err = resolver_mod:new({
        nameservers = { nameserver },
        retrans = 2,
        timeout = 1500,
    })
    if not resolver then
        return nil, "resolver_init_failed:" .. tostring(resolver_err)
    end

    local answers, query_err = resolver:query(hostname, { qtype = resolver.TYPE_A })
    if not answers or answers.errcode then
        return nil, "resolver_query_failed:" .. tostring(query_err or (answers and answers.errstr))
    end

    local addresses = {}
    local seen = {}
    local cname_target
    for _, answer in ipairs(answers) do
        if answer.address and not seen[answer.address] then
            seen[answer.address] = true
            addresses[#addresses + 1] = answer.address
        elseif answer.cname and not cname_target then
            cname_target = answer.cname
        end
    end

    if #addresses > 0 then
        return addresses
    end
    if cname_target then
        return query_a_records(resolver_mod, nameserver, cname_target, depth + 1)
    end
    return {}, nil
end

local function resolve_host_addresses(hostname, runtime_policy)
    local resolver_mod, require_err = require_resolver_module()
    if not resolver_mod then
        return nil, nil, "resolver_require_failed:" .. tostring(require_err)
    end

    local resolved = {}
    local errors = {}
    for _, nameserver in ipairs(runtime_policy.nameservers) do
        for _ = 1, runtime_policy.queries_per_host do
            local addresses, err = query_a_records(resolver_mod, nameserver, hostname, 0)
            if addresses then
                for _, address in ipairs(addresses) do
                    resolved[address] = true
                end
            elseif err then
                errors[#errors + 1] = err
            end
        end
    end

    local resolved_list = {}
    for ip, _ in pairs(resolved) do
        resolved_list[#resolved_list + 1] = ip
    end
    table.sort(resolved_list)

    if #resolved_list == 0 then
        return nil, nil, table.concat(errors, "; ")
    end
    return resolved, resolved_list, nil
end

local function peek_http_headers()
    local sock, sock_err = ngx.req.socket()
    if not sock then
        return nil, "req_socket:" .. tostring(sock_err)
    end

    local data, data_err = sock:peek(MAX_HEADER_BYTES)
    if not data then
        return nil, "peek_http_headers:" .. tostring(data_err)
    end

    local header_end = data:find("\r\n\r\n", 1, true)
    if not header_end then
        return nil, "http_headers_too_large_or_incomplete"
    end
    return data:sub(1, header_end + 3)
end

local function normalize_host(raw_host)
    local host = tostring(raw_host or ""):match("^%s*(.-)%s*$")
    if host == "" then
        return nil
    end
    if host:sub(1, 1) == "[" then
        return nil
    end
    host = host:gsub(":%d+$", "")
    host = host:lower()
    if not host:match("^[a-z0-9][a-z0-9%.%-]*[a-z0-9]$") then
        return nil
    end
    return host
end

local function parse_http_request(header_block)
    local lines = {}
    for line in header_block:gmatch("([^\r\n]*)\r\n") do
        lines[#lines + 1] = line
    end
    if #lines == 0 then
        return nil, "missing_request_line"
    end

    local method, target, version = lines[1]:match("^([A-Z]+)%s+([^%s]+)%s+(HTTP/%d%.%d)$")
    if not method then
        return nil, "bad_request_line"
    end
    if method == "CONNECT" then
        return nil, "connect_not_supported"
    end

    local host_count = 0
    local host
    for idx = 2, #lines do
        local name, value = lines[idx]:match("^([^:]+):%s*(.*)$")
        if name and name:lower() == "host" then
            host_count = host_count + 1
            host = value
        end
    end
    if host_count == 0 then
        return nil, "missing_host_header"
    end
    if host_count > 1 then
        return nil, "multiple_host_headers"
    end

    local normalized_host = normalize_host(host)
    if not normalized_host then
        return nil, "invalid_host_header"
    end

    local absolute_host = target:match("^https?://([^/:]+)")
    if absolute_host and normalize_host(absolute_host) ~= normalized_host then
        return nil, "absolute_form_host_mismatch"
    end

    return {
        method = method,
        target = target,
        version = version,
        host = normalized_host,
    }
end

local ok, runtime_err = xpcall(function()
    local original_dst = ngx.var.original_dst

    set_var("http_proxy_decision", "")
    set_var("http_host", "")
    set_var("http_original_dst_ip", "")
    set_var("http_resolved_ips", "")
    set_var("http_proxy_target", "")

    local runtime_policy, policy_err = load_runtime_policy()
    if not runtime_policy then
        return fail_internal("runtime_policy_load_failed", { original_dst = original_dst, err = policy_err })
    end

    if not original_dst or original_dst == "" then
        return fail_internal("missing_original_dst", { original_dst = original_dst })
    end

    local dst_ip = original_dst:match("^([^:]+):")
    if not dst_ip then
        return fail_internal("bad_original_dst", { original_dst = original_dst })
    end
    set_var("http_original_dst_ip", dst_ip)

    local headers, peek_err = peek_http_headers()
    if not headers then
        return fail_internal("http_header_peek_failed", { original_dst = original_dst, dst_ip = dst_ip, err = peek_err })
    end

    local request, parse_err = parse_http_request(headers)
    if not request then
        if parse_err == "missing_host_header" then
            return fail_quiet("drop_no_sni", "no_sni")
        end
        return fail_internal("http_request_parse_failed", { original_dst = original_dst, dst_ip = dst_ip, err = parse_err })
    end

    set_var("http_host", request.host)

    local host_allowed = ngx.var.http_host_allowed
    if host_allowed ~= "1" then
        debug_log("deny_allowlist", { host = request.host, original_dst = original_dst, dst_ip = dst_ip })
        return fail_quiet("deny_allowlist", "allowlist_denied")
    end

    local resolved, resolved_list, resolve_err = resolve_host_addresses(request.host, runtime_policy)
    if not resolved then
        return fail_internal("resolver_query_failed", {
            host = request.host,
            original_dst = original_dst,
            dst_ip = dst_ip,
            err = resolve_err,
        })
    end

    local resolved_str = table.concat(resolved_list, ",")
    set_var("http_resolved_ips", resolved_str)

    if not resolved[dst_ip] then
        set_decision("mismatch")
        log_event(ngx.NOTICE, "http_host_mismatch", {
            decision = "mismatch",
            host = request.host,
            original_dst = original_dst,
            dst_ip = dst_ip,
            resolved = resolved_str,
        })
        if runtime_policy.enforce then
            return ngx.exit(ngx.ERROR)
        end
    end

    local proxy_target = resolved_list[1] .. ":80"
    set_var("http_proxy_target", proxy_target)
    set_decision("allow")
    debug_log("allow", {
        host = request.host,
        method = request.method,
        target = request.target,
        original_dst = original_dst,
        dst_ip = dst_ip,
        resolved = resolved_str,
        proxy_target = proxy_target,
    })
end, function(err)
    return debug.traceback(err, 2)
end)

if not ok then
    set_decision("lua_exception")
    log_event(ngx.ERR, "lua_exception", { err = runtime_err })
    return ngx.exit(ngx.ERROR)
end
