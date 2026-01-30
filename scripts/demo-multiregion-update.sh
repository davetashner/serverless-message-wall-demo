#!/bin/bash
set -euo pipefail

# Demo script: Cross-region bulk configuration update
# Demonstrates ConfigHub as single authority for multi-region deployments
#
# This script pushes a configuration change (Lambda timeout) to both
# regional ConfigHub spaces simultaneously, showing how a single
# command can affect infrastructure in multiple AWS regions.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Regional configuration
REGIONS=("east" "west")
declare -A SPACES=(
    ["east"]="messagewall-dev-east"
    ["west"]="messagewall-dev-west"
)
declare -A AWS_REGIONS=(
    ["east"]="us-east-1"
    ["west"]="us-west-2"
)

usage() {
    cat <<EOF
Usage: $(basename "$0") [COMMAND] [OPTIONS]

Cross-region bulk configuration update demo.

Demonstrates updating Lambda timeout across multiple regions simultaneously
through ConfigHub, showing "one authority, multiple actuators" pattern.

COMMANDS:
    timeout VALUE   Set Lambda timeout to VALUE seconds (default: show current)
    memory VALUE    Set Lambda memory to VALUE MB (128, 256, 512, 1024)
    show            Show current configuration in both regions
    reset           Reset to default values (timeout: 10s, memory: 128MB)

OPTIONS:
    --apply         Apply changes after publishing (make them live)
    --dry-run       Show what would be changed without executing
    -h, --help      Show this help message

PREREQUISITES:
    - cub CLI installed and authenticated
    - Regional ConfigHub spaces exist (messagewall-dev-east, messagewall-dev-west)
    - Regional manifests published

EXAMPLES:
    # Show current configuration
    $(basename "$0") show

    # Update Lambda timeout to 30 seconds in both regions
    $(basename "$0") timeout 30 --apply

    # Update Lambda memory to 256MB
    $(basename "$0") memory 256 --apply

    # Reset to defaults
    $(basename "$0") reset --apply

DEMO NARRATIVE:
    "Watch as a single command updates infrastructure in us-east-1 AND us-west-2.
     ConfigHub is the single authority - one push, multiple actuators reconcile."

EOF
    exit 0
}

DRY_RUN=false
APPLY=false
COMMAND=""
VALUE=""

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        timeout|memory|show|reset)
            COMMAND="$1"
            if [[ "$1" != "show" && "$1" != "reset" && $# -gt 1 && ! "$2" =~ ^-- ]]; then
                VALUE="$2"
                shift
            fi
            shift
            ;;
        --apply)
            APPLY=true
            shift
            ;;
        --dry-run)
            DRY_RUN=true
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

# Default to show if no command
if [[ -z "${COMMAND}" ]]; then
    COMMAND="show"
fi

# Check prerequisites
if ! command -v cub &> /dev/null; then
    echo "Error: cub CLI is not installed"
    exit 1
fi

if ! cub auth status &> /dev/null; then
    echo "Error: Not authenticated to ConfigHub. Run: cub auth login"
    exit 1
fi

show_config() {
    echo "=== Current Multi-Region Configuration ==="
    echo ""

    for region in "${REGIONS[@]}"; do
        space="${SPACES[$region]}"
        aws_region="${AWS_REGIONS[$region]}"

        echo "Region: ${region} (${aws_region}) - Space: ${space}"

        # Try to get current lambda.yaml content
        if content=$(cub unit get --space "${space}" lambda --format yaml 2>/dev/null); then
            timeout=$(echo "$content" | grep -A1 "timeout:" | tail -1 | tr -d ' ' || echo "unknown")
            memory=$(echo "$content" | grep -A1 "memorySize:" | tail -1 | tr -d ' ' || echo "unknown")
            echo "  Lambda timeout:  ${timeout}s"
            echo "  Lambda memory:   ${memory}MB"
        else
            echo "  (No lambda unit found - run publish-messagewall.sh first)"
        fi
        echo ""
    done
}

update_timeout() {
    local new_timeout="$1"

    echo "=== Updating Lambda Timeout Across Regions ==="
    echo "New timeout: ${new_timeout} seconds"
    echo ""

    for region in "${REGIONS[@]}"; do
        space="${SPACES[$region]}"
        aws_region="${AWS_REGIONS[$region]}"
        manifest_dir="${PROJECT_ROOT}/infra/messagewall-${region}"
        lambda_file="${manifest_dir}/lambda.yaml"

        echo "Region: ${region} (${aws_region})"

        if [[ ! -f "${lambda_file}" ]]; then
            echo "  Error: ${lambda_file} not found"
            continue
        fi

        if [[ "${DRY_RUN}" == "true" ]]; then
            echo "  [DRY RUN] Would update timeout to ${new_timeout} in ${lambda_file}"
            echo "  [DRY RUN] Would publish to space ${space}"
        else
            # Update the local manifest
            echo "  Updating local manifest..."
            sed -i.bak "s/timeout: [0-9]*/timeout: ${new_timeout}/" "${lambda_file}"
            rm -f "${lambda_file}.bak"

            # Publish to ConfigHub
            echo "  Publishing to ConfigHub space: ${space}"
            if cub unit update --space "${space}" lambda "${lambda_file}" 2>/dev/null; then
                echo "  Published successfully"

                if [[ "${APPLY}" == "true" ]]; then
                    echo "  Applying revision..."
                    cub unit apply --space "${space}" lambda 2>/dev/null || true
                fi
            else
                echo "  Error: Failed to publish"
            fi
        fi
        echo ""
    done

    if [[ "${APPLY}" == "true" && "${DRY_RUN}" == "false" ]]; then
        echo "Changes applied! Both regional actuator clusters will reconcile."
        echo ""
        echo "Watch reconciliation:"
        echo "  kubectl get functions -A --context kind-actuator-east"
        echo "  kubectl get functions -A --context kind-actuator-west"
    fi
}

update_memory() {
    local new_memory="$1"

    # Validate memory value
    if [[ ! "${new_memory}" =~ ^(128|256|512|1024|2048)$ ]]; then
        echo "Error: Invalid memory value. Must be: 128, 256, 512, 1024, or 2048"
        exit 1
    fi

    echo "=== Updating Lambda Memory Across Regions ==="
    echo "New memory: ${new_memory} MB"
    echo ""

    for region in "${REGIONS[@]}"; do
        space="${SPACES[$region]}"
        aws_region="${AWS_REGIONS[$region]}"
        manifest_dir="${PROJECT_ROOT}/infra/messagewall-${region}"
        lambda_file="${manifest_dir}/lambda.yaml"

        echo "Region: ${region} (${aws_region})"

        if [[ ! -f "${lambda_file}" ]]; then
            echo "  Error: ${lambda_file} not found"
            continue
        fi

        if [[ "${DRY_RUN}" == "true" ]]; then
            echo "  [DRY RUN] Would update memorySize to ${new_memory} in ${lambda_file}"
            echo "  [DRY RUN] Would publish to space ${space}"
        else
            # Update the local manifest
            echo "  Updating local manifest..."
            sed -i.bak "s/memorySize: [0-9]*/memorySize: ${new_memory}/" "${lambda_file}"
            rm -f "${lambda_file}.bak"

            # Publish to ConfigHub
            echo "  Publishing to ConfigHub space: ${space}"
            if cub unit update --space "${space}" lambda "${lambda_file}" 2>/dev/null; then
                echo "  Published successfully"

                if [[ "${APPLY}" == "true" ]]; then
                    echo "  Applying revision..."
                    cub unit apply --space "${space}" lambda 2>/dev/null || true
                fi
            else
                echo "  Error: Failed to publish"
            fi
        fi
        echo ""
    done

    if [[ "${APPLY}" == "true" && "${DRY_RUN}" == "false" ]]; then
        echo "Changes applied! Both regional actuator clusters will reconcile."
    fi
}

reset_config() {
    echo "=== Resetting to Default Configuration ==="
    echo "Defaults: timeout=10s, memorySize=128MB"
    echo ""

    for region in "${REGIONS[@]}"; do
        space="${SPACES[$region]}"
        aws_region="${AWS_REGIONS[$region]}"
        manifest_dir="${PROJECT_ROOT}/infra/messagewall-${region}"
        lambda_file="${manifest_dir}/lambda.yaml"

        echo "Region: ${region} (${aws_region})"

        if [[ ! -f "${lambda_file}" ]]; then
            echo "  Error: ${lambda_file} not found"
            continue
        fi

        if [[ "${DRY_RUN}" == "true" ]]; then
            echo "  [DRY RUN] Would reset timeout to 10 and memorySize to 128"
        else
            echo "  Updating local manifest..."
            sed -i.bak "s/timeout: [0-9]*/timeout: 10/" "${lambda_file}"
            sed -i.bak "s/memorySize: [0-9]*/memorySize: 128/" "${lambda_file}"
            rm -f "${lambda_file}.bak"

            echo "  Publishing to ConfigHub space: ${space}"
            if cub unit update --space "${space}" lambda "${lambda_file}" 2>/dev/null; then
                echo "  Published successfully"

                if [[ "${APPLY}" == "true" ]]; then
                    echo "  Applying revision..."
                    cub unit apply --space "${space}" lambda 2>/dev/null || true
                fi
            else
                echo "  Error: Failed to publish"
            fi
        fi
        echo ""
    done
}

# Execute command
case "${COMMAND}" in
    show)
        show_config
        ;;
    timeout)
        if [[ -z "${VALUE}" ]]; then
            echo "Error: timeout requires a value (e.g., 'timeout 30')"
            exit 1
        fi
        update_timeout "${VALUE}"
        ;;
    memory)
        if [[ -z "${VALUE}" ]]; then
            echo "Error: memory requires a value (e.g., 'memory 256')"
            exit 1
        fi
        update_memory "${VALUE}"
        ;;
    reset)
        reset_config
        ;;
    *)
        echo "Unknown command: ${COMMAND}"
        usage
        ;;
esac
