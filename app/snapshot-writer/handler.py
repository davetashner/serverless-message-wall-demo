"""
Snapshot Writer Lambda for Message Wall

Triggered by EventBridge when a message is posted:
1. Reads messageCount from DynamoDB METADATA record
2. Queries the last 5 messages ordered by SK descending
3. Writes state.json to S3 for the browser to fetch
"""

import json
import os

import boto3

# Initialize AWS clients
dynamodb = boto3.resource("dynamodb")
s3 = boto3.client("s3")

# Configuration from environment variables
TABLE_NAME = os.environ.get("TABLE_NAME", "messagewall-demo-dev")
BUCKET_NAME = os.environ.get("BUCKET_NAME", "messagewall-demo-dev")
STATE_KEY = "state.json"


def handler(event, context):
    """Lambda handler for snapshot generation."""
    print(f"Received event: {json.dumps(event)}")

    table = dynamodb.Table(TABLE_NAME)

    try:
        # Get message count from METADATA record
        metadata_response = table.get_item(
            Key={"PK": "METADATA", "SK": "METADATA"},
            ProjectionExpression="messageCount",
        )
        message_count = metadata_response.get("Item", {}).get("messageCount", 0)

        # Query last 5 messages (ordered by SK descending)
        messages_response = table.query(
            KeyConditionExpression="PK = :pk",
            ExpressionAttributeValues={":pk": "MESSAGE"},
            ScanIndexForward=False,  # Descending order
            Limit=5,
            ProjectionExpression="SK, #txt, createdAt",
            ExpressionAttributeNames={"#txt": "text"},  # 'text' is reserved
        )

        messages = []
        for item in messages_response.get("Items", []):
            # Extract message ID from SK (format: timestamp#uuid)
            sk = item.get("SK", "")
            message_id = sk.split("#")[1] if "#" in sk else sk
            messages.append(
                {
                    "id": message_id,
                    "text": item.get("text", ""),
                    "createdAt": item.get("createdAt", ""),
                }
            )

        # Build state object
        state = {
            "messageCount": int(message_count),
            "messages": messages,
        }

        # Write to S3
        s3.put_object(
            Bucket=BUCKET_NAME,
            Key=STATE_KEY,
            Body=json.dumps(state, indent=2),
            ContentType="application/json",
            CacheControl="no-cache, no-store, must-revalidate",
        )

        print(f"Wrote state.json: {message_count} total messages, {len(messages)} recent")

        return {
            "statusCode": 200,
            "body": json.dumps({"success": True, "messageCount": int(message_count)}),
        }

    except Exception as e:
        print(f"Error generating snapshot: {e}")
        raise
