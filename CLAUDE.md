# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a serverless message wall demo application deployed on AWS using Crossplane as the infrastructure actuator running in Kubernetes. The key architectural constraint is that **Kubernetes runs only Crossplane controllers** — no application code runs in the cluster.

## Architecture

```
Browser → Lambda Function URL → DynamoDB → EventBridge → Snapshot Lambda → S3
Browser ← GET state.json ← S3
```

- **api-handler Lambda**: Receives POST requests, updates DynamoDB, emits EventBridge events
- **snapshot-writer Lambda**: Triggered by EventBridge, reads DynamoDB, writes state.json to S3
- **S3**: Hosts static website, state.json snapshot, and Lambda artifacts (in `artifacts/` prefix)
- **Crossplane**: Manages all AWS resources declaratively from Kubernetes
- **ConfigHub** (future): Authoritative store for rendered Crossplane manifests; actuator pulls from ConfigHub

## Build and Deploy Commands

See `docs/setup-actuator-cluster.md` for detailed setup instructions.

```bash
# Phase 1: AWS IAM setup (one-time, see docs/setup-actuator-cluster.md)
# Phase 2: Create local actuator cluster (kind)
scripts/bootstrap-kind.sh

# Phase 3: Install Crossplane
scripts/bootstrap-crossplane.sh
scripts/bootstrap-aws-providers.sh

# Phase 4: Install Kyverno
scripts/bootstrap-kyverno.sh

# Build Lambda artifacts (future)
cd app/api-handler && ./build.sh
cd app/snapshot-writer && ./build.sh

# Deploy infrastructure to AWS via Crossplane (future)
scripts/deploy-dev.sh

# Upload static website (future)
aws s3 sync app/web s3://<bucket-name>

# Verify deployment (future)
scripts/smoke-test.sh

# Tear down all resources (future)
scripts/cleanup.sh
```

## Project Principles

- Kubernetes is actuator-only (no app runtime)
- AWS managed services only
- Event-driven, not synchronous chains
- Demo-first, not production-hardening-first

## Issue Tracking

This project uses [Beads](https://github.com/steveyegge/beads) for issue tracking. Issues are stored in `beads/backlog.jsonl`.

```bash
bd list              # View all issues
bd show <issue-id>   # View issue details
bd create "title"    # Create new issue
bd update <id> --status in_progress
```

## Architecture Decision Records

Key technical decisions are documented in `docs/decisions/`:
- **ADR-001**: AWS Region (us-east-1)
- **ADR-002**: S3 Static Website Hosting
- **ADR-003**: Lambda Artifact Storage (same bucket as static site)
- **ADR-004**: DynamoDB Single-Table Schema
- **ADR-005**: ConfigHub Integration Architecture
- **ADR-006**: Crossplane Installation and AWS IAM Strategy
- **ADR-007**: Kyverno Policy Enforcement for AWS Resource Tags

## Directory Structure

- `app/` - Lambda handlers (Python) and static web assets
- `infra/` - Crossplane manifests for AWS resources (base + env overlays)
- `platform/` - Crossplane installation manifests (crossplane/, kyverno/, iam/)
- `scripts/` - Deployment and operational scripts
- `beads/` - Issue tracking (backlog.jsonl, principles.md)
- `docs/decisions/` - Architecture Decision Records

## Documentation

- `docs/setup-actuator-cluster.md` - Step-by-step guide to set up the actuator cluster
- `docs/demo-guide.md` - Demo talking points, commands, and common questions
