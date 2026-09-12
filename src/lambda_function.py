"""
Lambda function: List all major AWS resources in the account.
Triggered manually or on a schedule via EventBridge.
"""

import json
import logging
import os

import boto3
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(logging.INFO)

REGION = os.environ.get("AWS_REGION_NAME", "us-east-1")


def lambda_handler(event, context):
    """Entry point — returns a JSON summary of all resources found."""
    resources = {}
    errors = {}

    collectors = {
        "ec2_instances": list_ec2_instances,
        "s3_buckets": list_s3_buckets,
        "rds_instances": list_rds_instances,
        "lambda_functions": list_lambda_functions,
        "vpcs": list_vpcs,
        "security_groups": list_security_groups,
        "iam_users": list_iam_users,
        "iam_roles": list_iam_roles,
        "cloudwatch_alarms": list_cloudwatch_alarms,
        "sns_topics": list_sns_topics,
        "sqs_queues": list_sqs_queues,
        "dynamodb_tables": list_dynamodb_tables,
        "ecs_clusters": list_ecs_clusters,
        "eks_clusters": list_eks_clusters,
        "cloudformation_stacks": list_cloudformation_stacks,
    }

    for name, fn in collectors.items():
        try:
            resources[name] = fn()
            logger.info("%-30s %d item(s)", name, len(resources[name]))
        except ClientError as e:
            errors[name] = e.response["Error"]["Message"]
            logger.warning("Skipped %s: %s", name, errors[name])

    summary = {k: len(v) for k, v in resources.items()}
    logger.info("Summary: %s", json.dumps(summary))

    return {
        "statusCode": 200,
        "summary": summary,
        "resources": resources,
        "errors": errors,
    }


# ---------------------------------------------------------------------------
# Collectors
# ---------------------------------------------------------------------------

def list_ec2_instances():
    ec2 = boto3.client("ec2", region_name=REGION)
    instances = []
    paginator = ec2.get_paginator("describe_instances")
    for page in paginator.paginate():
        for reservation in page["Reservations"]:
            for i in reservation["Instances"]:
                name = _tag(i, "Name")
                instances.append({
                    "InstanceId":       i["InstanceId"],
                    "Name":             name,
                    "State":            i["State"]["Name"],
                    "InstanceType":     i["InstanceType"],
                    "PublicIpAddress":  i.get("PublicIpAddress", ""),
                    "PrivateIpAddress": i.get("PrivateIpAddress", ""),
                    "LaunchTime":       str(i.get("LaunchTime", "")),
                })
    return instances


def list_s3_buckets():
    s3 = boto3.client("s3")
    response = s3.list_buckets()
    return [
        {"Name": b["Name"], "CreationDate": str(b["CreationDate"])}
        for b in response.get("Buckets", [])
    ]


def list_rds_instances():
    rds = boto3.client("rds", region_name=REGION)
    instances = []
    paginator = rds.get_paginator("describe_db_instances")
    for page in paginator.paginate():
        for db in page["DBInstances"]:
            instances.append({
                "DBInstanceIdentifier": db["DBInstanceIdentifier"],
                "Engine":               db["Engine"],
                "EngineVersion":        db["EngineVersion"],
                "Status":               db["DBInstanceStatus"],
                "InstanceClass":        db["DBInstanceClass"],
                "Endpoint":             db.get("Endpoint", {}).get("Address", ""),
                "MultiAZ":              db["MultiAZ"],
                "StorageEncrypted":     db["StorageEncrypted"],
            })
    return instances


def list_lambda_functions():
    lmb = boto3.client("lambda", region_name=REGION)
    functions = []
    paginator = lmb.get_paginator("list_functions")
    for page in paginator.paginate():
        for fn in page["Functions"]:
            functions.append({
                "FunctionName": fn["FunctionName"],
                "Runtime":      fn.get("Runtime", ""),
                "Handler":      fn["Handler"],
                "CodeSize":     fn["CodeSize"],
                "LastModified": fn["LastModified"],
                "MemorySize":   fn["MemorySize"],
                "Timeout":      fn["Timeout"],
            })
    return functions


def list_vpcs():
    ec2 = boto3.client("ec2", region_name=REGION)
    vpcs = []
    for vpc in ec2.describe_vpcs()["Vpcs"]:
        vpcs.append({
            "VpcId":     vpc["VpcId"],
            "Name":      _tag(vpc, "Name"),
            "CidrBlock": vpc["CidrBlock"],
            "IsDefault": vpc["IsDefault"],
            "State":     vpc["State"],
        })
    return vpcs


def list_security_groups():
    ec2 = boto3.client("ec2", region_name=REGION)
    sgs = []
    paginator = ec2.get_paginator("describe_security_groups")
    for page in paginator.paginate():
        for sg in page["SecurityGroups"]:
            sgs.append({
                "GroupId":     sg["GroupId"],
                "GroupName":   sg["GroupName"],
                "Description": sg["Description"],
                "VpcId":       sg.get("VpcId", ""),
            })
    return sgs


def list_iam_users():
    iam = boto3.client("iam")
    users = []
    paginator = iam.get_paginator("list_users")
    for page in paginator.paginate():
        for user in page["Users"]:
            users.append({
                "UserName":   user["UserName"],
                "UserId":     user["UserId"],
                "Arn":        user["Arn"],
                "CreateDate": str(user["CreateDate"]),
            })
    return users


def list_iam_roles():
    iam = boto3.client("iam")
    roles = []
    paginator = iam.get_paginator("list_roles")
    for page in paginator.paginate():
        for role in page["Roles"]:
            roles.append({
                "RoleName":   role["RoleName"],
                "RoleId":     role["RoleId"],
                "Arn":        role["Arn"],
                "CreateDate": str(role["CreateDate"]),
            })
    return roles


def list_cloudwatch_alarms():
    cw = boto3.client("cloudwatch", region_name=REGION)
    alarms = []
    paginator = cw.get_paginator("describe_alarms")
    for page in paginator.paginate():
        for alarm in page["MetricAlarms"]:
            alarms.append({
                "AlarmName":  alarm["AlarmName"],
                "State":      alarm["StateValue"],
                "MetricName": alarm.get("MetricName", ""),
            })
    return alarms


def list_sns_topics():
    sns = boto3.client("sns", region_name=REGION)
    topics = []
    paginator = sns.get_paginator("list_topics")
    for page in paginator.paginate():
        for topic in page["Topics"]:
            topics.append({"TopicArn": topic["TopicArn"]})
    return topics


def list_sqs_queues():
    sqs = boto3.client("sqs", region_name=REGION)
    response = sqs.list_queues()
    return [{"QueueUrl": url} for url in response.get("QueueUrls", [])]


def list_dynamodb_tables():
    dynamodb = boto3.client("dynamodb", region_name=REGION)
    tables = []
    paginator = dynamodb.get_paginator("list_tables")
    for page in paginator.paginate():
        for name in page["TableNames"]:
            tables.append({"TableName": name})
    return tables


def list_ecs_clusters():
    ecs = boto3.client("ecs", region_name=REGION)
    arns = []
    paginator = ecs.get_paginator("list_clusters")
    for page in paginator.paginate():
        arns.extend(page["clusterArns"])
    if not arns:
        return []
    details = ecs.describe_clusters(clusters=arns)["clusters"]
    return [
        {"ClusterName": c["clusterName"], "Status": c["status"], "ActiveServices": c["activeServicesCount"]}
        for c in details
    ]


def list_eks_clusters():
    eks = boto3.client("eks", region_name=REGION)
    names = []
    paginator = eks.get_paginator("list_clusters")
    for page in paginator.paginate():
        names.extend(page["clusters"])
    return [{"ClusterName": n} for n in names]


def list_cloudformation_stacks():
    cf = boto3.client("cloudformation", region_name=REGION)
    stacks = []
    paginator = cf.get_paginator("list_stacks")
    active_statuses = [
        "CREATE_COMPLETE", "UPDATE_COMPLETE", "ROLLBACK_COMPLETE",
        "UPDATE_ROLLBACK_COMPLETE", "IMPORT_COMPLETE",
    ]
    for page in paginator.paginate(StackStatusFilter=active_statuses):
        for stack in page["StackSummaries"]:
            stacks.append({
                "StackName":   stack["StackName"],
                "Status":      stack["StackStatus"],
                "CreationTime": str(stack["CreationTime"]),
            })
    return stacks


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _tag(resource: dict, key: str, default: str = "") -> str:
    """Extract a tag value from an AWS resource dict."""
    return next(
        (t["Value"] for t in resource.get("Tags", []) if t["Key"] == key),
        default,
    )
