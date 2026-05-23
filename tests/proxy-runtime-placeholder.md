# Placeholder: Proxy Runtime Smoke Test

This document is a placeholder for the AWS integration test that should verify the proxy runtime is healthy even when no spoofing is involved.

## Goal

Prove that the deployed proxy instance has the full transparent proxy stack working:

- OpenResty service is active
- iptables REDIRECT is present
- the Lua preread hook is loaded
- the custom original-dst C module is loaded
- a normal allowed HTTPS request succeeds through the proxy path

## Desired assertions

- `systemctl is-active nginx` returns `active`
- `nginx -t` succeeds
- `iptables-save` shows the `PREROUTING` redirect to `8443`
- the effective nginx config references `preread_by_lua_file`
- the effective nginx config references `check_sni.lua`
- the effective nginx config references `ngx_stream_original_dst_module.so`
- a normal request such as `curl https://google.com` from the workload succeeds

## Nice-to-have follow-ups

- verify `/etc/sysconfig/aws-firewall-proxy-runtime` contains the expected `DNS_RESOLVER`
- verify `/etc/nginx/conf.d/sni_allowlist.conf` has been refreshed from SSM
- add one debug-mode path later for proving `SPIKE_DEBUG=1` behavior in a non-production test
