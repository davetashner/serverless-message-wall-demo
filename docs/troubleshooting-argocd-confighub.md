# Troubleshooting: ArgoCD + ConfigHub CMP Integration

This document captures issues encountered and solutions found when setting up ArgoCD to sync from ConfigHub using a Config Management Plugin (CMP).

## Issue 1: ArgoCD fails to resolve placeholder repoURL

**Symptom:**
```
Failed to load target state: dial tcp: lookup confighub.example.com: no such host
```

**Cause:** ArgoCD requires `repoURL` to be reachable even when using a CMP plugin. The CMP plugin runs AFTER ArgoCD clones the repository.

**Solution:** Use a real, accessible git repository URL. The CMP plugin will ignore the git content and fetch from ConfigHub anyway.

```yaml
# Before (broken)
source:
  repoURL: https://confighub.example.com/messagewall-prod

# After (working)
source:
  repoURL: https://github.com/davetashner/serverless-message-wall-demo.git
  path: platform
```

## Issue 2: CMP plugin socket name mismatch

**Symptom:**
```
could not find cmp-server plugin with name "confighub" supporting the given repository
Unable to connect to config management plugin service with address /home/argocd/cmp-server/plugins/confighub.sock
```

But the CMP sidecar logs show:
```
serving on /home/argocd/cmp-server/plugins/confighub-v1.0.sock
```

**Cause:** When `version: v1.0` is specified in the plugin.yaml, the CMP server creates a socket named `{name}-{version}.sock`. But ArgoCD looks for `{name}.sock`.

**Solution:** Remove the version from the plugin spec:

```yaml
# Before (broken)
spec:
  version: v1.0

# After (working)
spec:
  # Note: Omitting 'version' so socket is named 'confighub.sock' not 'confighub-v1.0.sock'
```

## Issue 3: cub CLI cannot create config directory

**Symptom:**
```
mkdir /.confighub: permission denied
```

**Cause:** The CMP sidecar runs as non-root user (999) with `runAsNonRoot: true`. The `cub` CLI tries to create `~/.confighub` but HOME is undefined or points to `/` which isn't writable.

**Solution:** Set HOME environment variable to a writable directory in the CMP container:

```yaml
env:
  - name: HOME
    value: /tmp
```

## Issue 4: Invalid worker ID format

**Symptom:**
```
authentication failed: {"message":"Invalid worker ID format"}
```

**Cause:** ConfigHub expects the worker UUID (e.g., `396697f8-ef08-474f-a7c1-89a8195971b3`), not the worker slug/name (e.g., `actuator-sync`).

**Solution:** Get the worker UUID and use it:

```bash
# Get the UUID
cub worker get --space messagewall-prod actuator-sync
# Output includes: ID  396697f8-ef08-474f-a7c1-89a8195971b3

# Use UUID in the secret
kubectl create secret generic confighub-actuator-credentials \
  --from-literal=CONFIGHUB_WORKER_ID="396697f8-ef08-474f-a7c1-89a8195971b3" \
  --from-literal=CONFIGHUB_WORKER_SECRET="ch_..."
```

## Issue 5: CONFIGHUB_SPACE not passed to generate command

**Symptom:**
```
Error: CONFIGHUB_SPACE not set
```

Despite being set in the Application spec's `source.plugin.env`.

**Cause:** Environment variables from the Application spec may not be passed correctly to the CMP sidecar in all ArgoCD versions/configurations.

**Workaround:** Set CONFIGHUB_SPACE as a default in the CMP container's env in values.yaml. The Application's env should override this, but having a default helps when the passthrough doesn't work.

```yaml
env:
  - name: CONFIGHUB_SPACE
    value: messagewall-prod  # Default, overridden by Application spec
```

**Note:** This workaround hardcodes a single space. For multi-space setups, investigate why env vars aren't being passed from Application spec.

## Issue 6: Lambda functions fail to sync (S3 artifact not found)

**Symptom:**
```
UpdateFunctionCode: S3 Error Code: NoSuchKey. The specified key does not exist.
```

**Cause:** Crossplane tries to update the Lambda function code, but the artifact ZIP doesn't exist in the S3 bucket.

**Solution:** Copy Lambda artifacts to the production bucket:

```bash
aws s3 cp s3://messagewall-demo-dev/artifacts/api-handler.zip \
          s3://messagewall-demo-prod/artifacts/api-handler.zip
aws s3 cp s3://messagewall-demo-dev/artifacts/snapshot-writer.zip \
          s3://messagewall-demo-prod/artifacts/snapshot-writer.zip
```

## Diagnostic Commands

```bash
# Check ArgoCD application status
kubectl get applications -n argocd messagewall-prod

# Check detailed error message
kubectl get applications -n argocd messagewall-prod -o jsonpath='{.status.conditions[*].message}'

# Check CMP sidecar logs
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-repo-server -c confighub-cmp

# Check repo-server logs for plugin errors
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-repo-server -c repo-server | grep -i plugin

# Trigger hard refresh
kubectl patch application messagewall-prod -n argocd --type merge \
  -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'

# Check Crossplane resource status
kubectl get function.lambda -o wide

# Get worker UUID from ConfigHub
cub worker get --space <space-name> <worker-name>
```

## Resolution Checklist

When ArgoCD + ConfigHub sync fails, check in order:

1. [ ] Is repoURL a real, reachable git endpoint?
2. [ ] Is the CMP socket name correct (no version suffix)?
3. [ ] Does the CMP container have HOME set to a writable directory?
4. [ ] Is CONFIGHUB_WORKER_ID the UUID (not the slug)?
5. [ ] Is CONFIGHUB_WORKER_SECRET correct?
6. [ ] Is CONFIGHUB_SPACE being passed to the generate command?
7. [ ] Do Lambda artifacts exist in the S3 bucket?
