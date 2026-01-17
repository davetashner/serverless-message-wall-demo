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

## Deployment Prerequisites

### Required Tools

- `kubectl`
- `kind`
- `aws` CLI (with valid credentials)
- Docker (for building Lambda artifacts)
- Python 3.x (for Lambda code)

### AWS Requirements

- An AWS account
- IAM credentials with permission to create:
  - S3 buckets
  - DynamoDB tables
  - Lambda functions
  - EventBridge rules
  - IAM roles/policies

---

## Deployment Steps

### 1. Create Actuator Cluster

```bash
scripts/bootstrap-kind.sh
```

### 2. Install Crossplane and AWS Provider

```bash
scripts/bootstrap-crossplane.sh
```

### 3. Build Lambda Artifacts

```bash
cd app/api-handler && ./build.sh
cd ../snapshot-writer && ./build.sh
```

Artifacts will be placed in app/artifacts/.

### 4. Deploy Infrastructure

```bash
scripts/deploy-dev.sh
```

This applies Crossplane manifests that create all AWS resources.

### 5. Upload Static Website

```bash
aws s3 sync app/web s3://<bucket-name>
```

The bucket name is printed during deployment.

### 6. Verify Deployment

```bash
scripts/smoke-test.sh
```

Or manually:
	1.	Open the S3 static site URL in a browser
	2.	Post a message
	3.	Refresh the page and observe updated state

### 7. Cleanup

To remove all resources:

```bash
scripts/cleanup.sh
```

This deletes Crossplane-managed resources safely.

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