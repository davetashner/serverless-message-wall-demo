#!/bin/bash
# finalize-web.sh - Update index.html with the actual Lambda Function URL
# Run this after deploy-dev.sh to complete the web app setup
#
# The Function URL is only known after the FunctionURL Crossplane resource
# is created and reconciled. This script retrieves it and updates index.html.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "${SCRIPT_DIR}")"

# Colors
if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    BLUE='\033[0;34m'
    NC='\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    NC=''
fi

log_info() { echo -e "${BLUE}ℹ${NC} $1"; }
log_success() { echo -e "${GREEN}✓${NC} $1"; }
log_warn() { echo -e "${YELLOW}⚠${NC} $1"; }
log_error() { echo -e "${RED}✗${NC} $1" >&2; }

# Configuration
CLUSTER_CONTEXT="kind-actuator"
STATE_FILE="${PROJECT_ROOT}/.setup-state.json"
INDEX_HTML="${PROJECT_ROOT}/app/web/index.html"

#------------------------------------------------------------------------------
# Load configuration from state file
#------------------------------------------------------------------------------

load_config() {
    if [[ ! -f "${STATE_FILE}" ]]; then
        log_error "Setup state file not found: ${STATE_FILE}"
        log_error "Run ./scripts/setup.sh first."
        exit 1
    fi
    
    # Extract values from JSON (using grep/sed for portability)
    RESOURCE_PREFIX=$(grep '"resource_prefix"' "${STATE_FILE}" | sed 's/.*: *"//' | sed 's/".*//')
    BUCKET_NAME=$(grep '"bucket_name"' "${STATE_FILE}" | sed 's/.*: *"//' | sed 's/".*//')
    AWS_REGION=$(grep '"aws_region"' "${STATE_FILE}" | sed 's/.*: *"//' | sed 's/".*//')
    
    if [[ -z "${RESOURCE_PREFIX}" || -z "${BUCKET_NAME}" || -z "${AWS_REGION}" ]]; then
        log_error "Could not read configuration from ${STATE_FILE}"
        exit 1
    fi
    
    log_info "Configuration loaded from ${STATE_FILE}"
    echo "  Resource Prefix: ${RESOURCE_PREFIX}"
    echo "  Bucket Name:     ${BUCKET_NAME}"
    echo "  Region:          ${AWS_REGION}"
    echo ""
}

#------------------------------------------------------------------------------
# Get Function URL from Kubernetes
#------------------------------------------------------------------------------

get_function_url() {
    local url

    log_info "Retrieving Function URL from Kubernetes..." >&2

    # Check if cluster is reachable
    if ! kubectl cluster-info --context "${CLUSTER_CONTEXT}" &> /dev/null; then
        log_error "Cannot reach cluster '${CLUSTER_CONTEXT}'"
        log_error "Make sure the kind cluster is running."
        exit 1
    fi
    
    # Get the Function URL
    url=$(kubectl get functionurl "${RESOURCE_PREFIX}-api-handler-url" \
        -o jsonpath='{.status.atProvider.functionUrl}' \
        --context "${CLUSTER_CONTEXT}" 2>/dev/null || true)
    
    if [[ -z "${url}" ]]; then
        log_error "Function URL not found. Is the deployment complete?"
        log_error "Run './scripts/deploy-dev.sh' first, then wait for resources to be ready."
        echo ""
        echo "Check status with:"
        echo "  kubectl get functionurl ${RESOURCE_PREFIX}-api-handler-url --context ${CLUSTER_CONTEXT}"
        exit 1
    fi
    
    echo "${url}"
}

#------------------------------------------------------------------------------
# Update index.html with Function URL
#------------------------------------------------------------------------------

update_index_html() {
    local function_url="$1"
    
    if [[ ! -f "${INDEX_HTML}" ]]; then
        log_error "index.html not found: ${INDEX_HTML}"
        log_error "Run './scripts/setup.sh' first to generate files from templates."
        exit 1
    fi
    
    # Check if it still has the placeholder
    if grep -q '\${API_URL}' "${INDEX_HTML}"; then
        log_info "Updating index.html with Function URL..."
        
        # Replace the placeholder
        sed -i.bak "s|\${API_URL}|${function_url}|g" "${INDEX_HTML}"
        rm -f "${INDEX_HTML}.bak"
        
        log_success "Updated: ${INDEX_HTML}"
    elif grep -q "${function_url}" "${INDEX_HTML}"; then
        log_info "index.html already has the correct Function URL."
    else
        log_warn "index.html has a different Function URL. Updating..."
        
        # Replace any existing URL pattern
        sed -i.bak "s|const API_URL = '.*';|const API_URL = '${function_url}';|g" "${INDEX_HTML}"
        rm -f "${INDEX_HTML}.bak"
        
        log_success "Updated: ${INDEX_HTML}"
    fi
}

#------------------------------------------------------------------------------
# Upload to S3
#------------------------------------------------------------------------------

upload_to_s3() {
    log_info "Uploading index.html to S3..."
    
    aws s3 cp "${INDEX_HTML}" "s3://${BUCKET_NAME}/index.html" \
        --content-type "text/html" \
        --region "${AWS_REGION}"
    
    log_success "Uploaded to s3://${BUCKET_NAME}/index.html"
}

#------------------------------------------------------------------------------
# Main
#------------------------------------------------------------------------------

main() {
    echo ""
    echo "=== Finalize Web Application ==="
    echo ""
    
    load_config
    
    FUNCTION_URL=$(get_function_url)
    log_success "Function URL: ${FUNCTION_URL}"
    echo ""
    
    update_index_html "${FUNCTION_URL}"
    echo ""
    
    upload_to_s3
    echo ""
    
    echo "=== Finalization Complete ==="
    echo ""
    echo "Your message wall is ready!"
    echo ""
    echo "  Website: http://${BUCKET_NAME}.s3-website-${AWS_REGION}.amazonaws.com/"
    echo "  API:     ${FUNCTION_URL}"
    echo ""
    echo "Run './scripts/smoke-test.sh' to verify everything works."
}

main "$@"
