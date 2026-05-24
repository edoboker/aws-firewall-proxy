"""Live runtime smoke test for the transparent proxy stack.

Proves the deployed proxy instance has the full transparent-proxy wiring in
place: valid nginx config, the iptables REDIRECT that captures :443, and the
Lua/C-module guard loaded. Requires a deployed stack reachable via SSM.
"""

from common.ssm import ssm_exec


def test_nginx_config_valid(outputs, aws_region):
    result = ssm_exec(
        outputs["proxy_instance_id"],
        "nginx -t",
        region=aws_region,
    )
    assert result.exit_code == 0, f"nginx -t failed: {result!r}"


def test_iptables_redirect_present(outputs, aws_region):
    result = ssm_exec(
        outputs["proxy_instance_id"],
        "iptables-save -t nat",
        region=aws_region,
    )
    assert result.exit_code == 0, f"iptables-save failed: {result!r}"
    out = result.stdout
    assert "PREROUTING" in out, f"no PREROUTING chain in nat table:\n{out}"
    assert "REDIRECT" in out and "8443" in out, (
        f"no REDIRECT to 8443 (workload :443 capture missing):\n{out}"
    )


def test_effective_config_wires_guard(outputs, aws_region):
    # `nginx -T` dumps the full effective config, including the AppConfig-rendered
    # includes, so this checks the live wiring rather than the AMI template.
    result = ssm_exec(
        outputs["proxy_instance_id"],
        "nginx -T",
        region=aws_region,
        timeout_seconds=60,
    )
    assert result.exit_code == 0, f"nginx -T failed: {result!r}"
    cfg = result.stdout
    for needle in (
        "preread_by_lua_file",
        "check_sni.lua",
        "ngx_stream_original_dst_module.so",
    ):
        assert needle in cfg, f"effective config does not reference {needle!r}"
