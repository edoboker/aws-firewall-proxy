-- check_sni.lua
--
-- Runs in stream preread phase. Compares the kernel-recorded original
-- destination (exposed by ngx_stream_original_dst_module as $original_dst)
-- against the fresh DNS resolution of the SNI extracted by ssl_preread.
--
-- This version is intentionally verbose while we debug the spike. It logs:
--   * phase entry and key inputs
--   * env var visibility
--   * require()/resolver init/query failures
--   * the final decision written to both error log and $spike_decision

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

local function append_trace(step)
    local parts = ngx.ctx.spike_trace_parts

    if not parts then
        parts = {}
        ngx.ctx.spike_trace_parts = parts
    end

    parts[#parts + 1] = step
    local joined = table.concat(parts, ">")
    ngx.ctx.spike_trace = joined
    set_var("spike_trace", joined)

    return joined
end

local function emit(level, event, extra)
    local parts = {
        'spike_lua="check_sni"',
        'event=' .. q(event),
        'phase=' .. q(ngx.get_phase()),
        'trace=' .. q(ngx.ctx.spike_trace or ""),
        'client=' .. q(ngx.var.remote_addr or ""),
        'sni=' .. q(ngx.var.ssl_preread_server_name or ""),
        'effective_sni=' .. q(ngx.var.spike_sni or ""),
        'sni_source=' .. q(ngx.var.spike_sni_source or ""),
        'original_dst=' .. q(ngx.var.original_dst or ""),
    }

    if extra then
        for key, value in pairs(extra) do
            parts[#parts + 1] = key .. "=" .. q(value)
        end
    end

    ngx.log(level, table.concat(parts, " "))
end

local function decide(decision, extra)
    set_var("spike_decision", decision)
    append_trace("decision:" .. decision)
    emit(ngx.WARN, "decision", extra or { decision = decision })
end

local function fail(decision, extra, enforce)
    decide(decision, extra)

    if enforce then
        append_trace("enforce_exit")
        emit(ngx.ERR, "enforcing_close", { decision = decision })
        return ngx.exit(ngx.ERROR)
    end

    append_trace("observe_only_return")
    emit(ngx.WARN, "observe_only_return", { decision = decision })
    return
end

local function format_nameservers(nameservers)
    local formatted = {}

    for _, nameserver in ipairs(nameservers) do
        if type(nameserver) == "table" then
            formatted[#formatted + 1] = table.concat(nameserver, ":")
        else
            formatted[#formatted + 1] = tostring(nameserver)
        end
    end

    return table.concat(formatted, ",")
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

local function peek_client_hello_record()
    append_trace("peek_tls_header")

    local sock, sock_err = ngx.req.socket()
    if not sock then
        return nil, "req_socket:" .. tostring(sock_err)
    end

    local header, header_err = sock:peek(5)
    if not header then
        return nil, "peek_tls_header:" .. tostring(header_err)
    end

    local content_type = header:byte(1)
    local record_len = u16(header, 4)
    if not record_len then
        return nil, "short_tls_header"
    end

    emit(ngx.WARN, "peeked_tls_header", {
        content_type = content_type,
        record_len = record_len,
    })

    if record_len < 4 then
        return nil, "bad_tls_record_length:" .. tostring(record_len)
    end

    append_trace("peek_tls_record")

    local total = 5 + record_len
    local record, record_err = sock:peek(total)
    if not record then
        return nil, "peek_tls_record:" .. tostring(record_err)
    end

    emit(ngx.WARN, "peeked_tls_record", {
        total = total,
        handshake_type = record:byte(6),
    })

    return record
end

local function parse_sni_from_client_hello(record)
    if #record < 9 then
        return nil, "short_tls_record"
    end

    if record:byte(1) ~= 22 then
        return nil, "unexpected_tls_content_type:" .. tostring(record:byte(1))
    end

    if record:byte(6) ~= 1 then
        return nil, "unexpected_handshake_type:" .. tostring(record:byte(6))
    end

    local handshake_len = u24(record, 7)
    if not handshake_len then
        return nil, "short_handshake_header"
    end

    if #record < 9 + handshake_len then
        return nil, "truncated_handshake"
    end

    local pos = 10
    pos = pos + 2   -- client_version
    pos = pos + 32  -- random

    local session_id_len = record:byte(pos)
    if not session_id_len then
        return nil, "missing_session_id_length"
    end
    pos = pos + 1 + session_id_len

    local cipher_suites_len = u16(record, pos)
    if not cipher_suites_len then
        return nil, "missing_cipher_suites_length"
    end
    pos = pos + 2 + cipher_suites_len

    local compression_methods_len = record:byte(pos)
    if not compression_methods_len then
        return nil, "missing_compression_methods_length"
    end
    pos = pos + 1 + compression_methods_len

    local extensions_len = u16(record, pos)
    if not extensions_len then
        return nil, "missing_extensions_length"
    end
    pos = pos + 2

    local extensions_end = pos + extensions_len - 1
    if extensions_end > #record then
        return nil, "truncated_extensions"
    end

    while pos + 3 <= extensions_end do
        local ext_type = u16(record, pos)
        local ext_len = u16(record, pos + 2)
        if not ext_type or not ext_len then
            return nil, "truncated_extension_header"
        end

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
                    return name
                end

                list_pos = list_pos + name_len
            end

            return nil, "no_host_name_in_sni_extension"
        end

        pos = pos + ext_len
    end

    return nil, "sni_extension_not_found"
end

local ok, runtime_err = xpcall(function()
    append_trace("entered")
    emit(ngx.WARN, "entered", {
        subsystem = ngx.config.subsystem,
        package_path = package.path,
    })

    local enforce_raw = os.getenv("ENFORCE")
    local dns_resolver_raw = os.getenv("DNS_RESOLVER")
    local enforce = (enforce_raw or "1") == "1"
    local nameservers = { dns_resolver_raw or "1.1.1.1" }
    local sni = ngx.var.ssl_preread_server_name
    local original_dst = ngx.var.original_dst

    set_var("spike_decision", "entered")
    set_var("spike_sni", sni or "")
    set_var("spike_sni_source", "")
    set_var("spike_dst_ip", "")
    set_var("spike_resolved", "")
    emit(ngx.WARN, "inputs", {
        enforce = tostring(enforce),
        enforce_raw = enforce_raw,
        dns_resolver_raw = dns_resolver_raw,
        nameservers = format_nameservers(nameservers),
    })

    if not sni or sni == "" then
        append_trace("sni_empty_before_peek")
        emit(ngx.WARN, "sni_empty_before_peek")

        local record, peek_err = peek_client_hello_record()
        if not record then
            return fail("drop_client_hello_peek_failed", { err = peek_err }, enforce)
        end

        local buffered_sni = ngx.var.ssl_preread_server_name
        if buffered_sni and buffered_sni ~= "" then
            sni = buffered_sni
            set_var("spike_sni", sni)
            set_var("spike_sni_source", "ssl_preread_after_peek")
            append_trace("sni_from_ssl_preread_after_peek")
            emit(ngx.WARN, "sni_from_ssl_preread_after_peek")
        else
            append_trace("manual_sni_parse")

            local parsed_sni, parse_err = parse_sni_from_client_hello(record)
            if not parsed_sni or parsed_sni == "" then
                return fail("drop_no_sni", { err = parse_err or "manual_parse_returned_empty" }, enforce)
            end

            sni = parsed_sni
            set_var("spike_sni", sni)
            set_var("spike_sni_source", "manual_clienthello_parse")
            append_trace("sni_from_manual_parse")
            emit(ngx.WARN, "sni_from_manual_parse", { parsed_sni = parsed_sni })
        end
    else
        set_var("spike_sni", sni)
        set_var("spike_sni_source", "ssl_preread_initial")
        append_trace("sni_from_ssl_preread_initial")
    end

    if not original_dst or original_dst == "" then
        append_trace("missing_original_dst")
        return fail("drop_no_original_dst", {
            reason = "iptables REDIRECT likely missing",
        }, enforce)
    end

    local dst_ip = original_dst:match("^([^:]+):")
    if not dst_ip then
        append_trace("bad_original_dst")
        return fail("drop_bad_original_dst", nil, enforce)
    end
    set_var("spike_dst_ip", dst_ip)

    append_trace("require_resolver")
    local require_ok, resolver_mod = pcall(require, "resty.dns.resolver")
    if not require_ok then
        return fail("drop_require_failed", {
            err = resolver_mod,
            package_path = package.path,
        }, enforce)
    end

    append_trace("resolver_new")
    local resolver, resolver_err = resolver_mod:new({
        nameservers = nameservers,
        retrans = 2,
        timeout = 1500,
    })
    if not resolver then
        return fail("drop_resolver_init_failed", { err = resolver_err }, enforce)
    end

    append_trace("resolver_query")
    emit(ngx.WARN, "querying_dns", {
        sni = sni,
        dst_ip = dst_ip,
        nameservers = format_nameservers(nameservers),
    })

    local answers, query_err = resolver:query(sni, { qtype = resolver.TYPE_A })
    if not answers or answers.errcode then
        return fail("drop_resolve_failed", {
            err = query_err or (answers and answers.errstr),
            errcode = answers and answers.errcode,
        }, enforce)
    end

    append_trace("answers_received")
    emit(ngx.WARN, "answers_received", {
        answer_count = #answers,
    })

    local resolved = {}
    for _, answer in ipairs(answers) do
        if answer.address then
            resolved[answer.address] = true
        end
    end

    local resolved_list = {}
    for ip, _ in pairs(resolved) do
        resolved_list[#resolved_list + 1] = ip
    end

    table.sort(resolved_list)
    local resolved_str = table.concat(resolved_list, ",")
    set_var("spike_resolved", resolved_str)

    if resolved[dst_ip] then
        append_trace("resolved_match")
        decide("allow", {
            decision = "allow",
            dst_ip = dst_ip,
            resolved = resolved_str,
            sni = sni,
            sni_source = ngx.var.spike_sni_source,
        })
        return
    end

    append_trace("resolved_mismatch")
    return fail("mismatch", {
        dst_ip = dst_ip,
        resolved = resolved_str,
        sni = sni,
        sni_source = ngx.var.spike_sni_source,
    }, enforce)
end, function(err)
    return debug.traceback(err, 2)
end)

if not ok then
    append_trace("exception")
    set_var("spike_decision", "drop_lua_exception")
    emit(ngx.ERR, "exception", { err = runtime_err })
    return ngx.exit(ngx.ERROR)
end
