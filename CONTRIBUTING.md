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
| AI code review | Local (review-changes.sh) |
| AI code review (optional) | Pre-push hook |
| Branch naming | Advisory only |

## AI Code Review

Review your changes locally using Claude Code CLI (covered by your Max subscription):

```bash
# Review changes on current branch vs main
./scripts/review-changes.sh

# Review and offer to fix issues automatically
./scripts/review-changes.sh --fix

# Compare against a different branch
./scripts/review-changes.sh --base develop
```

**Review verdicts:**
- `APPROVE` — Changes look good, push away
- `COMMENT` — Suggestions but not blocking
- `REQUEST_CHANGES` — Issues to fix before pushing

### Optional: Automatic Review on Push

Enable the pre-push hook to review automatically before every push:

```bash
chmod +x .husky/pre-push
```

This blocks pushes if the review returns `REQUEST_CHANGES`. Disable with:
```bash
chmod -x .husky/pre-push
```

### CI-Based Review (Optional)

For teams with Anthropic API access, there's also a GitHub Action workflow (`claude-pr-review.yml`) that can review PRs in CI. It's disabled by default to avoid API costs. See the workflow file to enable it.

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

## PR Feedback Loop

After pushing a PR, you can run an automated feedback loop that watches for review comments and invokes Claude Code to address them:

```bash
# Start the feedback loop for PR #42
./scripts/pr-feedback-loop.sh 42

# With options
./scripts/pr-feedback-loop.sh 42 --interval 60 --max-iterations 5

# Dry run (see what would happen)
./scripts/pr-feedback-loop.sh 42 --dry-run
```

**How it works:**
1. Checks out the PR branch
2. Polls GitHub for new review comments
3. When feedback is found, invokes Claude Code to address it
4. Commits and pushes the fixes
5. Repeats until PR is approved or max iterations reached

**Requirements:**
- `gh` CLI installed and authenticated
- `claude` CLI installed (Claude Code)
- `jq` installed

**Configuration:**
| Option | Environment Variable | Default | Description |
|--------|---------------------|---------|-------------|
| `--interval` | `POLL_INTERVAL` | 30 | Seconds between checks |
| `--max-iterations` | `MAX_ITERATIONS` | 10 | Max feedback rounds |

Press `Ctrl+C` to exit the loop at any time.
