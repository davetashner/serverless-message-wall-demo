# ADR-006: Crossplane Installation and AWS IAM Strategy

## Status
Accepted

## Context
We need to install Crossplane in the local kind cluster and configure it to manage AWS resources. Key concerns:
- This is a personal AWS account where blast radius matters
- The local kind cluster is low-risk but we still want defense in depth
- Crossplane needs to create IAM roles for Lambda, which requires careful scoping

## Decisions

### 1. Crossplane Installation: Helm

Use Helm to install Crossplane. This is the standard approach with the best documentation and upgrade path.

```bash
helm repo add crossplane-stable https://charts.crossplane.io/stable
helm install crossplane crossplane-stable/crossplane --namespace crossplane-system --create-namespace
```

### 2. AWS Provider: Family Providers (Not Monolithic)

Use modular family providers instead of the monolithic `provider-aws`:

| Provider | Purpose |
|----------|---------|
| `provider-aws-s3` | S3 bucket, bucket policy, website config |
| `provider-aws-dynamodb` | DynamoDB table |
| `provider-aws-lambda` | Lambda functions, function URLs |
| `provider-aws-cloudwatchevents` | EventBridge rules and targets |
| `provider-aws-iam` | IAM roles and policies |

**Rationale:**
- Lower memory footprint (~200MB vs ~1GB for monolithic)
- Faster startup
- Install only what's needed

### 3. Credentials: Static Credentials in Kubernetes Secret

For local kind cluster, use static credentials stored in a Kubernetes Secret.

```bash
kubectl create secret generic aws-credentials \
  -n crossplane-system \
  --from-literal=credentials="[default]
aws_access_key_id = <ACCESS_KEY>
aws_secret_access_key = <SECRET_KEY>"
```

The ProviderConfig references this secret.

**Note:** For production/EKS, use IRSA or Pod Identity instead.

### 4. Resource Naming Convention

All AWS resources created by Crossplane will use the prefix `messagewall-`:
- `messagewall-bucket`
- `messagewall-table`
- `messagewall-api-handler`
- `messagewall-snapshot-writer`
- `messagewall-api-role`
- `messagewall-snapshot-role`

This enables IAM policies to scope permissions to these resources.

### 5. IAM Strategy: Dedicated User + Permission Boundary

#### 5a. Crossplane IAM User

Create a dedicated IAM user `crossplane-actuator` with an inline policy that:
- Allows managing `messagewall-*` resources
- Allows creating IAM roles only with a specific permission boundary attached
- Denies privilege escalation

#### 5b. Permission Boundary

Create a permission boundary `MessageWallRoleBoundary` that caps what any Crossplane-created role can do:
- S3: read/write to `messagewall-*` buckets only
- DynamoDB: read/write to `messagewall-*` tables only
- EventBridge: put events
- CloudWatch Logs: create/write logs

This prevents Crossplane from creating overprivileged roles even if compromised.

#### 5c. IAM Policy for crossplane-actuator User

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "S3Management",
      "Effect": "Allow",
      "Action": [
        "s3:CreateBucket",
        "s3:DeleteBucket",
        "s3:PutBucketPolicy",
        "s3:DeleteBucketPolicy",
        "s3:GetBucketPolicy",
        "s3:PutBucketWebsite",
        "s3:GetBucketWebsite",
        "s3:DeleteBucketWebsite",
        "s3:PutBucketPublicAccessBlock",
        "s3:GetBucketPublicAccessBlock",
        "s3:PutObject",
        "s3:GetObject",
        "s3:DeleteObject",
        "s3:ListBucket",
        "s3:GetBucketLocation",
        "s3:GetBucketAcl",
        "s3:PutBucketAcl",
        "s3:PutBucketOwnershipControls",
        "s3:GetBucketOwnershipControls"
      ],
      "Resource": [
        "arn:aws:s3:::messagewall-*",
        "arn:aws:s3:::messagewall-*/*"
      ]
    },
    {
      "Sid": "DynamoDBManagement",
      "Effect": "Allow",
      "Action": [
        "dynamodb:CreateTable",
        "dynamodb:DeleteTable",
        "dynamodb:DescribeTable",
        "dynamodb:UpdateTable",
        "dynamodb:TagResource",
        "dynamodb:UntagResource",
        "dynamodb:ListTagsOfResource"
      ],
      "Resource": "arn:aws:dynamodb:us-east-1:*:table/messagewall-*"
    },
    {
      "Sid": "LambdaManagement",
      "Effect": "Allow",
      "Action": [
        "lambda:CreateFunction",
        "lambda:DeleteFunction",
        "lambda:GetFunction",
        "lambda:GetFunctionConfiguration",
        "lambda:UpdateFunctionCode",
        "lambda:UpdateFunctionConfiguration",
        "lambda:AddPermission",
        "lambda:RemovePermission",
        "lambda:GetPolicy",
        "lambda:CreateFunctionUrlConfig",
        "lambda:DeleteFunctionUrlConfig",
        "lambda:GetFunctionUrlConfig",
        "lambda:UpdateFunctionUrlConfig",
        "lambda:TagResource",
        "lambda:UntagResource",
        "lambda:ListTags"
      ],
      "Resource": "arn:aws:lambda:us-east-1:*:function:messagewall-*"
    },
    {
      "Sid": "EventBridgeManagement",
      "Effect": "Allow",
      "Action": [
        "events:PutRule",
        "events:DeleteRule",
        "events:DescribeRule",
        "events:EnableRule",
        "events:DisableRule",
        "events:PutTargets",
        "events:RemoveTargets",
        "events:ListTargetsByRule",
        "events:TagResource",
        "events:UntagResource"
      ],
      "Resource": "arn:aws:events:us-east-1:*:rule/messagewall-*"
    },
    {
      "Sid": "CloudWatchLogsManagement",
      "Effect": "Allow",
      "Action": [
        "logs:CreateLogGroup",
        "logs:DeleteLogGroup",
        "logs:DescribeLogGroups",
        "logs:PutRetentionPolicy",
        "logs:TagLogGroup",
        "logs:UntagLogGroup"
      ],
      "Resource": "arn:aws:logs:us-east-1:*:log-group:/aws/lambda/messagewall-*"
    },
    {
      "Sid": "IAMRoleManagement",
      "Effect": "Allow",
      "Action": [
        "iam:CreateRole",
        "iam:DeleteRole",
        "iam:GetRole",
        "iam:UpdateRole",
        "iam:TagRole",
        "iam:UntagRole",
        "iam:PutRolePolicy",
        "iam:DeleteRolePolicy",
        "iam:GetRolePolicy",
        "iam:AttachRolePolicy",
        "iam:DetachRolePolicy",
        "iam:ListRolePolicies",
        "iam:ListAttachedRolePolicies"
      ],
      "Resource": "arn:aws:iam::*:role/messagewall-*",
      "Condition": {
        "StringEquals": {
          "iam:PermissionsBoundary": "arn:aws:iam::*:policy/MessageWallRoleBoundary"
        }
      }
    },
    {
      "Sid": "IAMPassRole",
      "Effect": "Allow",
      "Action": "iam:PassRole",
      "Resource": "arn:aws:iam::*:role/messagewall-*",
      "Condition": {
        "StringEquals": {
          "iam:PassedToService": "lambda.amazonaws.com"
        }
      }
    },
    {
      "Sid": "IAMBoundaryRead",
      "Effect": "Allow",
      "Action": [
        "iam:GetPolicy",
        "iam:GetPolicyVersion"
      ],
      "Resource": "arn:aws:iam::*:policy/MessageWallRoleBoundary"
    }
  ]
}
```

#### 5d. Permission Boundary Policy (MessageWallRoleBoundary)

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "S3Access",
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject",
        "s3:ListBucket"
      ],
      "Resource": [
        "arn:aws:s3:::messagewall-*",
        "arn:aws:s3:::messagewall-*/*"
      ]
    },
    {
      "Sid": "DynamoDBAccess",
      "Effect": "Allow",
      "Action": [
        "dynamodb:GetItem",
        "dynamodb:PutItem",
        "dynamodb:UpdateItem",
        "dynamodb:DeleteItem",
        "dynamodb:Query",
        "dynamodb:Scan"
      ],
      "Resource": "arn:aws:dynamodb:us-east-1:*:table/messagewall-*"
    },
    {
      "Sid": "EventBridgeAccess",
      "Effect": "Allow",
      "Action": "events:PutEvents",
      "Resource": "*"
    },
    {
      "Sid": "CloudWatchLogsAccess",
      "Effect": "Allow",
      "Action": [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ],
      "Resource": "arn:aws:logs:us-east-1:*:log-group:/aws/lambda/messagewall-*:*"
    }
  ]
}
```

## Setup Steps

1. Create the permission boundary policy `MessageWallRoleBoundary` in AWS
2. Create the IAM user `crossplane-actuator` with the policy above
3. Generate access keys for the user
4. Store credentials in Kubernetes secret

## Consequences

- Crossplane can only manage `messagewall-*` resources
- Crossplane can only create IAM roles that have the permission boundary attached
- Lambda execution roles are capped to only access messagewall resources
- If Crossplane is compromised, blast radius is limited to this demo's resources
- Manual setup required before first Crossplane use (create boundary policy and user)

## Alternatives Considered

1. **Broad permissions**: Rejected due to personal account blast radius concerns
2. **Dedicated AWS account**: Overkill for a demo, but would be cleaner
3. **Terraform for IAM setup**: Could automate the bootstrap, but adds complexity
