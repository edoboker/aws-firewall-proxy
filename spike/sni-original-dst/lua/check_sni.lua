-- check_sni.lua
--
-- Stream preread policy:
--   * recover the pre-NAT destination from $original_dst (set by the C module)
--   * parse the ClientHello ourselves to recover SNI
--   * resolve that SNI
--   * allow only if dst_ip is one of the resolved A records
--
-- Logging model:
--   * default runtime: quiet on allow, WARN on spoof mismatch, ERR on internal failures
--   * debug runtime: set SPIKE_DEBUG=1 for step-by-step diagnostic logs

local ENFORCE = (os.getenv("ENFORCE") or "1") == "1"
local DEBUG = (os.getenv("SPIKE_DEBUG") or "0") == "1"
local DNS_RESOLVERS = os.getenv("DNS_RESOLVERS") or os.getenv("DNS_RESOLVER") or "1.1.1.1"
local DNS_QUERIES_PER_SNI = tonumber(os.getenv("DNS_QUERIES_PER_SNI") or "1") or 1
local MAX_CNAME_DEPTH = 5

if DNS_QUERIES_PER_SNI < 1 then
    DNS_QUERIES_PER_SNI = 1
elseif DNS_QUERIES_PER_SNI > 16 then
    DNS_QUERIES_PER_SNI = 16
end

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
        ngx.log(ngx.ERR,
                'spike_lua="check_sni" event="set_var_failed" name=', q(name),
                ' value=', q(value), ' err=', q(err))
    end
end

local function log_event(level, event, fields)
    local parts = {
        'spike_lua="check_sni"',
        'event=' .. q(event),
    }

    local ordered_keys = {
        "decision",
        "sni",
        "original_dst",
        "dst_ip",
        "resolved",
        "dns_resolver",
        "dns_queries_per_sni",
        "record_content_type",
        "record_version",
        "record_len",
        "handshake_type",
        "handshake_len",
        "client_hello_version",
        "session_id_len",
        "cipher_suites_len",
        "cipher_suite_count",
        "compression_methods_len",
        "extensions_len",
        "extension_count",
        "err",
    }

    if fields then
        for _, key in ipairs(ordered_keys) do
            local value = fields[key]
            if value ~= nil and value ~= "" then
                parts[#parts + 1] = key .. "=" .. q(value)
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

local function build_nameserver_list()
    local nameservers = {}
    local seen = {}

    local function add(nameserver)
        if nameserver and nameserver ~= "" and not seen[nameserver] then
            seen[nameserver] = true
            nameservers[#nameservers + 1] = nameserver
        end
    end

    for nameserver in tostring(DNS_RESOLVERS):gmatch("[^,%s]+") do
        add(nameserver)
    end

    if #nameservers == 0 then
        add("1.1.1.1")
    end

    return nameservers
end

local function set_decision(decision)
    set_var("spike_decision", decision)
end

local function fail_internal(event, fields)
    set_decision(event)
    log_event(ngx.ERR, event, fields)
    if ENFORCE then
        return ngx.exit(ngx.ERROR)
    end
end

local function fail_quiet(decision)
    set_decision(decision)
    if DEBUG then
        log_event(ngx.NOTICE, decision, nil)
    end
    if ENFORCE then
        return ngx.exit(ngx.ERROR)
    end
end

local function u16(data, pos)
    local b1, b2 = data:byte(pos, pos + 1)

    if not b2 then
        return nil
    end

    return b1 * 256 + b2
end

local function u24(data, pos)
    local b1, b2, b3 = data:byte(pos, pos + 2)

    if not b3 then
        return nil
    end

    return b1 * 65536 + b2 * 256 + b3
end

local function hex_u16(byte1, byte2)
    if not byte1 or not byte2 then
        return nil
    end

    return string.format("0x%02x%02x", byte1, byte2)
end

local function peek_client_hello_record()
    local sock, sock_err = ngx.req.socket()
    if not sock then
        return nil, "req_socket:" .. tostring(sock_err)
    end

    local header, header_err = sock:peek(5)
    if not header then
        return nil, "peek_tls_header:" .. tostring(header_err)
    end

    local record_len = u16(header, 4)
    if not record_len then
        return nil, "short_tls_header"
    end

    if record_len < 4 then
        return nil, "bad_tls_record_length:" .. tostring(record_len)
    end

    local total = 5 + record_len
    local record, record_err = sock:peek(total)
    if not record then
        return nil, "peek_tls_record:" .. tostring(record_err)
    end

    return record
end

local function parse_client_hello(record)
    if #record < 9 then
        return nil, "short_tls_record"
    end

    local info = {
        record_content_type = record:byte(1),
        record_version = hex_u16(record:byte(2), record:byte(3)),
        record_len = u16(record, 4),
        handshake_type = record:byte(6),
        handshake_len = u24(record, 7),
    }

    if info.record_content_type ~= 22 then
        return nil, "unexpected_tls_content_type:" .. tostring(info.record_content_type)
    end

    if info.handshake_type ~= 1 then
        return nil, "unexpected_handshake_type:" .. tostring(info.handshake_type)
    end

    if not info.handshake_len then
        return nil, "short_handshake_header"
    end

    if #record < 9 + info.handshake_len then
        return nil, "truncated_handshake"
    end

    local pos = 10
    info.client_hello_version = hex_u16(record:byte(pos), record:byte(pos + 1))
    pos = pos + 2
    pos = pos + 32

    info.session_id_len = record:byte(pos)
    if not info.session_id_len then
        return nil, "missing_session_id_length"
    end
    pos = pos + 1 + info.session_id_len

    info.cipher_suites_len = u16(record, pos)
    if not info.cipher_suites_len then
        return nil, "missing_cipher_suites_length"
    end
    info.cipher_suite_count = info.cipher_suites_len / 2
    pos = pos + 2 + info.cipher_suites_len

    info.compression_methods_len = record:byte(pos)
    if not info.compression_methods_len then
        return nil, "missing_compression_methods_length"
    end
    pos = pos + 1 + info.compression_methods_len

    info.extensions_len = u16(record, pos)
    if not info.extensions_len then
        return nil, "missing_extensions_length"
    end
    pos = pos + 2

    local extensions_end = pos + info.extensions_len - 1
    if extensions_end > #record then
        return nil, "truncated_extensions"
    end

    info.extension_count = 0

    while pos + 3 <= extensions_end do
        local ext_type = u16(record, pos)
        local ext_len = u16(record, pos + 2)
        if not ext_type or not ext_len then
            return nil, "truncated_extension_header"
        end

        info.extension_count = info.extension_count + 1
        pos = pos + 4

        if pos + ext_len - 1 > extensions_end then
            return nil, "truncated_extension_body:" .. tostring(ext_type)
        end

        if ext_type == 0 then
            local list_len = u16(record, pos)
            if not list_len then
                return nil, "missing_sni_list_length"
            end

            local list_pos = pos + 2
            local list_end = pos + ext_len - 1

            if list_pos + list_len - 1 > list_end then
                return nil, "truncated_sni_list"
            end

            while list_pos + 2 <= list_end do
                local name_type = record:byte(list_pos)
                local name_len = u16(record, list_pos + 1)
                if not name_type or not name_len then
                    return nil, "truncated_server_name_header"
                end

                list_pos = list_pos + 3

                if list_pos + name_len - 1 > list_end then
                    return nil, "truncated_server_name"
                end

                local name = record:sub(list_pos, list_pos + name_len - 1)
                if name_type == 0 then
                    info.sni = name
                    return info
                end

                list_pos = list_pos + name_len
            end

            return nil, "no_host_name_in_sni_extension"
        end

        pos = pos + ext_len
    end

    return nil, "sni_extension_not_found"
end

local function require_resolver_module()
    local require_ok, resolver_mod = pcall(require, "resty.dns.resolver")
    if not require_ok then
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
        return nil, "resolver_init_failed:" .. tostring(nameserver) .. ":" .. tostring(resolver_err)
    end

    local answers, query_err = resolver:query(hostname, { qtype = resolver.TYPE_A })
    if not answers or answers.errcode then
        return nil, "resolver_query_failed:" .. tostring(nameserver) .. ":" .. tostring(query_err or (answers and answers.errstr))
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

local function resolve_sni_addresses(hostname)
    local resolver_mod, require_err = require_resolver_module()
    if not resolver_mod then
        return nil, nil, DNS_RESOLVERS, "resolver_require_failed:" .. tostring(require_err)
    end

    local nameservers = build_nameserver_list()
    local resolved = {}
    local errors = {}

    for _, nameserver in ipairs(nameservers) do
        for _ = 1, DNS_QUERIES_PER_SNI do
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
        if #errors == 0 then
            errors[1] = "resolver_returned_no_a_records"
        end
        return nil, nil, table.concat(nameservers, ","), table.concat(errors, "; ")
    end

    return resolved, table.concat(resolved_list, ","), table.concat(nameservers, ","), (#errors > 0 and table.concat(errors, "; ") or nil)
end

local ok, runtime_err = xpcall(function()
    local original_dst = ngx.var.original_dst

    set_var("spike_decision", "")
    set_var("spike_sni", "")
    set_var("spike_dst_ip", "")
    set_var("spike_resolved", "")

    if not original_dst or original_dst == "" then
        return fail_internal("missing_original_dst", {
            original_dst = original_dst,
            dns_resolver = DNS_RESOLVERS,
            err = "iptables REDIRECT likely missing",
        })
    end

    local dst_ip = original_dst:match("^([^:]+):")
    if not dst_ip then
        return fail_internal("bad_original_dst", {
            original_dst = original_dst,
            dns_resolver = DNS_RESOLVERS,
        })
    end
    set_var("spike_dst_ip", dst_ip)

    local record, peek_err = peek_client_hello_record()
    if not record then
        return fail_internal("client_hello_peek_failed", {
            original_dst = original_dst,
            dst_ip = dst_ip,
            dns_resolver = DNS_RESOLVERS,
            err = peek_err,
        })
    end

    local clienthello, parse_err = parse_client_hello(record)
    if not clienthello then
        if parse_err == "sni_extension_not_found" or parse_err == "no_host_name_in_sni_extension" then
            debug_log("missing_sni", {
                original_dst = original_dst,
                dst_ip = dst_ip,
                dns_resolver = DNS_RESOLVERS,
            })
            return fail_quiet("drop_no_sni")
        end

        return fail_internal("client_hello_parse_failed", {
            original_dst = original_dst,
            dst_ip = dst_ip,
            dns_resolver = DNS_RESOLVERS,
            err = parse_err,
        })
    end

    set_var("spike_sni", clienthello.sni or "")

    debug_log("client_hello_parsed", {
        sni = clienthello.sni,
        original_dst = original_dst,
        dst_ip = dst_ip,
        dns_resolver = DNS_RESOLVERS,
        dns_queries_per_sni = DNS_QUERIES_PER_SNI,
        record_content_type = clienthello.record_content_type,
        record_version = clienthello.record_version,
        record_len = clienthello.record_len,
        handshake_type = clienthello.handshake_type,
        handshake_len = clienthello.handshake_len,
        client_hello_version = clienthello.client_hello_version,
        session_id_len = clienthello.session_id_len,
        cipher_suites_len = clienthello.cipher_suites_len,
        cipher_suite_count = clienthello.cipher_suite_count,
        compression_methods_len = clienthello.compression_methods_len,
        extensions_len = clienthello.extensions_len,
        extension_count = clienthello.extension_count,
    })

    local resolved, resolved_str, dns_resolver_used, resolve_err = resolve_sni_addresses(clienthello.sni)
    if not resolved then
        return fail_internal("resolver_query_failed", {
            sni = clienthello.sni,
            original_dst = original_dst,
            dst_ip = dst_ip,
            dns_resolver = dns_resolver_used or DNS_RESOLVERS,
            dns_queries_per_sni = DNS_QUERIES_PER_SNI,
            err = resolve_err,
        })
    end

    set_var("spike_resolved", resolved_str)

    if resolved[dst_ip] then
        set_decision("allow")
        debug_log("allow", {
            sni = clienthello.sni,
            original_dst = original_dst,
            dst_ip = dst_ip,
            resolved = resolved_str,
            dns_resolver = dns_resolver_used,
            dns_queries_per_sni = DNS_QUERIES_PER_SNI,
        })
        return
    end

    set_decision("mismatch")
    log_event(ngx.WARN, "sni_spoofing_detected", {
        decision = "mismatch",
        sni = clienthello.sni,
        original_dst = original_dst,
        dst_ip = dst_ip,
        resolved = resolved_str,
        dns_resolver = dns_resolver_used,
        dns_queries_per_sni = DNS_QUERIES_PER_SNI,
        record_content_type = clienthello.record_content_type,
        record_version = clienthello.record_version,
        record_len = clienthello.record_len,
        handshake_type = clienthello.handshake_type,
        handshake_len = clienthello.handshake_len,
        client_hello_version = clienthello.client_hello_version,
        session_id_len = clienthello.session_id_len,
        cipher_suites_len = clienthello.cipher_suites_len,
        cipher_suite_count = clienthello.cipher_suite_count,
        compression_methods_len = clienthello.compression_methods_len,
        extensions_len = clienthello.extensions_len,
        extension_count = clienthello.extension_count,
    })

    if ENFORCE then
        return ngx.exit(ngx.ERROR)
    end
end, function(err)
    return debug.traceback(err, 2)
end)

if not ok then
    set_decision("lua_exception")
    log_event(ngx.ERR, "lua_exception", {
        dns_resolver = DNS_RESOLVERS,
        dns_queries_per_sni = DNS_QUERIES_PER_SNI,
        err = runtime_err,
    })
    return ngx.exit(ngx.ERROR)
end
