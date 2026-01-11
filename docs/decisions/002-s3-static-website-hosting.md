# ADR-002: S3 Static Website Hosting

## Status
Accepted

## Context
The browser-based UI needs to be served from S3. There are two approaches:
1. S3 static website hosting (enables index documents, error pages, HTTP access)
2. Direct S3 object access with public-read ACLs

## Decision
Use **S3 static website hosting** feature.

## Rationale
- Provides cleaner URLs (no need to specify `index.html`)
- Standard pattern for static site hosting
- Enables custom error pages if needed
- Website endpoint format: `http://<bucket-name>.s3-website-us-east-1.amazonaws.com`

## Consequences
- Bucket must have `WebsiteConfiguration` set
- Bucket policy must allow public read access for website content
- HTTPS requires CloudFront (not in scope for initial demo)
- CORS configuration needed for Lambda Function URL calls
