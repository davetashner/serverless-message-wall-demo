# Contributing Guidelines

This document defines standards for commits, pull requests, and branches in this repository.

## Commit Message Format

All commits must follow the [Conventional Commits](https://www.conventionalcommits.org/) specification:

```
<type>(<scope>): <subject>

[optional body]

[optional footer]
```

### Type (required)

| Type | Use Case |
|------|----------|
| `feat` | New feature or capability |
| `fix` | Bug fix |
| `docs` | Documentation only |
| `refactor` | Code restructure, no behavior change |
| `chore` | Maintenance, backlog updates, config |
| `test` | Adding or updating tests |
| `ci` | CI/CD configuration changes |

### Scope (recommended)

Reference the epic, issue, or component:

- Epic: `epic-11`, `epic-17`
- Issue: `issue-13.3`, `issue-8.5`
- Component: `lambda`, `crossplane`, `confighub`, `kyverno`, `argocd`
- Other: `backlog`, `docs`, `ci`

### Subject Rules

| Rule | Example |
|------|---------|
| Use imperative mood | "Add feature" not "Added feature" |
| Use sentence case | "Add policy validation" not "add policy validation" |
| No period at end | "Add X" not "Add X." |
| Max 72 characters | Keep it concise |

### Examples

```bash
# Feature with issue reference
feat(issue-8.5): Add bulk configuration change demo

# Bug fix
fix(lambda): Correct timeout handling in api-handler

# Documentation
docs(epic-15): Add Mermaid diagrams for approval workflow

# Chore/maintenance
chore(backlog): Update issue statuses for EPIC-14

# Multiple issues (use footer)
feat(epic-14): Add policy guardrails

Implements tag validation and IAM wildcard blocking.

Closes ISSUE-14.1, ISSUE-14.2
```

### Validation

Commit messages are validated locally by [commitlint](https://commitlint.js.org/) via [husky](https://typicode.github.io/husky/) git hooks. Invalid commits will be rejected.

To bypass in emergencies (not recommended):
```bash
git commit --no-verify -m "message"
```

## Pull Request Standards

### Title

Use the same format as commit subjects:
```
<type>(<scope>): <subject>
```

### Body Template

PRs must include the following sections:

```markdown
## Summary
<1-3 bullet points describing what changed and why>

## Evidence
<Proof that the change works - see Evidence Requirements below>

## Test Plan
<Steps to verify the change>
```

### Evidence Requirements

**All PRs to main must include evidence that the change is valid**, except for documentation-only changes (`docs` type).

| Change Type | Required Evidence |
|-------------|-------------------|
| `feat` | Test output, screenshot, or demo command output |
| `fix` | Before/after showing the fix, or test proving the bug is fixed |
| `refactor` | Test output showing behavior unchanged |
| `test` | Test execution output |
| `chore` | Validation output (e.g., lint passing, config valid) |
| `ci` | Workflow run link or dry-run output |
| `docs` | No evidence required |

**Evidence Examples:**

```markdown
## Evidence

### Test output
$ npm test
✓ All 42 tests passed

### Command output
$ kubectl get pods -n crossplane-system
NAME                                      READY   STATUS    RESTARTS   AGE
crossplane-7d4b5c8f9d-xxxxx              1/1     Running   0          5m

### Screenshot
![Feature working](./screenshot.png)
```

### Labels

Apply appropriate labels:
- Epic: `epic-11`, `epic-17`, etc.
- Type: `type:feat`, `type:fix`, `type:docs`, etc.

## Branch Naming

```
<type>/<issue-id>-<short-description>
```

**Examples:**
```
feat/issue-17.3-delete-gates
fix/issue-21.2-metrics-export
docs/epic-15-diagrams
chore/update-dependencies
```

## Enforcement

| Check | Enforcement Point |
|-------|-------------------|
| Commit message format | Local (husky + commitlint) |
| Commit message format | PR (GitHub Action) |
| PR evidence section | PR (GitHub Action) |
| AI code review | PR (GitHub Action) |
| Branch naming | Advisory only |

## AI Code Review

All PRs are automatically reviewed by Claude via the `claude-pr-review.yml` workflow. The AI reviewer:

- Checks code against project standards (this document + CLAUDE.md)
- Looks for bugs, security issues, and architectural violations
- Verifies commit message format
- Assesses evidence/testing adequacy

**Review verdicts:**
- `APPROVE` — Changes look good
- `COMMENT` — Suggestions but not blocking
- `REQUEST_CHANGES` — Issues that should be addressed

**To skip AI review:** Add the `skip-ai-review` label to the PR.

**Setup (maintainers):** The workflow requires an `ANTHROPIC_API_KEY` secret in the repository settings.

## Setup for Contributors

After cloning, install git hooks:

```bash
npm install
```

This automatically sets up husky hooks via the `prepare` script.

## AI-Assisted Commits

When commits are authored or co-authored by AI agents, include the co-author footer:

```
feat(issue-8.5): Add bulk configuration demo

Co-Authored-By: Claude <noreply@anthropic.com>
```
