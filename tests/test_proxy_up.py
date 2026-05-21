from common.ssm import ssm_exec


def test_proxy_process_up(outputs, aws_region):
    result = ssm_exec(
        outputs["proxy_instance_id"],
        "systemctl is-active nginx",
        region=aws_region,
    )
    assert result.exit_code == 0, f"nginx not active: {result!r}"
    assert result.stdout.strip() == "active"
