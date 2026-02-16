#!/bin/sh
# validate-policies.sh - Policy validation for rendered Crossplane manifests
#
# Iterates all YAML files in the rendered directory and checks resources
# by kind (not filename). Works with both the old envsubst pipeline
# (multi-resource files) and the new composition render pipeline
# (one resource per file).
#
# Checks:
# - Lambda memory/timeout bounds
# - Overly permissive IAM policies (Action: "*")
#
# Usage: ./validate-policies.sh <rendered-dir>

set -e

RENDERED_DIR="${1:-.}"
VIOLATIONS=0

# Colors
if [ -t 1 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    NC='\033[0m'
else
    RED=''
    GREEN=''
    NC=''
fi

echo "=========================================="
echo "Policy Validation for Crossplane Manifests"
echo "=========================================="
echo ""

# Check if yq is available for kind-based detection
if command -v yq > /dev/null 2>&1; then
    USE_YQ=true
else
    USE_YQ=false
    echo "Note: yq not found, falling back to pattern-based checks"
    echo ""
fi

# -----------------------------------------------------------------------------
# Lambda bounds check
# -----------------------------------------------------------------------------
echo "--- Lambda Configuration Bounds ---"

lambda_found=false

for yaml_file in "$RENDERED_DIR"/*.yaml; do
    [ -f "$yaml_file" ] || continue

    # Check if this file contains a Lambda Function resource
    is_lambda=false
    if [ "$USE_YQ" = "true" ]; then
        kind=$(yq eval '.kind // ""' "$yaml_file" 2>/dev/null)
        if [ "$kind" = "Function" ]; then
            apiVersion=$(yq eval '.apiVersion // ""' "$yaml_file" 2>/dev/null)
            case "$apiVersion" in
                lambda.aws.upbound.io*) is_lambda=true ;;
            esac
        fi
    else
        # Fallback: check for Lambda Function kind pattern
        if grep -q 'kind: Function' "$yaml_file" && grep -q 'lambda.aws.upbound.io' "$yaml_file"; then
            is_lambda=true
        fi
    fi

    if [ "$is_lambda" = "true" ]; then
        lambda_found=true
        fname=$(basename "$yaml_file")

        # Extract memorySize values and check bounds (128-3008)
        for memory in $(grep -E '^\s*memorySize:\s*[0-9]+' "$yaml_file" | sed 's/.*memorySize:\s*//'); do
            if [ "$memory" -lt 128 ] 2>/dev/null; then
                printf "${RED}x${NC} %s: memorySize=%s is below minimum (128 MB)\n" "$fname" "$memory"
                VIOLATIONS=$((VIOLATIONS + 1))
            elif [ "$memory" -gt 3008 ] 2>/dev/null; then
                printf "${RED}x${NC} %s: memorySize=%s exceeds maximum (3008 MB)\n" "$fname" "$memory"
                VIOLATIONS=$((VIOLATIONS + 1))
            else
                printf "${GREEN}ok${NC} %s: memorySize=%s MB (valid)\n" "$fname" "$memory"
            fi
        done

        # Extract timeout values and check bounds (3-300)
        for timeout in $(grep -E '^\s*timeout:\s*[0-9]+' "$yaml_file" | sed 's/.*timeout:\s*//'); do
            if [ "$timeout" -lt 3 ] 2>/dev/null; then
                printf "${RED}x${NC} %s: timeout=%s is below minimum (3 seconds)\n" "$fname" "$timeout"
                VIOLATIONS=$((VIOLATIONS + 1))
            elif [ "$timeout" -gt 300 ] 2>/dev/null; then
                printf "${RED}x${NC} %s: timeout=%s exceeds maximum (300 seconds)\n" "$fname" "$timeout"
                VIOLATIONS=$((VIOLATIONS + 1))
            else
                printf "${GREEN}ok${NC} %s: timeout=%s seconds (valid)\n" "$fname" "$timeout"
            fi
        done
    fi
done

if [ "$lambda_found" = "false" ]; then
    echo "No Lambda Function resources found"
fi

echo ""

# -----------------------------------------------------------------------------
# IAM wildcard check
# -----------------------------------------------------------------------------
echo "--- IAM Policy Permissions ---"

iam_found=false

for yaml_file in "$RENDERED_DIR"/*.yaml; do
    [ -f "$yaml_file" ] || continue

    # Check if this file contains an IAM resource (Role, RolePolicy, Policy)
    is_iam=false
    if [ "$USE_YQ" = "true" ]; then
        kind=$(yq eval '.kind // ""' "$yaml_file" 2>/dev/null)
        case "$kind" in
            Role|RolePolicy|Policy)
                apiVersion=$(yq eval '.apiVersion // ""' "$yaml_file" 2>/dev/null)
                case "$apiVersion" in
                    iam.aws.upbound.io*) is_iam=true ;;
                esac
                ;;
        esac
    else
        if grep -q 'iam.aws.upbound.io' "$yaml_file"; then
            is_iam=true
        fi
    fi

    if [ "$is_iam" = "true" ]; then
        iam_found=true
        fname=$(basename "$yaml_file")

        # Check for "Action": "*" (full wildcard - very dangerous)
        if grep -qE '"Action"\s*:\s*"\*"' "$yaml_file"; then
            printf "${RED}x${NC} %s: Found 'Action': '*' - overly permissive\n" "$fname"
            VIOLATIONS=$((VIOLATIONS + 1))
        else
            printf "${GREEN}ok${NC} %s: No wildcard Action:'*' found\n" "$fname"
        fi

        # Check for service wildcards like "s3:*" or "dynamodb:*" (but not in comments)
        if grep -vE '^\s*#' "$yaml_file" | grep -qE '"[a-z0-9-]+:\*"'; then
            # Exclude known safe patterns (events:PutEvents often needs Resource:*)
            wildcards=$(grep -vE '^\s*#' "$yaml_file" | grep -oE '"[a-z0-9-]+:\*"' | sort -u | grep -v 'events:' || true)
            if [ -n "$wildcards" ]; then
                printf "${RED}x${NC} %s: Found service wildcard actions: %s\n" "$fname" "$wildcards"
                VIOLATIONS=$((VIOLATIONS + 1))
            fi
        fi
    fi
done

if [ "$iam_found" = "false" ]; then
    echo "No IAM resources found"
fi

echo ""

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
echo "=========================================="
echo "Validation Summary"
echo "=========================================="
echo ""

if [ "$VIOLATIONS" -gt 0 ]; then
    printf "${RED}FAILED${NC}: %d policy violation(s) found\n" "$VIOLATIONS"
    exit 1
else
    printf "${GREEN}PASSED${NC}: All policy checks passed\n"
    exit 0
fi
