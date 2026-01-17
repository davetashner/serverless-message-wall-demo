#!/bin/bash
# test-setup.sh - Test suite for the setup wizard
# Covers validation, placeholder replacement, and error handling

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "${SCRIPT_DIR}")"

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Colors
if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    NC='\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    NC=''
fi

#------------------------------------------------------------------------------
# Test helpers
#------------------------------------------------------------------------------

setup_test_env() {
    # Create a temporary directory for testing
    TEST_DIR=$(mktemp -d)
    
    # Copy templates and setup script
    mkdir -p "${TEST_DIR}/scripts"
    mkdir -p "${TEST_DIR}/infra/base"
    mkdir -p "${TEST_DIR}/app/web"
    mkdir -p "${TEST_DIR}/platform/iam"
    
    cp "${PROJECT_ROOT}/scripts/setup.sh" "${TEST_DIR}/scripts/"
    cp "${PROJECT_ROOT}/infra/base/"*.template "${TEST_DIR}/infra/base/" 2>/dev/null || true
    cp "${PROJECT_ROOT}/app/web/"*.template "${TEST_DIR}/app/web/" 2>/dev/null || true
    cp "${PROJECT_ROOT}/platform/iam/"*.template "${TEST_DIR}/platform/iam/" 2>/dev/null || true
    cp "${PROJECT_ROOT}/scripts/"*.template "${TEST_DIR}/scripts/" 2>/dev/null || true
    
    # Update SCRIPT_DIR and PROJECT_ROOT in the copied setup.sh
    # (The script will use its own location)
}

cleanup_test_env() {
    if [[ -n "${TEST_DIR:-}" && -d "${TEST_DIR}" ]]; then
        rm -rf "${TEST_DIR}"
    fi
}

run_test() {
    local name="$1"
    local cmd="$2"
    local expected_exit="$3"
    
    TESTS_RUN=$((TESTS_RUN + 1))
    
    echo -n "  Testing: ${name}... "
    
    set +e
    output=$(eval "${cmd}" 2>&1)
    actual_exit=$?
    set -e
    
    if [[ "${actual_exit}" -eq "${expected_exit}" ]]; then
        echo -e "${GREEN}PASS${NC}"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        return 0
    else
        echo -e "${RED}FAIL${NC}"
        echo "    Expected exit: ${expected_exit}, got: ${actual_exit}"
        echo "    Output: ${output}"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        return 1
    fi
}

run_test_contains() {
    local name="$1"
    local cmd="$2"
    local expected_pattern="$3"
    
    TESTS_RUN=$((TESTS_RUN + 1))
    
    echo -n "  Testing: ${name}... "
    
    set +e
    output=$(eval "${cmd}" 2>&1)
    set -e
    
    if echo "${output}" | grep -q "${expected_pattern}"; then
        echo -e "${GREEN}PASS${NC}"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        return 0
    else
        echo -e "${RED}FAIL${NC}"
        echo "    Expected pattern: ${expected_pattern}"
        echo "    Output: ${output}"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        return 1
    fi
}

#------------------------------------------------------------------------------
# Validation tests
#------------------------------------------------------------------------------

test_validation() {
    echo ""
    echo "=== Validation Tests ==="
    
    # Test: Invalid account ID (too short)
    run_test_contains \
        "rejects short account ID" \
        "${SCRIPT_DIR}/setup.sh --account-id 12345 --non-interactive --dry-run" \
        "must be exactly 12 digits"
    
    # Test: Invalid account ID (letters)
    run_test_contains \
        "rejects non-numeric account ID" \
        "${SCRIPT_DIR}/setup.sh --account-id 12345678901a --non-interactive --dry-run" \
        "must be exactly 12 digits"
    
    # Test: Invalid region format
    run_test_contains \
        "rejects invalid region format" \
        "${SCRIPT_DIR}/setup.sh --account-id 123456789012 --region invalid --non-interactive --dry-run" \
        "Region format appears invalid"
    
    # Test: Invalid resource prefix (starts with number)
    run_test_contains \
        "rejects prefix starting with number" \
        "${SCRIPT_DIR}/setup.sh --account-id 123456789012 --resource-prefix 1abc --non-interactive --dry-run" \
        "Resource prefix must be"
    
    # Test: Invalid resource prefix (too short)
    run_test_contains \
        "rejects prefix too short" \
        "${SCRIPT_DIR}/setup.sh --account-id 123456789012 --resource-prefix ab --non-interactive --dry-run" \
        "Resource prefix must be"
    
    # Test: Invalid environment (uppercase)
    run_test_contains \
        "rejects uppercase environment" \
        "${SCRIPT_DIR}/setup.sh --account-id 123456789012 --environment DEV --non-interactive --dry-run" \
        "Environment must be"
    
    # Test: Valid inputs pass validation
    run_test \
        "accepts valid inputs" \
        "${SCRIPT_DIR}/setup.sh --account-id 123456789012 --region us-west-2 --resource-prefix myapp --environment staging --non-interactive --dry-run" \
        0
}

#------------------------------------------------------------------------------
# Dry-run tests
#------------------------------------------------------------------------------

test_dry_run() {
    echo ""
    echo "=== Dry-Run Tests ==="
    
    # Test: Dry run lists files
    run_test_contains \
        "dry run lists template files" \
        "${SCRIPT_DIR}/setup.sh --account-id 123456789012 --non-interactive --dry-run" \
        "Would generate"
    
    # Test: Dry run shows correct bucket name
    run_test_contains \
        "dry run shows computed bucket name" \
        "${SCRIPT_DIR}/setup.sh --account-id 123456789012 --non-interactive --dry-run" \
        "messagewall-dev-123456789012"
    
    # Test: Dry run doesn't create files
    run_test \
        "dry run creates no state file" \
        "! test -f ${PROJECT_ROOT}/.setup-state.json" \
        0
}

#------------------------------------------------------------------------------
# Template processing tests
#------------------------------------------------------------------------------

test_template_processing() {
    echo ""
    echo "=== Template Processing Tests ==="
    
    setup_test_env
    trap cleanup_test_env EXIT
    
    # Run setup in test directory
    cd "${TEST_DIR}"
    ./scripts/setup.sh --account-id 111122223333 --region eu-west-1 --resource-prefix testapp --environment prod --non-interactive --force 2>/dev/null || true
    cd "${PROJECT_ROOT}"
    
    # Test: State file created
    TESTS_RUN=$((TESTS_RUN + 1))
    echo -n "  Testing: state file created... "
    if [[ -f "${TEST_DIR}/.setup-state.json" ]]; then
        echo -e "${GREEN}PASS${NC}"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}FAIL${NC}"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
    
    # Test: Account ID substituted in IAM template
    TESTS_RUN=$((TESTS_RUN + 1))
    echo -n "  Testing: account ID substituted in iam.yaml... "
    if [[ -f "${TEST_DIR}/infra/base/iam.yaml" ]] && grep -q "111122223333" "${TEST_DIR}/infra/base/iam.yaml"; then
        echo -e "${GREEN}PASS${NC}"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}FAIL${NC}"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
    
    # Test: Region substituted
    TESTS_RUN=$((TESTS_RUN + 1))
    echo -n "  Testing: region substituted in iam.yaml... "
    if [[ -f "${TEST_DIR}/infra/base/iam.yaml" ]] && grep -q "eu-west-1" "${TEST_DIR}/infra/base/iam.yaml"; then
        echo -e "${GREEN}PASS${NC}"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}FAIL${NC}"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
    
    # Test: Resource prefix substituted
    TESTS_RUN=$((TESTS_RUN + 1))
    echo -n "  Testing: resource prefix substituted... "
    if [[ -f "${TEST_DIR}/infra/base/iam.yaml" ]] && grep -q "testapp-api-role" "${TEST_DIR}/infra/base/iam.yaml"; then
        echo -e "${GREEN}PASS${NC}"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}FAIL${NC}"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
    
    # Test: Bucket name computed correctly
    TESTS_RUN=$((TESTS_RUN + 1))
    echo -n "  Testing: bucket name computed correctly... "
    if [[ -f "${TEST_DIR}/.setup-state.json" ]] && grep -q "testapp-prod-111122223333" "${TEST_DIR}/.setup-state.json"; then
        echo -e "${GREEN}PASS${NC}"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}FAIL${NC}"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
    
    # Test: API_URL placeholder preserved in index.html
    TESTS_RUN=$((TESTS_RUN + 1))
    echo -n "  Testing: API_URL placeholder preserved... "
    if [[ -f "${TEST_DIR}/app/web/index.html" ]] && grep -q '\${API_URL}' "${TEST_DIR}/app/web/index.html"; then
        echo -e "${GREEN}PASS${NC}"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}FAIL${NC}"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
    
    # Test: Generated scripts are executable
    TESTS_RUN=$((TESTS_RUN + 1))
    echo -n "  Testing: generated scripts are executable... "
    if [[ -f "${TEST_DIR}/scripts/deploy-dev.sh" && -x "${TEST_DIR}/scripts/deploy-dev.sh" ]]; then
        echo -e "${GREEN}PASS${NC}"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}FAIL${NC}"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
    
    cleanup_test_env
    trap - EXIT
}

#------------------------------------------------------------------------------
# Error handling tests
#------------------------------------------------------------------------------

test_error_handling() {
    echo ""
    echo "=== Error Handling Tests ==="
    
    # Test: Missing required account ID in non-interactive mode
    run_test_contains \
        "errors on missing account ID" \
        "${SCRIPT_DIR}/setup.sh --non-interactive --dry-run 2>&1 || true" \
        "Account ID is required"
    
    # Test: Help flag works
    run_test_contains \
        "help flag shows usage" \
        "${SCRIPT_DIR}/setup.sh --help" \
        "Usage:"
}

#------------------------------------------------------------------------------
# Main
#------------------------------------------------------------------------------

main() {
    echo "========================================"
    echo "  Setup Wizard Test Suite"
    echo "========================================"
    
    # Clean any existing state
    rm -f "${PROJECT_ROOT}/.setup-state.json"
    
    test_validation
    test_dry_run
    test_template_processing
    test_error_handling
    
    echo ""
    echo "========================================"
    echo "  Results: ${TESTS_PASSED}/${TESTS_RUN} passed"
    echo "========================================"
    
    if [[ ${TESTS_FAILED} -gt 0 ]]; then
        echo -e "${RED}${TESTS_FAILED} test(s) failed${NC}"
        exit 1
    else
        echo -e "${GREEN}All tests passed!${NC}"
        exit 0
    fi
}

main "$@"
