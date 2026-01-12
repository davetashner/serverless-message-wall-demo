"""
API Handler Lambda for Message Wall

Handles POST requests from the browser:
1. Increments messageCount in DynamoDB METADATA record
2. Stores the message in DynamoDB with PK=MESSAGE, SK=<timestamp>#<uuid>
3. Emits an EventBridge event to trigger snapshot-writer

Note: CORS is handled by the Lambda Function URL configuration.
"""

import base64
import json
import os
import uuid
from datetime import datetime, timezone

import boto3

# Initialize AWS clients
dynamodb = boto3.resource("dynamodb")
events = boto3.client("events")

# Configuration from environment variables
TABLE_NAME = os.environ.get("TABLE_NAME", "messagewall-demo-dev")
EVENT_BUS_NAME = os.environ.get("EVENT_BUS_NAME", "default")


def handler(event, context):
    """Lambda handler for API requests."""
    # Handle CORS preflight
    if event.get("requestContext", {}).get("http", {}).get("method") == "OPTIONS":
        return response(200, "")

    # Only accept POST
    method = event.get("requestContext", {}).get("http", {}).get("method", "")
    if method != "POST":
        return response(405, {"error": "Method not allowed"})

    # Parse request body (may be base64 encoded by Function URL)
    try:
        raw_body = event.get("body", "{}")
        if event.get("isBase64Encoded", False):
            raw_body = base64.b64decode(raw_body).decode("utf-8")
        body = json.loads(raw_body)
        message_text = body.get("text", "").strip()
    except (json.JSONDecodeError, ValueError):
        return response(400, {"error": "Invalid JSON"})

    if not message_text:
        return response(400, {"error": "Message text is required"})

    # Limit message length
    if len(message_text) > 500:
        return response(400, {"error": "Message too long (max 500 chars)"})

    table = dynamodb.Table(TABLE_NAME)
    now = datetime.now(timezone.utc)
    timestamp = now.strftime("%Y-%m-%dT%H:%M:%S.%fZ")
    message_id = str(uuid.uuid4())
    sort_key = f"{timestamp}#{message_id}"

    try:
        # Increment message count in METADATA record
        table.update_item(
            Key={"PK": "METADATA", "SK": "METADATA"},
            UpdateExpression="SET messageCount = if_not_exists(messageCount, :zero) + :inc",
            ExpressionAttributeValues={":zero": 0, ":inc": 1},
        )

        # Store the message
        table.put_item(
            Item={
                "PK": "MESSAGE",
                "SK": sort_key,
                "text": message_text,
                "createdAt": timestamp,
            }
        )

        # Emit EventBridge event to trigger snapshot update
        events.put_events(
            Entries=[
                {
                    "Source": "messagewall.api-handler",
                    "DetailType": "MessagePosted",
                    "Detail": json.dumps(
                        {
                            "messageId": message_id,
                            "timestamp": timestamp,
                        }
                    ),
                    "EventBusName": EVENT_BUS_NAME,
                }
            ]
        )

        return response(
            200,
            {
                "success": True,
                "messageId": message_id,
                "timestamp": timestamp,
            },
        )

    except Exception as e:
        print(f"Error processing request: {e}")
        return response(500, {"error": "Internal server error"})


def response(status_code, body):
    """Return JSON response. CORS is handled by Function URL."""
    return {
        "statusCode": status_code,
        "headers": {
            "Content-Type": "application/json",
        },
        "body": json.dumps(body) if isinstance(body, dict) else body,
    }
