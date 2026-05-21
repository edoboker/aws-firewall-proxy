import time
from dataclasses import dataclass

import boto3
from botocore.exceptions import ClientError

TERMINAL_STATES = {"Success", "Failed", "TimedOut", "Cancelled"}


@dataclass
class SsmResult:
    status: str
    exit_code: int
    stdout: str
    stderr: str


def ssm_exec(
    instance_id: str,
    command: str,
    *,
    region: str,
    timeout_seconds: int = 60,
    poll_interval: float = 2.0,
) -> SsmResult:
    """Run a shell command on an EC2 instance via SSM Run Command.

    Raises TimeoutError if the invocation does not reach a terminal state in time.
    """
    client = boto3.client("ssm", region_name=region)

    send = client.send_command(
        InstanceIds=[instance_id],
        DocumentName="AWS-RunShellScript",
        Parameters={"commands": [command]},
        TimeoutSeconds=timeout_seconds,
    )
    command_id = send["Command"]["CommandId"]

    deadline = time.monotonic() + timeout_seconds + 30
    while True:
        try:
            invocation = client.get_command_invocation(
                CommandId=command_id, InstanceId=instance_id
            )
        except ClientError as e:
            if e.response["Error"]["Code"] != "InvocationDoesNotExist":
                raise
            invocation = None

        if invocation and invocation["Status"] in TERMINAL_STATES:
            return SsmResult(
                status=invocation["Status"],
                exit_code=invocation.get("ResponseCode", -1),
                stdout=invocation.get("StandardOutputContent", ""),
                stderr=invocation.get("StandardErrorContent", ""),
            )

        if time.monotonic() > deadline:
            raise TimeoutError(
                f"SSM command {command_id} on {instance_id} did not finish in time"
            )
        time.sleep(poll_interval)
