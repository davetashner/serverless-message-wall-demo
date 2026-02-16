#!/bin/bash
set -euo pipefail

# render-composition.sh - Render Crossplane Composition into individual managed resources
#
# Replaces the envsubst-based template pipeline with crossplane render.
# The Composition becomes a build-time transform; Crossplane in-cluster acts
# as a pure reconciler of fully-expanded managed resources.
#
# Pipeline:
#   1. kustomize build overlay → Claim YAML
#   2. Convert Claim → XR (kind change for crossplane CLI)
#   3. crossplane render XR + Composition + Function → multi-doc YAML
#   4. Split output into individual files named by composition-resource-name
#   5. Strip Crossplane-internal annotations not needed in ConfigHub

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
CLAIMS_DIR="${PROJECT_ROOT}/infra/claims"
COMPOSITION="${PROJECT_ROOT}/platform/crossplane/compositions/serverless-event-app-aws.yaml"
FUNCTION="${PROJECT_ROOT}/platform/crossplane/functions/function-patch-and-transform.yaml"
XRD="${PROJECT_ROOT}/platform/crossplane/xrd/serverless-event-app.yaml"

# Overlay-to-space mapping (same as publish-claims.sh)
get_space_name() {
    local overlay="$1"
    case "$overlay" in
        dev-east)  echo "messagewall-dev-east" ;;
        dev-west)  echo "messagewall-dev-west" ;;
        prod-east) echo "messagewall-prod-east" ;;
        prod-west) echo "messagewall-prod-west" ;;
        *) echo "" ;;
    esac
}

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Render a Crossplane Composition into individual managed resource files.

Replaces the envsubst-based template pipeline. Uses 'crossplane render'
to expand a Claim through the Composition, producing one YAML file per
managed resource (19 total).

OPTIONS:
    --overlay NAME    Overlay to render: dev-east, dev-west, prod-east, prod-west
                      (required)
    --output-dir DIR  Directory for rendered resource files (default: rendered/<overlay>)
    --dry-run         Show rendered output without writing files
    --get-space NAME  Print the ConfigHub space name for an overlay and exit
    -h, --help        Show this help message

PREREQUISITES:
    - crossplane CLI (crossplane render)
    - kustomize CLI or kubectl
    - yq (v4+)
    - Docker (crossplane render runs function as gRPC container)

EXAMPLES:
    # Render dev-east overlay
    $(basename "$0") --overlay dev-east --output-dir /tmp/rendered

    # Dry-run to preview
    $(basename "$0") --overlay dev-east --dry-run

    # Get ConfigHub space for an overlay
    $(basename "$0") --get-space dev-east

EOF
    exit 0
}

DRY_RUN=false
OVERLAY=""
OUTPUT_DIR=""
GET_SPACE=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --overlay)
            OVERLAY="$2"
            shift 2
            ;;
        --output-dir)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --get-space)
            GET_SPACE="$2"
            shift 2
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

# Handle --get-space
if [[ -n "${GET_SPACE}" ]]; then
    space=$(get_space_name "${GET_SPACE}")
    if [[ -z "${space}" ]]; then
        echo "Error: Unknown overlay '${GET_SPACE}'" >&2
        exit 1
    fi
    echo "${space}"
    exit 0
fi

# Validate overlay
if [[ -z "${OVERLAY}" ]]; then
    echo "Error: --overlay is required"
    echo "Valid options: dev-east, dev-west, prod-east, prod-west"
    exit 1
fi

case "${OVERLAY}" in
    dev-east|dev-west|prod-east|prod-west) ;;
    *)
        echo "Error: Invalid overlay '${OVERLAY}'"
        echo "Valid options: dev-east, dev-west, prod-east, prod-west"
        exit 1
        ;;
esac

# Default output dir
if [[ -z "${OUTPUT_DIR}" ]]; then
    OUTPUT_DIR="${PROJECT_ROOT}/rendered/${OVERLAY}"
fi

# Check prerequisites
KUSTOMIZE_CMD=""
if command -v kustomize &> /dev/null; then
    KUSTOMIZE_CMD="kustomize build"
elif command -v kubectl &> /dev/null; then
    KUSTOMIZE_CMD="kubectl kustomize"
else
    echo "Error: Neither kustomize nor kubectl is installed"
    exit 1
fi

if ! command -v crossplane &> /dev/null; then
    echo "Error: crossplane CLI is not installed"
    echo "Install with: curl -sL https://raw.githubusercontent.com/crossplane/crossplane/master/install.sh | sh"
    exit 1
fi

if ! command -v yq &> /dev/null; then
    echo "Error: yq is not installed"
    echo "Install with: brew install yq"
    exit 1
fi

OVERLAY_DIR="${CLAIMS_DIR}/overlays/${OVERLAY}"
if [[ ! -d "${OVERLAY_DIR}" ]]; then
    echo "Error: Overlay directory not found: ${OVERLAY_DIR}"
    exit 1
fi

echo "=== Rendering Composition for ${OVERLAY} ==="
echo "  Overlay: ${OVERLAY_DIR}"
echo "  Composition: ${COMPOSITION}"
echo "  Function: ${FUNCTION}"
echo ""

# Step 1: kustomize build → Claim YAML
echo "Step 1: Building Kustomize overlay..."
CLAIM_YAML=$(${KUSTOMIZE_CMD} "${OVERLAY_DIR}")
echo "  Claim rendered successfully"

# Step 2: Convert Claim → XR
# crossplane render expects an XR (composite), not a Claim.
# Change kind from ServerlessEventAppClaim to ServerlessEventApp and remove namespace.
echo "Step 2: Converting Claim to XR..."
XR_YAML=$(echo "${CLAIM_YAML}" | yq eval '
    .kind = "ServerlessEventApp" |
    del(.metadata.namespace)
' -)
echo "  XR created"

# Write XR to temp file (crossplane render needs file paths)
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "${TEMP_DIR}"' EXIT

echo "${XR_YAML}" > "${TEMP_DIR}/xr.yaml"

# Create a clean function file (crossplane render chokes on leading comments + ---)
grep -v '^#' "${FUNCTION}" | grep -v '^---$' > "${TEMP_DIR}/function.yaml"

# Step 3: crossplane render
echo "Step 3: Running crossplane render..."
RENDER_OUTPUT=$(crossplane render \
    "${TEMP_DIR}/xr.yaml" \
    "${COMPOSITION}" \
    "${TEMP_DIR}/function.yaml" \
    2>&1) || {
    echo "Error: crossplane render failed:"
    echo "${RENDER_OUTPUT}"
    exit 1
}
echo "  Render completed"

# Step 4: Split output into individual files
echo "Step 4: Splitting into individual resource files..."

if [[ "${DRY_RUN}" == "true" ]]; then
    echo ""
    echo "=== Dry Run Output ==="
    echo ""

    # Count and display resources (skip the first doc which is the XR)
    doc_index=0
    echo "${RENDER_OUTPUT}" | yq eval-all --no-doc '
        select(documentIndex > 0) |
        .metadata.annotations["crossplane.io/composition-resource-name"] + " (" + .kind + ")"
    ' - | while read -r line; do
        echo "  ${line}"
    done

    echo ""
    echo "Full rendered output:"
    echo "${RENDER_OUTPUT}"
    exit 0
fi

# Create output directory
mkdir -p "${OUTPUT_DIR}"

# Count total documents
TOTAL_DOCS=$(echo "${RENDER_OUTPUT}" | yq eval-all --no-doc '[documentIndex] | length' - 2>/dev/null || echo "0")

# Annotations to strip from ConfigHub output
STRIP_ANNOTATIONS=(
    "crossplane.io/composition-resource-name"
    "crossplane.io/external-name"
)

resource_count=0

# Process each document, skipping the first (the XR itself)
for i in $(seq 1 $((TOTAL_DOCS - 1))); do
    # Extract resource name from composition-resource-name annotation
    RESOURCE_NAME=$(echo "${RENDER_OUTPUT}" | yq eval-all "select(documentIndex == ${i}) | .metadata.annotations[\"crossplane.io/composition-resource-name\"]" -)

    if [[ -z "${RESOURCE_NAME}" || "${RESOURCE_NAME}" == "null" ]]; then
        echo "  Warning: Document ${i} has no composition-resource-name, skipping"
        continue
    fi

    RESOURCE_KIND=$(echo "${RENDER_OUTPUT}" | yq eval-all "select(documentIndex == ${i}) | .kind" -)
    OUTPUT_FILE="${OUTPUT_DIR}/${RESOURCE_NAME}.yaml"

    # Extract the document and clean up Crossplane-internal annotations
    echo "${RENDER_OUTPUT}" | yq eval-all "select(documentIndex == ${i})" - | \
        yq eval '
            del(.metadata.annotations["crossplane.io/composition-resource-name"]) |
            del(.metadata.annotations["crossplane.io/external-name"])
        ' - > "${OUTPUT_FILE}"

    # Clean up empty annotations map if all annotations were stripped
    if [[ $(yq eval '.metadata.annotations | length' "${OUTPUT_FILE}") == "0" ]]; then
        yq eval -i 'del(.metadata.annotations)' "${OUTPUT_FILE}"
    fi

    echo "  ${RESOURCE_NAME}.yaml (${RESOURCE_KIND})"
    resource_count=$((resource_count + 1))
done

echo ""
echo "=== Render Complete ==="
echo "  Resources: ${resource_count}"
echo "  Output: ${OUTPUT_DIR}"
echo "  Space: $(get_space_name "${OVERLAY}")"
