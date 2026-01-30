# Claim Authoring Guide

This guide explains how developers create and deploy ServerlessEventAppClaims using Kustomize overlays.

## Deployment Flow

```
┌─────────────┐     ┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│    Git      │────▶│  Kustomize  │────▶│  ConfigHub  │────▶│  Crossplane │
│  (overlays) │     │   (render)  │     │  (publish)  │     │    (AWS)    │
└─────────────┘     └─────────────┘     └─────────────┘     └─────────────┘
       │                   │                   │                   │
       │  dev-east/        │  Rendered         │  Versioned        │  17 AWS
       │  prod-west/       │  claim.yaml       │  revision         │  resources
       │  ...              │                   │                   │
```

**Flow:**
1. Developer edits Kustomize overlay in Git
2. `kustomize build` renders the final claim YAML
3. `publish-claims.sh` publishes to ConfigHub space
4. ArgoCD syncs ConfigHub → Kubernetes
5. Crossplane reconciles claim → AWS resources

## Claim Schema

### Minimum Required Fields

Only 2 fields are required to create a deployment:

```yaml
apiVersion: messagewall.demo/v1alpha1
kind: ServerlessEventAppClaim
metadata:
  name: my-app
spec:
  environment: dev           # Required: dev | staging | prod
  awsAccountId: "123456789012"  # Required: 12-digit AWS account
```

### Full Schema with Defaults

All available fields and their default values:

```yaml
apiVersion: messagewall.demo/v1alpha1
kind: ServerlessEventAppClaim
metadata:
  name: my-app
  namespace: default
  annotations: {}            # Optional: custom annotations
spec:
  # Required fields
  environment: dev           # dev | staging | prod
  awsAccountId: "123456789012"

  # Optional fields with defaults
  resourcePrefix: messagewall    # Prefix for AWS resource names
  region: us-east-1              # us-east-1 | us-west-2 | eu-west-1
  lambdaMemory: 128              # MB (128-10240)
  lambdaTimeout: 10              # seconds (1-900)
  eventSource: messagewall.api-handler
  artifactBucket: ""             # Uses app bucket if empty
```

## Directory Structure

```
infra/claims/
├── base/
│   ├── kustomization.yaml    # Base kustomization
│   └── claim.yaml            # Template with defaults
└── overlays/
    ├── dev-east/
    │   └── kustomization.yaml
    ├── dev-west/
    │   └── kustomization.yaml
    ├── prod-east/
    │   └── kustomization.yaml
    └── prod-west/
        └── kustomization.yaml
```

## Example Overlays

### Dev Overlay (dev-east)

Minimal patches for development:

```yaml
# infra/claims/overlays/dev-east/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - ../../base

patches:
  - target:
      kind: ServerlessEventAppClaim
      name: messagewall
    patch: |
      - op: replace
        path: /metadata/name
        value: messagewall-dev-east
      - op: replace
        path: /spec/environment
        value: dev
      - op: replace
        path: /spec/region
        value: us-east-1
      - op: replace
        path: /spec/resourcePrefix
        value: messagewall-east

labels:
  - pairs:
      environment: dev
      region: us-east-1
    includeSelectors: false
```

### Prod Overlay (prod-east)

Production adds resource tuning and annotations:

```yaml
# infra/claims/overlays/prod-east/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - ../../base

patches:
  - target:
      kind: ServerlessEventAppClaim
      name: messagewall
    patch: |
      - op: replace
        path: /metadata/name
        value: messagewall-prod-east
      - op: replace
        path: /spec/environment
        value: prod
      - op: replace
        path: /spec/region
        value: us-east-1
      - op: replace
        path: /spec/resourcePrefix
        value: messagewall-east
      - op: replace
        path: /spec/lambdaMemory
        value: 256
      - op: replace
        path: /spec/lambdaTimeout
        value: 30
      - op: add
        path: /metadata/annotations
        value:
          messagewall.demo/tier: production
          messagewall.demo/oncall: platform-team

labels:
  - pairs:
      environment: prod
      region: us-east-1
    includeSelectors: false
```

## Publishing Workflow

### Preview Rendered Output

```bash
# Render a single overlay
kustomize build infra/claims/overlays/dev-east

# Render all overlays and compare
for overlay in dev-east dev-west prod-east prod-west; do
  echo "=== $overlay ==="
  kustomize build infra/claims/overlays/$overlay | grep -E '(name:|environment:|region:|lambdaMemory:)'
done
```

### Publish to ConfigHub

```bash
# Dry-run (preview without publishing)
./scripts/publish-claims.sh --dry-run

# Publish a single overlay
./scripts/publish-claims.sh --overlay dev-east

# Publish and apply (make live)
./scripts/publish-claims.sh --overlay dev-east --apply

# Publish all overlays
./scripts/publish-claims.sh --apply
```

### Overlay to Space Mapping

| Overlay     | ConfigHub Space       | Region    | Environment |
|-------------|----------------------|-----------|-------------|
| dev-east    | messagewall-dev-east | us-east-1 | dev         |
| dev-west    | messagewall-dev-west | us-west-2 | dev         |
| prod-east   | messagewall-prod-east| us-east-1 | prod        |
| prod-west   | messagewall-prod-west| us-west-2 | prod        |

## Creating a New Overlay

1. Create overlay directory:
   ```bash
   mkdir -p infra/claims/overlays/staging-east
   ```

2. Create kustomization.yaml:
   ```yaml
   apiVersion: kustomize.config.k8s.io/v1beta1
   kind: Kustomization

   resources:
     - ../../base

   patches:
     - target:
         kind: ServerlessEventAppClaim
         name: messagewall
       patch: |
         - op: replace
           path: /metadata/name
           value: messagewall-staging-east
         - op: replace
           path: /spec/environment
           value: staging
         - op: replace
           path: /spec/region
           value: us-east-1

   labels:
     - pairs:
         environment: staging
         region: us-east-1
       includeSelectors: false
   ```

3. Add space mapping to `scripts/publish-claims.sh` (in `get_space_name` function):
   ```bash
   staging-east) echo "messagewall-staging-east" ;;
   ```

4. Create ConfigHub space (if it doesn't exist):
   ```bash
   cub space create messagewall-staging-east
   ```

5. Test and publish:
   ```bash
   kustomize build infra/claims/overlays/staging-east
   ./scripts/publish-claims.sh --overlay staging-east --apply
   ```

## Validation

Claims are validated at multiple levels:

1. **Kustomize** - YAML syntax and patch correctness
2. **ConfigHub** - Policy enforcement during publish
3. **Kyverno** - Runtime policies in Kubernetes
4. **Crossplane XRD** - OpenAPI schema validation

Common validation errors:
- Missing required fields (`environment`, `awsAccountId`)
- Invalid enum values (e.g., `environment: development` instead of `dev`)
- Out-of-range values (e.g., `lambdaMemory: 50`)
- AWS account ID format (must be 12 digits)

## Next Steps

- [XRD Schema Reference](../platform/crossplane/xrd/serverless-event-app.yaml) - Full XRD definition
- [Kyverno Policies](../platform/kyverno/policies/) - Runtime validation policies
- [Demo Guide](demo-guide.md) - End-to-end deployment walkthrough
