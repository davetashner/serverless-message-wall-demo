#!/bin/bash
# List all precious database units in production ConfigHub spaces
#
# This script queries ConfigHub and Kubernetes to find all resources
# marked as precious (stateful, business-critical, irreversible).
#
# Usage:
#   ./scripts/list-precious-units.sh [OPTIONS]
#
# Options:
#   --space SPACE   Query specific space only (default: all production spaces)
#   --format FORMAT Output format: table, json, yaml (default: table)
#   --kubectl-only  Query only Kubernetes Claims, skip ConfigHub
#   -h, --help      Show this help message
#
# Examples:
#   ./scripts/list-precious-units.sh
#   ./scripts/list-precious-units.sh --space messagewall-prod
#   ./scripts/list-precious-units.sh --kubectl-only --format json
#
# See docs/precious-resources.md for the precious resource convention.

set -euo pipefail

SPACE=""
FORMAT="table"
KUBECTL_ONLY=false

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

List all precious database units in production.

OPTIONS:
    --space SPACE     Query specific space only
    --format FORMAT   Output format: table, json, yaml (default: table)
    --kubectl-only    Query only Kubernetes Claims, skip ConfigHub
    -h, --help        Show this help message

WHAT IS PRECIOUS?
    Precious resources are stateful infrastructure whose deletion would
    cause irreversible data loss (DynamoDB tables, S3 buckets with data).
    See docs/precious-resources.md for full definition.

EXAMPLES:
    # List all precious units
    $(basename "$0")

    # Query specific space
    $(basename "$0") --space messagewall-prod

    # Output as JSON (for scripting)
    $(basename "$0") --format json

EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --space)
            SPACE="$2"
            shift 2
            ;;
        --format)
            FORMAT="$2"
            shift 2
            ;;
        --kubectl-only)
            KUBECTL_ONLY=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "Unknown option: $1"
            usage
            ;;
    esac
done

# Header
echo "========================================"
echo "Precious Database Units"
echo "========================================"
echo ""

# -------------------------------------------------------------------
# ConfigHub Query (if available)
# -------------------------------------------------------------------
if [[ "${KUBECTL_ONLY}" == "false" ]] && command -v cub &> /dev/null; then
    echo "--- ConfigHub Spaces ---"
    echo ""

    if [[ -n "${SPACE}" ]]; then
        SPACES="${SPACE}"
    else
        # List all production-tier spaces
        SPACES=$(cub space list --filter "metadata.tier=production" -o name 2>/dev/null || echo "")
        if [[ -z "${SPACES}" ]]; then
            echo "No production spaces found (or cub not authenticated)."
            echo "Run: cub auth login"
            echo ""
        fi
    fi

    for space in ${SPACES}; do
        echo "Space: ${space}"

        case "${FORMAT}" in
            table)
                cub unit list --space "${space}" \
                    --filter "metadata.precious=true" \
                    -o table 2>/dev/null || echo "  (no units or query failed)"
                ;;
            json)
                cub unit list --space "${space}" \
                    --filter "metadata.precious=true" \
                    -o json 2>/dev/null || echo "  []"
                ;;
            yaml)
                cub unit list --space "${space}" \
                    --filter "metadata.precious=true" \
                    -o yaml 2>/dev/null || echo "  # no units"
                ;;
        esac
        echo ""
    done

    # Summary query: all precious database units
    echo "--- Precious Database Units (DynamoDB) ---"
    echo ""
    for space in ${SPACES}; do
        cub unit list --space "${space}" \
            --filter "metadata.precious=true" \
            --filter "metadata.precious-resources~dynamodb" \
            -o table 2>/dev/null || true
    done
    echo ""
else
    if [[ "${KUBECTL_ONLY}" == "false" ]]; then
        echo "Note: cub CLI not found. Showing Kubernetes Claims only."
        echo "Install cub from: https://github.com/confighub/cub/releases"
        echo ""
    fi
fi

# -------------------------------------------------------------------
# Kubernetes Query (Crossplane Claims)
# -------------------------------------------------------------------
echo "--- Kubernetes Claims with Precious Annotation ---"
echo ""

if ! command -v kubectl &> /dev/null; then
    echo "kubectl not found. Skipping Kubernetes query."
    exit 0
fi

case "${FORMAT}" in
    table)
        echo "NAME                    NAMESPACE   PRECIOUS   RESOURCES      DATA-CLASS"
        echo "---                     ---------   --------   ---------      ----------"
        kubectl get serverlesseventappclaim -A \
            -o custom-columns=\
'NAME:.metadata.name,NAMESPACE:.metadata.namespace,PRECIOUS:.metadata.annotations.confighub\.io/precious,RESOURCES:.metadata.annotations.confighub\.io/precious-resources,DATA-CLASS:.metadata.annotations.confighub\.io/data-classification' \
            2>/dev/null | tail -n +2 | grep -E "true" || echo "(no precious Claims found)"
        ;;
    json)
        kubectl get serverlesseventappclaim -A -o json 2>/dev/null | \
            jq '[.items[] | select(.metadata.annotations["confighub.io/precious"] == "true") | {
                name: .metadata.name,
                namespace: .metadata.namespace,
                precious: .metadata.annotations["confighub.io/precious"],
                resources: .metadata.annotations["confighub.io/precious-resources"],
                dataClassification: .metadata.annotations["confighub.io/data-classification"]
            }]' 2>/dev/null || echo "[]"
        ;;
    yaml)
        kubectl get serverlesseventappclaim -A -o yaml 2>/dev/null | \
            yq '.items[] | select(.metadata.annotations["confighub.io/precious"] == "true")' 2>/dev/null || echo "# no precious Claims"
        ;;
esac

echo ""
echo "========================================"
echo "Legend:"
echo "  precious=true    : Contains stateful resources"
echo "  dynamodb,s3      : Specific precious resource types"
echo "  customer-data    : Data classification level"
echo ""
echo "For protection details, see: docs/precious-resources.md"
