# ADR-003: Lambda Artifact Storage

## Status
Accepted

## Context
Lambda functions require deployment packages (ZIP files) to be stored in S3 for Crossplane to reference. We need to decide where to store these artifacts.

## Decision
Store Lambda ZIP artifacts in the **same S3 bucket** as the static website, under an `artifacts/` prefix.

## Rationale
- Simplifies infrastructure (one bucket instead of two)
- Demo-focused: fewer resources to manage and explain
- Artifacts can be excluded from public website access via bucket policy if needed

## Consequences
- Bucket structure:
  ```
  <bucket>/
    index.html
    app.js
    state.json
    artifacts/
      api-handler.zip
      snapshot-writer.zip
  ```
- Crossplane Lambda manifests reference `s3://<bucket>/artifacts/*.zip`
- Build scripts upload to `artifacts/` prefix
