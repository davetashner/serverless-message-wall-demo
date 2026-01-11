# ADR-001: AWS Region

## Status
Accepted

## Context
The demo requires deploying AWS resources (S3, DynamoDB, Lambda, EventBridge). We need to choose a consistent region for all resources.

## Decision
Use **us-east-1** for all AWS resources.

## Rationale
- us-east-1 is the oldest and most feature-complete AWS region
- S3 static website hosting has simpler URL patterns in us-east-1
- No specific latency or compliance requirements for this demo

## Consequences
- All Crossplane manifests will specify `region: us-east-1`
- AWS credentials must have permissions in us-east-1
