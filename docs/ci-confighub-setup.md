# CI Setup for ConfigHub Publishing

This guide explains how to set up the GitHub Action that publishes Crossplane manifests to ConfigHub.

## Overview

The workflow (`.github/workflows/confighub-publish.yml`) does:
- **On PR**: Preview what would change (dry-run)
- **On push to main**: Publish rendered manifests to ConfigHub

## Prerequisites

1. A ConfigHub account with access to the `messagewall-dev` space
2. Admin access to the GitHub repository

## Setup Steps

### 1. Create a ConfigHub Worker for CI

Workers are service accounts for automation. Create one for GitHub Actions:

```bash
# Create the worker
cub worker create --space messagewall-dev github-ci

# Get the worker credentials (save these securely!)
cub worker get-secret --space messagewall-dev github-ci
```

This outputs the worker ID and secret. **Save these immediately** - the secret cannot be retrieved again.

### 2. Add GitHub Secrets

Go to your repository's **Settings > Secrets and variables > Actions** and add:

| Secret Name | Value |
|-------------|-------|
| `CONFIGHUB_WORKER_ID` | The worker ID from step 1 |
| `CONFIGHUB_WORKER_SECRET` | The worker secret from step 1 |

### 3. Verify Setup

Create a PR that modifies any file in `infra/base/` or `config/`. The workflow should:
1. Render the templates
2. Show a preview of what would change in ConfigHub
3. Post results to the GitHub Actions summary

On merge to main, the workflow will actually publish the changes.

## Configuration

Environment-specific values are in `config/<env>.env`:

```bash
# config/dev.env
AWS_ACCOUNT_ID=205074708100
AWS_REGION=us-east-1
RESOURCE_PREFIX=messagewall
ENVIRONMENT=dev
BUCKET_NAME=messagewall-demo-dev
CONFIGHUB_SPACE=messagewall-dev
```

To add a new environment (e.g., `prod`):
1. Create `config/prod.env` with production values
2. Create the ConfigHub space (e.g., `messagewall-prod`)
3. Add the space to the workflow's `environment` choices

## Troubleshooting

### "Worker not found" error
Ensure the worker exists in the correct space:
```bash
cub worker list --space messagewall-dev
```

### "Permission denied" error
The worker may need additional permissions. Check worker permissions:
```bash
cub worker get --space messagewall-dev github-ci
```

### Workflow not triggering
The workflow only runs when files in these paths change:
- `infra/base/**`
- `config/**`
- `.github/workflows/confighub-publish.yml`
