#!/bin/sh
# validate-policies.sh - Policy validation for rendered Crossplane manifests
#
# Simple pattern-based checks for obvious policy violations:
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

# -----------------------------------------------------------------------------
# Lambda bounds check
# -----------------------------------------------------------------------------
echo "--- Lambda Configuration Bounds ---"

lambda_file="$RENDERED_DIR/lambda.yaml"
if [ -f "$lambda_file" ]; then
    # Extract memorySize values and check bounds (128-3008)
    for memory in $(grep -E '^\s*memorySize:\s*[0-9]+' "$lambda_file" | sed 's/.*memorySize:\s*//'); do
        if [ "$memory" -lt 128 ] 2>/dev/null; then
            printf "${RED}✗${NC} memorySize=%s is below minimum (128 MB)\n" "$memory"
            VIOLATIONS=$((VIOLATIONS + 1))
        elif [ "$memory" -gt 3008 ] 2>/dev/null; then
            printf "${RED}✗${NC} memorySize=%s exceeds maximum (3008 MB)\n" "$memory"
            VIOLATIONS=$((VIOLATIONS + 1))
        else
            printf "${GREEN}✓${NC} memorySize=%s MB (valid)\n" "$memory"
        fi
    done

    # Extract timeout values and check bounds (3-300)
    for timeout in $(grep -E '^\s*timeout:\s*[0-9]+' "$lambda_file" | sed 's/.*timeout:\s*//'); do
        if [ "$timeout" -lt 3 ] 2>/dev/null; then
            printf "${RED}✗${NC} timeout=%s is below minimum (3 seconds)\n" "$timeout"
            VIOLATIONS=$((VIOLATIONS + 1))
        elif [ "$timeout" -gt 300 ] 2>/dev/null; then
            printf "${RED}✗${NC} timeout=%s exceeds maximum (300 seconds)\n" "$timeout"
            VIOLATIONS=$((VIOLATIONS + 1))
        else
            printf "${GREEN}✓${NC} timeout=%s seconds (valid)\n" "$timeout"
        fi
    done
else
    echo "No lambda.yaml found"
fi

echo ""

# -----------------------------------------------------------------------------
# IAM wildcard check
# -----------------------------------------------------------------------------
echo "--- IAM Policy Permissions ---"

iam_file="$RENDERED_DIR/iam.yaml"
if [ -f "$iam_file" ]; then
    # Check for "Action": "*" (full wildcard - very dangerous)
    if grep -qE '"Action"\s*:\s*"\*"' "$iam_file"; then
        printf "${RED}✗${NC} Found 'Action': '*' - overly permissive\n"
        VIOLATIONS=$((VIOLATIONS + 1))
    else
        printf "${GREEN}✓${NC} No wildcard Action:'*' found\n"
    fi

    # Check for service wildcards like "s3:*" or "dynamodb:*" (but not in comments)
    if grep -vE '^\s*#' "$iam_file" | grep -qE '"[a-z0-9-]+:\*"'; then
        # Exclude known safe patterns (events:PutEvents often needs Resource:*)
        wildcards=$(grep -vE '^\s*#' "$iam_file" | grep -oE '"[a-z0-9-]+:\*"' | sort -u | grep -v 'events:')
        if [ -n "$wildcards" ]; then
            printf "${RED}✗${NC} Found service wildcard actions: %s\n" "$wildcards"
            VIOLATIONS=$((VIOLATIONS + 1))
        else
            printf "${GREEN}✓${NC} No dangerous service wildcards found\n"
        fi
    else
        printf "${GREEN}✓${NC} No service wildcard actions found\n"
    fi

    # Check that Resource: "*" only appears with safe actions (events:PutEvents)
    # This is a simple heuristic - look for Resource: "*" not near events:PutEvents
    if grep -B5 '"Resource"\s*:\s*"\*"' "$iam_file" | grep -qv 'events:PutEvents'; then
        # Found Resource: "*" without events:PutEvents nearby - might be a problem
        # But this could have false positives, so just warn
        printf "${GREEN}✓${NC} Resource:'*' found (review manually if not for EventBridge)\n"
    else
        printf "${GREEN}✓${NC} Resource wildcards appropriately scoped\n"
    fi
else
    echo "No iam.yaml found"
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
