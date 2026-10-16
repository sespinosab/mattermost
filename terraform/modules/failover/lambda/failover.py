import logging
import os
import time

import boto3

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger()
ec2 = boto3.client("ec2")
ssm = boto3.client("ssm")
sns = boto3.client("sns")

PRIMARY = os.environ["PRIMARY_INSTANCE_ID"]
STANDBY = os.environ["STANDBY_INSTANCE_ID"]
EIP_ALLOCATION_ID = os.environ["EIP_ALLOCATION_ID"]
SNS_TOPIC_ARN = os.environ["SNS_TOPIC_ARN"]


def app_is_healthy(instance_id):
    """Run the health endpoint check through SSM; no public health-check port is needed."""
    try:
        command = ssm.send_command(
            InstanceIds=[instance_id],
            DocumentName="AWS-RunShellScript",
            Parameters={"commands": ["for i in 1 2 3; do curl --fail --silent --show-error --max-time 5 http://127.0.0.1:8065/api/v4/system/ping >/dev/null && exit 0; sleep 5; done; exit 1"]},
            TimeoutSeconds=15,
        )
        command_id = command["Command"]["CommandId"]
        for _ in range(8):
            time.sleep(3)
            try:
                result = ssm.get_command_invocation(CommandId=command_id, InstanceId=instance_id)
            except ssm.exceptions.InvocationDoesNotExist:
                continue
            status = result.get("Status")
            if status == "Success":
                return True
            if status in ("Failed", "TimedOut", "Cancelled", "Cancelling"):
                logger.warning("SSM health check failed for %s: %s", instance_id, result.get("StandardErrorContent", "no stderr"))
                return False
        logger.warning("SSM health check timed out for %s", instance_id)
        return False
    except Exception as exc:
        logger.warning("Could not check application health on %s: %s", instance_id, exc)
        return False


def publish(subject, message):
    sns.publish(TopicArn=SNS_TOPIC_ARN, Subject=subject[:100], Message=message)


def lambda_handler(event, context):
    addresses = ec2.describe_addresses(AllocationIds=[EIP_ALLOCATION_ID]).get("Addresses", [])
    if not addresses:
        logger.error("Elastic IP allocation %s was not found", EIP_ALLOCATION_ID)
        return {"status": "error", "reason": "eip-not-found"}

    current_instance = addresses[0].get("InstanceId")
    if current_instance and app_is_healthy(current_instance):
        logger.info("Mattermost is healthy on %s", current_instance)
        return {"status": "healthy", "instance_id": current_instance}

    if current_instance == STANDBY:
        logger.error("Mattermost is unhealthy on standby instance %s; automatic failback is not configured", STANDBY)
        return {"status": "standby-unhealthy", "instance_id": STANDBY}

    if current_instance not in (None, PRIMARY):
        logger.error("Elastic IP is associated with unexpected instance %s; refusing automatic reassignment", current_instance)
        publish("Mattermost failover stopped", f"Elastic IP allocation {EIP_ALLOCATION_ID} is associated with unexpected instance {current_instance}. Manual investigation required.")
        return {"status": "unexpected-eip-association", "instance_id": current_instance}

    logger.error("Mattermost health check failed on primary; starting standby %s", STANDBY)
    try:
        ec2.start_instances(InstanceIds=[STANDBY])
        waiter = ec2.get_waiter("instance_running")
        waiter.wait(InstanceIds=[STANDBY], WaiterConfig={"Delay": 10, "MaxAttempts": 18})
        ec2.associate_address(AllocationId=EIP_ALLOCATION_ID, InstanceId=STANDBY, AllowReassociation=True)
        publish("Mattermost failover initiated", f"Mattermost did not respond on the primary EC2. Started standby {STANDBY} in another Availability Zone and reassigned the Elastic IP. Allow several minutes for startup, then verify the application.")
        logger.info("Elastic IP reassigned to standby %s", STANDBY)
        return {"status": "failover-started", "instance_id": STANDBY}
    except Exception as exc:
        logger.exception("Failover failed")
        publish("Mattermost failover FAILED", f"Could not complete failover to standby {STANDBY}: {exc}. Manual recovery is required.")
        raise
