#!/bin/bash
# setup.sh - Setup wizard for serverless-message-wall-demo
# See ADR-008 for design decisions
#
# This wizard collects configuration values and generates files from templates.
# Run with --help for usage information.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "${SCRIPT_DIR}")"

# Default values
DEFAULT_REGION="us-east-1"
DEFAULT_RESOURCE_PREFIX="messagewall"
DEFAULT_ENVIRONMENT="dev"

# Colors for output (if terminal supports it)
if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    BLUE='\033[0;34m'
    BOLD='\033[1m'
    NC='\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    BOLD=''
    NC=''
fi

# Configuration variables (set via prompts or CLI flags)
AWS_ACCOUNT_ID=""
AWS_REGION=""
RESOURCE_PREFIX=""
ENVIRONMENT=""
BUCKET_NAME=""

# Flags
NON_INTERACTIVE=false
DRY_RUN=false
FORCE=false

# State file location
STATE_FILE="${PROJECT_ROOT}/.setup-state.json"

#------------------------------------------------------------------------------
# Helper functions
#------------------------------------------------------------------------------

log_info() {
    echo -e "${BLUE}ℹ${NC} $1"
}

log_success() {
    echo -e "${GREEN}✓${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}⚠${NC} $1"
}

log_error() {
    echo -e "${RED}✗${NC} $1" >&2
}

show_usage() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Setup wizard for serverless-message-wall-demo.
Collects configuration and generates files from templates.

Options:
  --account-id ID       AWS account ID (12-digit number)
  --region REGION       AWS region (default: ${DEFAULT_REGION})
  --resource-prefix PFX Resource prefix for naming (default: ${DEFAULT_RESOURCE_PREFIX})
  --environment ENV     Environment name (default: ${DEFAULT_ENVIRONMENT})
  --non-interactive     Run without prompts (requires --account-id)
  --dry-run             Show what would be generated without writing files
  --force               Overwrite existing configuration without warning
  -h, --help            Show this help message

Examples:
  # Interactive mode (recommended for first-time setup)
  ./scripts/setup.sh

  # Non-interactive mode for CI/CD
  ./scripts/setup.sh --account-id 123456789012 --non-interactive

  # Preview changes without writing files
  ./scripts/setup.sh --dry-run

Environment Variables:
  AWS_ACCOUNT_ID        Can be used instead of --account-id
  AWS_REGION            Can be used instead of --region
  RESOURCE_PREFIX       Can be used instead of --resource-prefix
  ENVIRONMENT           Can be used instead of --environment

EOF
}

#------------------------------------------------------------------------------
# Argument parsing
#------------------------------------------------------------------------------

parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --account-id)
                AWS_ACCOUNT_ID="$2"
                shift 2
                ;;
            --region)
                AWS_REGION="$2"
                shift 2
                ;;
            --resource-prefix)
                RESOURCE_PREFIX="$2"
                shift 2
                ;;
            --environment)
                ENVIRONMENT="$2"
                shift 2
                ;;
            --non-interactive)
                NON_INTERACTIVE=true
                shift
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --force)
                FORCE=true
                shift
                ;;
            -h|--help)
                show_usage
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                show_usage
                exit 1
                ;;
        esac
    done
}

#------------------------------------------------------------------------------
# Auto-detection
#------------------------------------------------------------------------------

detect_aws_account_id() {
    if command -v aws &> /dev/null; then
        local detected
        detected=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || true)
        if [[ -n "${detected}" && "${detected}" != "None" ]]; then
            echo "${detected}"
            return 0
        fi
    fi
    return 1
}

#------------------------------------------------------------------------------
# Interactive prompts
#------------------------------------------------------------------------------

prompt_value() {
    local prompt="$1"
    local default="$2"
    local var_name="$3"
    local value=""
    
    if [[ -n "${default}" ]]; then
        read -rp "${prompt} [${default}]: " value
        value="${value:-${default}}"
    else
        read -rp "${prompt}: " value
    fi
    
    echo "${value}"
}

run_interactive_prompts() {
    echo ""
    echo -e "${BOLD}=== Message Wall Setup Wizard ===${NC}"
    echo ""
    echo "This wizard will configure your local environment for deployment."
    echo "Press Enter to accept defaults shown in brackets."
    echo ""

    # AWS Account ID
    local detected_account=""
    if detected_account=$(detect_aws_account_id); then
        log_info "Detected AWS account from credentials: ${detected_account}"
    fi
    
    if [[ -z "${AWS_ACCOUNT_ID}" ]]; then
        AWS_ACCOUNT_ID=$(prompt_value "AWS Account ID (12 digits)" "${detected_account}" "AWS_ACCOUNT_ID")
    fi

    # AWS Region
    if [[ -z "${AWS_REGION}" ]]; then
        AWS_REGION=$(prompt_value "AWS Region" "${DEFAULT_REGION}" "AWS_REGION")
    fi

    # Resource Prefix
    if [[ -z "${RESOURCE_PREFIX}" ]]; then
        RESOURCE_PREFIX=$(prompt_value "Resource prefix" "${DEFAULT_RESOURCE_PREFIX}" "RESOURCE_PREFIX")
    fi

    # Environment
    if [[ -z "${ENVIRONMENT}" ]]; then
        ENVIRONMENT=$(prompt_value "Environment" "${DEFAULT_ENVIRONMENT}" "ENVIRONMENT")
    fi

    echo ""
}

#------------------------------------------------------------------------------
# Apply defaults and compute derived values
#------------------------------------------------------------------------------

apply_defaults() {
    # Use environment variables as fallback
    AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID:-${AWS_ACCOUNT_ID_ENV:-}}"
    AWS_REGION="${AWS_REGION:-${AWS_REGION_ENV:-${DEFAULT_REGION}}}"
    RESOURCE_PREFIX="${RESOURCE_PREFIX:-${RESOURCE_PREFIX_ENV:-${DEFAULT_RESOURCE_PREFIX}}}"
    ENVIRONMENT="${ENVIRONMENT:-${ENVIRONMENT_ENV:-${DEFAULT_ENVIRONMENT}}}"
    
    # Compute bucket name
    BUCKET_NAME="${RESOURCE_PREFIX}-${ENVIRONMENT}-${AWS_ACCOUNT_ID}"
}

#------------------------------------------------------------------------------
# Validation
#------------------------------------------------------------------------------

validate_inputs() {
    local errors=0

    # AWS Account ID: must be 12 digits
    if [[ -z "${AWS_ACCOUNT_ID}" ]]; then
        log_error "AWS Account ID is required"
        errors=$((errors + 1))
    elif ! [[ "${AWS_ACCOUNT_ID}" =~ ^[0-9]{12}$ ]]; then
        log_error "AWS Account ID must be exactly 12 digits: ${AWS_ACCOUNT_ID}"
        errors=$((errors + 1))
    fi

    # AWS Region: basic format check
    if [[ -z "${AWS_REGION}" ]]; then
        log_error "AWS Region is required"
        errors=$((errors + 1))
    elif ! [[ "${AWS_REGION}" =~ ^[a-z]{2}-[a-z]+-[0-9]+$ ]]; then
        log_error "AWS Region format appears invalid: ${AWS_REGION}"
        errors=$((errors + 1))
    fi

    # Resource Prefix: alphanumeric and hyphens, 3-20 chars
    if [[ -z "${RESOURCE_PREFIX}" ]]; then
        log_error "Resource prefix is required"
        errors=$((errors + 1))
    elif ! [[ "${RESOURCE_PREFIX}" =~ ^[a-z][a-z0-9-]{2,19}$ ]]; then
        log_error "Resource prefix must be 3-20 lowercase alphanumeric characters (hyphens allowed): ${RESOURCE_PREFIX}"
        errors=$((errors + 1))
    fi

    # Environment: alphanumeric, 2-10 chars
    if [[ -z "${ENVIRONMENT}" ]]; then
        log_error "Environment is required"
        errors=$((errors + 1))
    elif ! [[ "${ENVIRONMENT}" =~ ^[a-z][a-z0-9]{1,9}$ ]]; then
        log_error "Environment must be 2-10 lowercase alphanumeric characters: ${ENVIRONMENT}"
        errors=$((errors + 1))
    fi

    # Bucket name length check (S3 limit is 63 chars)
    if [[ ${#BUCKET_NAME} -gt 63 ]]; then
        log_error "Bucket name too long (${#BUCKET_NAME} chars, max 63): ${BUCKET_NAME}"
        errors=$((errors + 1))
    fi

    if [[ ${errors} -gt 0 ]]; then
        return 1
    fi
    return 0
}

#------------------------------------------------------------------------------
# State management
#------------------------------------------------------------------------------

check_existing_state() {
    if [[ -f "${STATE_FILE}" ]]; then
        log_warn "Setup has already been run. Previous configuration:"
        echo ""
        cat "${STATE_FILE}"
        echo ""
        
        if [[ "${FORCE}" == "true" ]]; then
            log_info "Proceeding with --force flag"
            return 0
        fi
        
        if [[ "${NON_INTERACTIVE}" == "true" ]]; then
            log_error "Setup already run. Use --force to overwrite."
            return 1
        fi
        
        read -rp "Overwrite existing configuration? [y/N]: " confirm
        if [[ ! "${confirm}" =~ ^[Yy]$ ]]; then
            log_info "Aborted. Use --force to overwrite."
            return 1
        fi
    fi
    return 0
}

save_state() {
    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    
    cat > "${STATE_FILE}" << EOF
{
  "version": 1,
  "completed_at": "${timestamp}",
  "config": {
    "aws_account_id": "${AWS_ACCOUNT_ID}",
    "aws_region": "${AWS_REGION}",
    "resource_prefix": "${RESOURCE_PREFIX}",
    "environment": "${ENVIRONMENT}",
    "bucket_name": "${BUCKET_NAME}"
  }
}
EOF
    log_success "Saved configuration to ${STATE_FILE}"
}

#------------------------------------------------------------------------------
# Template processing
#------------------------------------------------------------------------------

# List of template files and their output locations
declare -a TEMPLATE_FILES=(
    "infra/base/iam.yaml.template:infra/base/iam.yaml"
    "infra/base/eventbridge.yaml.template:infra/base/eventbridge.yaml"
    "infra/base/lambda.yaml.template:infra/base/lambda.yaml"
    "infra/base/s3.yaml.template:infra/base/s3.yaml"
    "infra/base/dynamodb.yaml.template:infra/base/dynamodb.yaml"
    "infra/base/function-url.yaml.template:infra/base/function-url.yaml"
    "app/web/index.html.template:app/web/index.html"
    "platform/iam/crossplane-actuator-policy.json.template:platform/iam/crossplane-actuator-policy.json"
    "platform/iam/messagewall-role-boundary.json.template:platform/iam/messagewall-role-boundary.json"
    "scripts/cleanup.sh.template:scripts/cleanup.sh"
    "scripts/smoke-test.sh.template:scripts/smoke-test.sh"
    "scripts/deploy-dev.sh.template:scripts/deploy-dev.sh"
)

process_templates() {
    echo ""
    log_info "Processing templates..."
    echo ""
    
    # Export variables for envsubst
    export AWS_ACCOUNT_ID
    export AWS_REGION
    export RESOURCE_PREFIX
    export ENVIRONMENT
    export BUCKET_NAME
    export API_URL="\${API_URL}"  # Placeholder for post-deploy finalization
    
    # Variables to substitute (explicit list to avoid substituting shell variables)
    local SUBST_VARS='${AWS_ACCOUNT_ID} ${AWS_REGION} ${RESOURCE_PREFIX} ${ENVIRONMENT} ${BUCKET_NAME} ${API_URL}'
    
    local processed=0
    local template output
    
    for mapping in "${TEMPLATE_FILES[@]}"; do
        template="${PROJECT_ROOT}/${mapping%%:*}"
        output="${PROJECT_ROOT}/${mapping##*:}"
        
        if [[ ! -f "${template}" ]]; then
            log_warn "Template not found: ${template}"
            continue
        fi
        
        if [[ "${DRY_RUN}" == "true" ]]; then
            echo "  Would generate: ${output##${PROJECT_ROOT}/}"
        else
            envsubst "${SUBST_VARS}" < "${template}" > "${output}"
            
            # Make scripts executable
            if [[ "${output}" == *.sh ]]; then
                chmod +x "${output}"
            fi
            
            log_success "Generated: ${output##${PROJECT_ROOT}/}"
        fi
        processed=$((processed + 1))
    done
    
    echo ""
    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "Dry run complete. ${processed} files would be generated."
    else
        log_success "Generated ${processed} files from templates."
    fi
}

#------------------------------------------------------------------------------
# Summary
#------------------------------------------------------------------------------

show_summary() {
    echo ""
    echo -e "${BOLD}=== Configuration Summary ===${NC}"
    echo ""
    echo "  AWS Account ID:    ${AWS_ACCOUNT_ID}"
    echo "  AWS Region:        ${AWS_REGION}"
    echo "  Resource Prefix:   ${RESOURCE_PREFIX}"
    echo "  Environment:       ${ENVIRONMENT}"
    echo "  Bucket Name:       ${BUCKET_NAME}"
    echo ""
}

show_next_steps() {
    echo ""
    echo -e "${BOLD}=== Next Steps ===${NC}"
    echo ""
    echo "1. Review the generated files (optional):"
    echo "   git diff"
    echo ""
    echo "2. Create the IAM permission boundary policy in AWS:"
    echo "   aws iam create-policy --policy-name MessageWallRoleBoundary \\"
    echo "     --policy-document file://platform/iam/messagewall-role-boundary.json"
    echo ""
    echo "3. Run the prerequisites check:"
    echo "   ./scripts/check-prerequisites.sh"
    echo ""
    echo "4. Bootstrap the actuator cluster:"
    echo "   ./scripts/bootstrap-kind.sh"
    echo "   ./scripts/bootstrap-crossplane.sh"
    echo "   ./scripts/bootstrap-aws-providers.sh"
    echo ""
    echo "5. Deploy the application:"
    echo "   ./scripts/deploy-dev.sh"
    echo ""
    echo "6. After deployment, finalize the web app with the Function URL:"
    echo "   ./scripts/finalize-web.sh"
    echo ""
}

#------------------------------------------------------------------------------
# Main
#------------------------------------------------------------------------------

main() {
    # Save original env vars before parsing (for fallback)
    AWS_ACCOUNT_ID_ENV="${AWS_ACCOUNT_ID:-}"
    AWS_REGION_ENV="${AWS_REGION:-}"
    RESOURCE_PREFIX_ENV="${RESOURCE_PREFIX:-}"
    ENVIRONMENT_ENV="${ENVIRONMENT:-}"
    
    # Reset for clean parsing
    AWS_ACCOUNT_ID=""
    AWS_REGION=""
    RESOURCE_PREFIX=""
    ENVIRONMENT=""
    
    parse_args "$@"
    
    # Check for existing state
    if ! check_existing_state; then
        exit 1
    fi
    
    # Interactive or non-interactive mode
    if [[ "${NON_INTERACTIVE}" == "false" ]]; then
        run_interactive_prompts
    fi
    
    # Apply defaults and compute derived values
    apply_defaults
    
    # Validate inputs
    if ! validate_inputs; then
        echo ""
        log_error "Validation failed. Please fix the errors above."
        exit 1
    fi
    
    # Show summary
    show_summary
    
    # In interactive mode, confirm before proceeding
    if [[ "${NON_INTERACTIVE}" == "false" && "${DRY_RUN}" == "false" ]]; then
        read -rp "Generate files with this configuration? [Y/n]: " confirm
        if [[ "${confirm}" =~ ^[Nn]$ ]]; then
            log_info "Aborted."
            exit 0
        fi
    fi
    
    # Process templates
    process_templates
    
    # Save state (unless dry run)
    if [[ "${DRY_RUN}" == "false" ]]; then
        save_state
        show_next_steps
    fi
}

main "$@"
