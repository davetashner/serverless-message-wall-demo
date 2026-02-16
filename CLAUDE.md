# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## TL;DR — Critical Rules

**Before you do anything else**, know these rules:

| Rule | Details |
|------|---------|
| **Commit format** | `type(scope): Subject` — Conventional Commits enforced by hook |
| **Types** | `feat`, `fix`, `docs`, `refactor`, `chore`, `test`, `ci` |
| **Review before push** | Run `./scripts/review-changes.sh` to self-review |
| **After creating PR** | Run `./scripts/pr-feedback-loop.sh <PR#>` to handle review feedback |
| **PR evidence** | Non-docs PRs must have `## Evidence` section |
| **Backlog updates** | Update `beads/backlog.jsonl` when completing issues |
| **Don't modify backlog** | Without user approval |
| **Read current-focus.md** | For session handoff notes and what's blocked |

**Quick workflow:**
```bash
./scripts/review-changes.sh           # Before pushing
git push && gh pr create ...          # Create PR
./scripts/pr-feedback-loop.sh 42      # Handle review feedback
```

---

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
- **ConfigHub**: Authoritative store for fully-expanded Crossplane managed resources (ADR-014)
- **ArgoCD**: Syncs configuration from ConfigHub to Kubernetes via CMP plugin

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

# Phase 5: Install ConfigHub worker (optional, for ConfigHub sync)
cub worker create --space messagewall-dev actuator-sync --allow-exists
cub worker install actuator-sync --space messagewall-dev --provider-types kubernetes --export --include-secret | kubectl apply -f -

# Phase 6: Install ArgoCD (optional, for observability)
scripts/bootstrap-argocd.sh

# Render Composition (expands Claim → 19 managed resource YAMLs via crossplane render)
scripts/render-composition.sh --overlay dev-east --output-dir rendered/dev-east

# Validate rendered resources
scripts/validate-policies.sh rendered/dev-east

# Build Lambda artifacts
cd app/api-handler && ./build.sh
cd app/snapshot-writer && ./build.sh

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

## Project Context

Stable context that informs decision-making across sessions:

- **ConfigHub** is a configuration authority product built by the repo owner (Steve/Dave). It provides versioned configuration storage, policy enforcement, and controlled deployment. Think of it as "the source of truth for what should be deployed."
- **Target audience** for this demo is platform engineers and infrastructure teams evaluating control planes for cloud resource management.
- **The agent future** — This project is explicitly designing for a world where AI agents propose and execute infrastructure changes. EPIC-15 and related work anticipates high agent-driven change velocity and the need for machine-verifiable safety guarantees.
- **Why Crossplane?** — It provides a Kubernetes-native way to manage cloud resources declaratively, fitting the "actuator-only" principle. The XRD abstraction (EPIC-11) hides AWS complexity from developers.
- **Why not Terraform?** — State file management, lack of continuous reconciliation, and poor fit for the Kubernetes-native control plane model.

## Issue Tracking

This project uses [Beads](https://github.com/steveyegge/beads) for issue tracking. Issues are stored in `beads/backlog.jsonl`.

```bash
bd list              # View all issues
bd show <issue-id>   # View issue details
bd create "title"    # Create new issue
bd update <id> --status in_progress
```

### Commit Message Format

**All commits must follow [Conventional Commits](https://www.conventionalcommits.org/).** This is enforced by commitlint via husky hooks locally and GitHub Actions on PRs.

```
<type>(<scope>): <subject>
```

**Types:** `feat`, `fix`, `docs`, `refactor`, `chore`, `test`, `ci`

**Scope:** Use epic/issue ID or component name: `epic-11`, `issue-8.5`, `lambda`, `crossplane`, `backlog`

**Subject:** Imperative mood, sentence case, no period, max 72 chars.

**Examples:**
```bash
feat(issue-8.5): Add bulk configuration change demo
fix(lambda): Correct timeout handling in api-handler
docs(epic-15): Add Mermaid diagrams for approval workflow
chore(backlog): Update issue statuses for EPIC-14
```

See `CONTRIBUTING.md` for full details.

### PR Evidence Requirement

**PRs to main must include an `## Evidence` section** proving the change works (except docs-only changes). Examples:
- Test output
- Command output showing the feature works
- Screenshot or link to CI run

This is enforced by GitHub Actions. See `CONTRIBUTING.md` for details.

### Before Pushing to Main

**Always update `beads/backlog.jsonl` before pushing to main.** When completing work on an issue:

1. Mark the issue status as `"done"` in `beads/backlog.jsonl`
2. If all issues in an epic are done, mark the epic status as `"done"`
3. Include the backlog update in the same commit or PR as the completed work

This keeps the backlog in sync with actual progress and avoids orphaned "pending" issues for completed work.

## Architecture Decision Records

Key technical decisions are documented in `docs/decisions/`:
- **ADR-001**: AWS Region (us-east-1)
- **ADR-002**: S3 Static Website Hosting
- **ADR-003**: Lambda Artifact Storage (same bucket as static site)
- **ADR-004**: DynamoDB Single-Table Schema
- **ADR-005**: ConfigHub Integration Architecture
- **ADR-006**: Crossplane Installation and AWS IAM Strategy
- **ADR-007**: Kyverno Policy Enforcement for AWS Resource Tags
- **ADR-008**: Setup Wizard Design
- **ADR-009**: ArgoCD Config Management Plugin for ConfigHub Sync
- **ADR-010**: ConfigHub Stores Claims (not expanded resources)
- **ADR-011**: Bidirectional GitOps with ConfigHub as Authority
- **ADR-012**: Developer Authoring Surface (Claims as canonical)
- **ADR-013**: ConfigHub Multi-Tenancy Model (space-per-team-per-env)
- **ADR-014**: ConfigHub Stores Expanded Resources (supersedes ADR-010)

## Directory Structure

- `app/` - Lambda handlers (Python) and static web assets
- `infra/` - Crossplane manifests for AWS resources (base + env overlays)
- `platform/` - Crossplane installation manifests (crossplane/, kyverno/, argocd/, iam/)
- `scripts/` - Deployment and operational scripts
- `beads/` - Issue tracking (backlog.jsonl, principles.md, current-focus.md)
- `docs/decisions/` - Architecture Decision Records

## Documentation

- `docs/setup-actuator-cluster.md` - Step-by-step guide to set up the actuator cluster
- `docs/demo-guide.md` - Demo talking points, commands, and common questions

## Agentic Workflow Scripts

Scripts for AI-assisted development workflow:

```bash
# Review your changes before pushing (uses Claude Code CLI, free with Max)
./scripts/review-changes.sh

# Review and auto-fix any issues found
./scripts/review-changes.sh --fix

# After pushing a PR, watch for review feedback and auto-address it
./scripts/pr-feedback-loop.sh <PR_NUMBER>
```

**Optional auto-review on push:** Enable with `chmod +x .husky/pre-push`

See `CONTRIBUTING.md` for full workflow documentation.

### After Creating a PR

**When you create or push a PR, always start the feedback loop:**

```bash
# After: gh pr create ... or git push for an existing PR
./scripts/pr-feedback-loop.sh <PR_NUMBER>
```

This monitors the PR for review comments and automatically addresses feedback until the PR is approved. The loop:
1. Polls for new review comments every 30 seconds
2. Invokes Claude Code to fix issues when feedback arrives
3. Commits and pushes the fixes
4. Exits when PR is approved (or after 10 iterations)

**Do not skip this step.** The feedback loop ensures PR review comments are addressed promptly.
