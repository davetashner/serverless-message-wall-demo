# Serverless Message Wall Demo  
**AWS Serverless · Crossplane Actuator · Event-Driven · Browser-Based**

---

## Overview

`serverless-message-wall-demo` is a **simple, event-driven serverless application** designed to be:

- Easy to understand
- Easy to demo in a browser
- Fully deployed on **AWS managed services**
- Provisioned and reconciled via **Crossplane running in Kubernetes**
- Free of any application runtime inside Kubernetes (Kubernetes is **actuator only**)

The demo intentionally keeps the application logic small while still exercising real cloud-native patterns:
- Events instead of tight coupling
- Immutable infrastructure
- Declarative provisioning
- Clear separation between **authoring**, **control**, and **execution**

This repository is also structured to support **ConfigHub integration** as a follow-on step, enabling policy enforcement, bulk configuration changes, and drift control.

---

## What the Application Does

### Browser Experience

The application is a single static web page that shows:

- **Total visitor count**
- **The most recent messages** (e.g. last 5)
- A text box with a **“Post Message”** button

Users interact entirely through the browser.

### Functional Behavior

1. A user loads the page.
2. The page fetches a JSON snapshot (`state.json`) from S3.
3. When a user posts a message:
   - The browser sends a POST request to a Lambda Function URL.
   - The Lambda updates DynamoDB.
   - The Lambda emits an EventBridge event.
4. EventBridge triggers a second Lambda that:
   - Reads the latest data from DynamoDB.
   - Writes an updated `state.json` snapshot to S3.
5. The browser refreshes the view using the updated snapshot.

---

## High-Level Architecture

```
Browser
   |
   |  POST /message
   v
Lambda Function URL
   |
   |  PutItem / UpdateItem
   v
DynamoDB
   |
   |  PutEvents
   v
EventBridge
   |
   |  Rule match
   v
Snapshot Lambda
   |
   |  PutObject
   v
S3 (state.json)

Browser ───────────────► GET state.json
```

### Key Design Principles

- **Event-driven**: No direct Lambda-to-Lambda calls
- **Snapshot-based UI**: Browser reads from S3, not live databases
- **Actuator-only Kubernetes**: No app code runs in the cluster
- **Minimal moving parts**: No queues, retries, or orchestration layers

---

## AWS Services Used

| Service        | Purpose |
|---------------|--------|
| AWS Lambda | Application logic |
| Lambda Function URL | Browser-accessible API |
| DynamoDB | Visitor count + messages |
| EventBridge | Event routing |
| S3 | Static website + `state.json` |
| IAM | Least-privilege execution roles |
| CloudWatch Logs | Observability |

---

## Repository Structure

```
serverless-message-wall-demo/
├── README.md
├── beads/
│   └── backlog.jsonl          # Epics and issues (Beads format)
├── platform/
│   └── crossplane/
│       ├── install.yaml
│       ├── provider-aws.yaml
│       └── providerconfig.yaml
├── infra/
│   ├── base/
│   │   ├── s3.yaml
│   │   ├── dynamodb.yaml
│   │   ├── iam.yaml
│   │   ├── lambda-api.yaml
│   │   ├── lambda-snapshot.yaml
│   │   ├── eventbridge.yaml
│   └── envs/
│       └── dev/
│           ├── kustomization.yaml
│           └── patches.yaml
├── app/
│   ├── web/
│   │   ├── index.html
│   │   └── app.js
│   ├── api-handler/
│   │   ├── handler.py
│   │   └── build.sh
│   ├── snapshot-writer/
│   │   ├── handler.py
│   │   └── build.sh
│   └── artifacts/
│       ├── api-handler.zip
│       └── snapshot-writer.zip
└── scripts/
├── bootstrap-kind.sh
├── bootstrap-crossplane.sh
├── deploy-dev.sh
├── smoke-test.sh
└── cleanup.sh
```

---

## Kubernetes and Crossplane Role

Kubernetes is used **only** to run Crossplane and its controllers.

- No application containers
- No services, ingresses, or pods for the app
- Kubernetes credentials are never exposed to users

Crossplane is responsible for:
- Creating AWS resources
- Reconciling desired state
- Reporting readiness and failures

---

## Quick Start

### 1. Check Prerequisites

```bash
./scripts/check-prerequisites.sh
```

Required tools: Docker, kind, kubectl, helm, AWS CLI

### 2. Run the Setup Wizard

```bash
./scripts/setup.sh
```

The wizard will:
- Prompt for your AWS account ID (auto-detected from credentials)
- Ask for region, resource prefix, and environment name
- Generate all configuration files
- Offer to run the full deployment

Or, deploy everything in one command:

```bash
./scripts/setup.sh --deploy
```

### 3. Verify Deployment

```bash
./scripts/smoke-test.sh
```

### 4. Cleanup

```bash
./scripts/cleanup.sh
```

---

## Manual Deployment Steps

For more control, you can run each step manually:

### 1. Configure the Project

```bash
./scripts/setup.sh
```

### 2. Create IAM Resources (One-Time)

```bash
# Create permission boundary
aws iam create-policy \
  --policy-name MessageWallRoleBoundary \
  --policy-document file://platform/iam/messagewall-role-boundary.json

# Create Crossplane user and attach policy
# See docs/setup-actuator-cluster.md for full instructions
```

### 3. Bootstrap the Cluster

```bash
./scripts/bootstrap-kind.sh
./scripts/bootstrap-crossplane.sh
./scripts/bootstrap-aws-providers.sh
```

### 4. Deploy Infrastructure

```bash
./scripts/deploy-dev.sh
```

### 5. Finalize Web Application

```bash
./scripts/finalize-web.sh
```

This retrieves the Lambda Function URL and updates `index.html`.

### 6. Verify Deployment

```bash
./scripts/smoke-test.sh
```

Or manually:
1. Open the S3 static site URL in a browser
2. Post a message
3. Refresh the page and observe updated state

---

## Deployment Prerequisites

### Required Tools

- Docker (running)
- `kind` - Kubernetes in Docker
- `kubectl` - Kubernetes CLI
- `helm` - Kubernetes package manager
- `aws` CLI (with valid credentials)

Run `./scripts/check-prerequisites.sh` to verify.

### AWS Requirements

- An AWS account
- IAM credentials with permission to create:
  - S3 buckets
  - DynamoDB tables
  - Lambda functions
  - EventBridge rules
  - IAM roles/policies

## Extending the Demo

This demo is intentionally designed to evolve.

### Documented Extensions

- **Bulk Configuration Changes**: See `docs/bulk-changes-and-change-management.md` for detailed scenarios including security patching, risk mitigation strategies, and change management procedures
- **ConfigHub Integration**: See `docs/decisions/005-confighub-integration-architecture.md` for how ConfigHub fits into the deployment flow

### Future Extensions

- Add ConfigHub to manage resolved configuration
- Enforce IAM and security policies at the config layer
- Demonstrate bulk configuration changes via ConfigHub functions
- Add multiple environments (dev / stage / prod)
- Add CloudFront or WAF
- Add drift detection and reconciliation

## Why This Demo Exists

This repository exists to answer a simple question:

What does a modern, event-driven, serverless application look like when infrastructure is treated as data and Kubernetes is only the actuator?

The answer is:
	•	Simple
	•	Explicit
	•	Observable
	•	Evolvable