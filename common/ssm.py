import time
from dataclasses import dataclass

import boto3
from botocore.exceptions import ClientError

TERMINAL_STATES = {"Success", "Failed", "TimedOut", "Cancelled"}
READY_PING_STATUS = "Online"
INVALID_EC2_STATES = {"shutting-down", "terminated", "stopping", "stopped"}


@dataclass
class SsmResult:
    status: str
    exit_code: int
    stdout: str
    stderr: str


@dataclass
class SsmTargetState:
    instance_state: str | None
    ping_status: str | None
    managed: bool


def _describe_target_state(*, ec2_client, ssm_client, instance_id: str) -> SsmTargetState:
    instance_state = None
    try:
        reservations = ec2_client.describe_instances(InstanceIds=[instance_id])[
            "Reservations"
        ]
    except ClientError as e:
        if e.response["Error"]["Code"] != "InvalidInstanceID.NotFound":
            raise
    else:
        if reservations and reservations[0]["Instances"]:
            instance_state = reservations[0]["Instances"][0]["State"]["Name"]

    info = ssm_client.describe_instance_information(
        Filters=[{"Key": "InstanceIds", "Values": [instance_id]}]
    )["InstanceInformationList"]
    if not info:
        return SsmTargetState(
            instance_state=instance_state,
            ping_status=None,
            managed=False,
        )

    return SsmTargetState(
        instance_state=instance_state,
        ping_status=info[0].get("PingStatus"),
        managed=True,
    )


def _format_target_state(state: SsmTargetState) -> str:
    return (
        f"EC2 state={state.instance_state or 'unknown'}, "
        f"SSM managed={'yes' if state.managed else 'no'}, "
        f"SSM ping={state.ping_status or 'unknown'}"
    )


def _readiness_blocker(state: SsmTargetState) -> str | None:
    if state.instance_state in INVALID_EC2_STATES:
        return f"instance is in EC2 state {state.instance_state}"
    if state.instance_state is None and not state.managed:
        return "instance was not found in this region and is not registered with SSM"
    return None


def _wait_for_target_ready(
    *,
    ec2_client,
    ssm_client,
    instance_id: str,
    region: str,
    timeout_seconds: int,
    poll_interval: float,
) -> SsmTargetState:
    deadline = time.monotonic() + timeout_seconds
    last_state = SsmTargetState(instance_state=None, ping_status=None, managed=False)

    while True:
        last_state = _describe_target_state(
            ec2_client=ec2_client,
            ssm_client=ssm_client,
            instance_id=instance_id,
        )
        blocker = _readiness_blocker(last_state)
        if blocker is not None:
            raise RuntimeError(
                f"SSM target {instance_id} in {region} cannot become ready: "
                f"{blocker} ({_format_target_state(last_state)})."
            )
        if (
            last_state.instance_state == "running"
            and last_state.managed
            and last_state.ping_status == READY_PING_STATUS
        ):
            return last_state

        if time.monotonic() > deadline:
            raise TimeoutError(
                f"SSM target {instance_id} in {region} did not become ready in time "
                f"({_format_target_state(last_state)})."
            )
        time.sleep(poll_interval)


def ssm_exec(
    instance_id: str,
    command: str,
    *,
    region: str,
    timeout_seconds: int = 60,
    poll_interval: float = 2.0,
    ready_timeout_seconds: int | None = None,
) -> SsmResult:
    """Run a shell command on an EC2 instance via SSM Run Command.

    Raises TimeoutError if the invocation does not reach a terminal state in time.
    """
    ec2_client = boto3.client("ec2", region_name=region)
    client = boto3.client("ssm", region_name=region)
    readiness_timeout = ready_timeout_seconds or 15

    send_deadline = time.monotonic() + readiness_timeout
    while True:
        try:
            send = client.send_command(
                InstanceIds=[instance_id],
                DocumentName="AWS-RunShellScript",
                Parameters={"commands": [command]},
                TimeoutSeconds=timeout_seconds,
            )
            break
        except ClientError as e:
            if e.response["Error"]["Code"] != "InvalidInstanceId":
                raise
            if time.monotonic() > send_deadline:
                state = _describe_target_state(
                    ec2_client=ec2_client,
                    ssm_client=client,
                    instance_id=instance_id,
                )
                raise TimeoutError(
                    f"SSM target {instance_id} in {region} never accepted Run Command "
                    f"({_format_target_state(state)})."
                ) from e
            _wait_for_target_ready(
                ec2_client=ec2_client,
                ssm_client=client,
                instance_id=instance_id,
                region=region,
                timeout_seconds=readiness_timeout,
                poll_interval=poll_interval,
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
