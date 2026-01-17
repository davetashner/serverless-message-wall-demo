# ADR-008: Setup Wizard for New Users

## Status
Accepted

## Context
New users cloning this repository cannot deploy it immediately because configuration values are hardcoded throughout the codebase:

- **AWS Account ID** appears in IAM policy ARNs (`infra/base/iam.yaml`)
- **S3 bucket name** appears in multiple files (must be globally unique)
- **AWS region** is hardcoded to `us-east-1`
- **Lambda Function URL** is hardcoded in the web app (`app/web/index.html`)

Additionally, the Lambda Function URL is only known after deployment, creating a chicken-and-egg problem for the web application.

We need a setup wizard that:
1. Collects required configuration from users
2. Generates properly configured files
3. Handles the two-phase deployment for Function URL
4. Validates AWS credentials and permissions
5. Provides a good developer experience for both interactive and CI/CD scenarios

## Decision

### 1. Configuration Values

The wizard will collect these values:

| Value | Required | Default | Validation |
|-------|----------|---------|------------|
| `AWS_ACCOUNT_ID` | Yes | Auto-detect via `aws sts get-caller-identity` | 12-digit number |
| `AWS_REGION` | No | `us-east-1` | Valid AWS region |
| `BUCKET_NAME` | Yes | None (must be unique) | S3 naming rules, 3-63 chars |
| `RESOURCE_PREFIX` | No | `messagewall` | Alphanumeric + hyphens |
| `ENVIRONMENT` | No | `dev` | Alphanumeric |

### 2. Template Approach: `envsubst` with `.template` Files

Use the standard Unix `envsubst` tool for templating.

**Rationale:**
- Available on all Unix systems (part of `gettext`)
- Simple variable substitution: `${VARIABLE}` syntax
- No external dependencies (Python, Node, etc.)
- Works well with YAML files

**Implementation:**
- Create `.template` files alongside source files (e.g., `iam.yaml.template`)
- Wizard generates actual files from templates
- Templates use `${VAR}` syntax, e.g., `arn:aws:iam::${AWS_ACCOUNT_ID}:policy/...`

**File structure after setup:**
```
infra/base/
├── iam.yaml.template    # Source template (version controlled)
├── iam.yaml             # Generated file (gitignored)
├── s3.yaml.template
├── s3.yaml
└── ...
```

### 3. Interaction Modes

#### Interactive Mode (Default)
```bash
./scripts/setup.sh
```
- Prompts for each value with sensible defaults
- Auto-detects AWS account ID from credentials
- Validates inputs before proceeding
- Shows summary before generating files

#### Non-Interactive Mode (CI/CD)
```bash
./scripts/setup.sh \
  --account-id 123456789012 \
  --bucket-name my-unique-bucket \
  --region us-west-2 \
  --non-interactive
```
- All required values via CLI flags
- Fails fast if any required value is missing
- No prompts; suitable for automation

#### Environment Variable Mode
```bash
export AWS_ACCOUNT_ID=123456789012
export BUCKET_NAME=my-unique-bucket
./scripts/setup.sh --non-interactive
```
- Values from environment variables
- CLI flags override environment variables

### 4. Two-Phase Deployment for Function URL

The Lambda Function URL is only known after the `FunctionUrl` Crossplane resource is created and reconciled. The web app (`index.html`) needs this URL to make API calls.

**Solution: Post-deployment finalization script**

1. **Phase 1: Initial deployment** (`scripts/deploy-dev.sh`)
   - Deploys all infrastructure including Lambda and FunctionUrl
   - Uploads `index.html` with placeholder API URL (`__API_URL__`)

2. **Phase 2: Finalization** (`scripts/finalize-web.sh`)
   - Queries the actual Function URL from Kubernetes/AWS
   - Substitutes the placeholder in `index.html`
   - Re-uploads the updated file to S3

**Why not deploy twice?**
- Simpler mental model: deploy once, finalize once
- The placeholder approach makes it clear when finalization is needed
- Finalization can be re-run safely (idempotent)

**Alternative considered: Relative URL**
- Not feasible: S3 static hosting and Lambda Function URL are different origins
- CORS is already configured, but the browser needs the full URL

### 5. Validation Strategy

#### Pre-flight Checks (`scripts/setup.sh`)
- AWS CLI is installed and configured
- Required tools available (`kubectl`, `kind`, `envsubst`)
- AWS credentials are valid (can call STS)
- S3 bucket name is available (not taken)

#### AWS Permission Validation (`scripts/validate-aws.sh`)
- Tests that the IAM user/role can perform required operations
- Checks for `MessageWallRoleBoundary` policy existence
- Validates Crossplane IAM user permissions
- Reports specific missing permissions

### 6. Re-run Detection and Warning

The wizard tracks its state in `.setup-state.json`:

```json
{
  "version": 1,
  "completed_at": "2024-01-15T10:30:00Z",
  "config": {
    "aws_account_id": "123456789012",
    "bucket_name": "my-messagewall-bucket",
    "region": "us-east-1"
  }
}
```

**Re-run behavior:**
- If `.setup-state.json` exists, warn user and show previous config
- Offer to: (a) keep existing config, (b) reconfigure, (c) abort
- In non-interactive mode with existing config, fail unless `--force` flag

### 7. Dry-Run Mode

```bash
./scripts/setup.sh --dry-run
```
- Shows what files would be generated
- Shows what values would be substituted
- Does not write any files
- Validates all inputs as normal

### 8. Prerequisite Checker

```bash
./scripts/check-prerequisites.sh
```

Checks for:
- Docker (running)
- kind
- kubectl
- AWS CLI (v2)
- Helm
- envsubst
- Valid AWS credentials
- Required AWS permissions (optional deep check with `--validate-aws`)

Output format:
```
Checking prerequisites...
✓ Docker: running (v24.0.7)
✓ kind: installed (v0.20.0)
✓ kubectl: installed (v1.28.0)
✓ AWS CLI: installed (v2.15.0)
✓ Helm: installed (v3.14.0)
✓ envsubst: available
✓ AWS credentials: valid (account 123456789012)

All prerequisites satisfied.
```

## Implementation Files

| File | Purpose |
|------|---------|
| `scripts/setup.sh` | Main setup wizard |
| `scripts/finalize-web.sh` | Post-deployment Function URL substitution |
| `scripts/validate-aws.sh` | AWS permission validation |
| `scripts/check-prerequisites.sh` | Prerequisite checker |
| `.setup-state.json` | Setup state tracking (gitignored) |
| `infra/base/*.template` | Template files for Crossplane manifests |
| `app/web/index.html.template` | Template for web app |

## Consequences

### Positive
- New users can deploy with minimal friction
- CI/CD pipelines can configure non-interactively
- Dry-run mode prevents accidents
- Re-run detection prevents configuration drift
- Clear separation between templates (source) and generated files

### Negative
- Two-phase deployment adds complexity
- Users must remember to run finalize script
- Template files add to repository file count
- envsubst requires gettext package on some systems

### Mitigations
- `deploy-dev.sh` will print reminder about finalization
- Could add `deploy-all.sh` that runs both phases
- envsubst is widely available and can be installed easily

## Alternatives Considered

1. **Kustomize for templating**: More powerful but adds dependency; overkill for simple variable substitution
2. **Helm for infrastructure**: Crossplane manifests aren't Helm charts; would require restructuring
3. **JSON config file**: Harder to edit than CLI flags/env vars; adds indirection
4. **Interactive wizard only**: Blocks CI/CD adoption
5. **Hardcode account ID in repo**: Prevents anyone else from using it
