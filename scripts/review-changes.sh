#!/usr/bin/env bash
#
# Local Code Review using Claude Code CLI
# Reviews your changes against main branch before pushing.
# Uses your Claude Max subscription (no API costs).
#
# Usage:
#   ./scripts/review-changes.sh           # Review current changes vs main
#   ./scripts/review-changes.sh --fix     # Review and offer to fix issues
#   ./scripts/review-changes.sh --hook    # Exit non-zero if REQUEST_CHANGES (for git hooks)
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

# Parse arguments
FIX_MODE=false
HOOK_MODE=false
BASE_BRANCH="main"

while [[ $# -gt 0 ]]; do
    case $1 in
        --fix)
            FIX_MODE=true
            shift
            ;;
        --hook)
            HOOK_MODE=true
            shift
            ;;
        --base)
            BASE_BRANCH="$2"
            shift 2
            ;;
        --help)
            cat << EOF
Usage: $(basename "$0") [OPTIONS]

Review changes using Claude Code CLI (uses your Max subscription).

Options:
  --fix         After review, offer to fix any issues found
  --hook        Exit with code 1 if review requests changes (for git hooks)
  --base BRANCH Compare against this branch (default: main)
  --help        Show this help

Examples:
  $(basename "$0")                    # Review changes
  $(basename "$0") --fix              # Review and fix issues
  $(basename "$0") --hook             # Use in pre-push hook
EOF
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Check for claude CLI
if ! command -v claude &> /dev/null; then
    log_error "Claude Code CLI not found. Install it first."
    exit 1
fi

cd "$REPO_ROOT"

# Get current branch
CURRENT_BRANCH=$(git branch --show-current)

if [[ "$CURRENT_BRANCH" == "$BASE_BRANCH" ]]; then
    log_warn "You're on $BASE_BRANCH. Review works best on feature branches."
    log_info "Reviewing uncommitted changes instead..."
    DIFF_CMD="git diff HEAD"
    CHANGED_FILES_CMD="git diff --name-only HEAD"
else
    log_info "Reviewing changes: $CURRENT_BRANCH vs $BASE_BRANCH"
    DIFF_CMD="git diff $BASE_BRANCH...$CURRENT_BRANCH"
    CHANGED_FILES_CMD="git diff --name-only $BASE_BRANCH...$CURRENT_BRANCH"
fi

# Get the diff
DIFF=$($DIFF_CMD 2>/dev/null || echo "")
CHANGED_FILES=$($CHANGED_FILES_CMD 2>/dev/null || echo "")

if [[ -z "$DIFF" ]]; then
    log_success "No changes to review."
    exit 0
fi

# Count changes
LINES_CHANGED=$(echo "$DIFF" | wc -l | tr -d ' ')
FILES_CHANGED=$(echo "$CHANGED_FILES" | grep -c . || echo "0")

log_info "Files changed: $FILES_CHANGED"
log_info "Lines in diff: $LINES_CHANGED"
echo ""

# Check if diff is too large
if [[ "$LINES_CHANGED" -gt 3000 ]]; then
    log_warn "Large diff ($LINES_CHANGED lines). Truncating to 2000 lines for review."
    DIFF=$(echo "$DIFF" | head -n 2000)
    DIFF="$DIFF

... (truncated, showing first 2000 lines of $LINES_CHANGED total)"
fi

# Build the review prompt
REVIEW_PROMPT=$(cat << 'EOF'
Review this code diff for a pull request. Check against the project standards.

## Review Criteria
1. Code quality and correctness
2. Security issues or vulnerabilities
3. Follows project conventions (see CONTRIBUTING.md in context)
4. Commit message format (Conventional Commits required)
5. Potential bugs or edge cases

## Response Format
Respond with EXACTLY this format:

### Verdict
<APPROVE | COMMENT | REQUEST_CHANGES>

### Summary
<1-2 sentence assessment>

### Issues
<Bulleted list of problems, or "None">

### Suggestions
<Optional improvements>

Be concise. Focus on real issues, not style nitpicks.

## Changes to Review

EOF
)

REVIEW_PROMPT="$REVIEW_PROMPT
Files changed:
$CHANGED_FILES

Diff:
\`\`\`diff
$DIFF
\`\`\`"

# Run Claude Code review
log_info "Running Claude Code review..."
echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}                      CODE REVIEW                              ${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
echo ""

# Use claude CLI with --print to get the review
REVIEW_OUTPUT=$(echo "$REVIEW_PROMPT" | claude --print 2>&1) || {
    log_error "Claude Code review failed"
    echo "$REVIEW_OUTPUT"
    exit 1
}

echo "$REVIEW_OUTPUT"
echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
echo ""

# Extract verdict
VERDICT=$(echo "$REVIEW_OUTPUT" | grep -A1 "### Verdict" | tail -1 | tr -d ' ' | tr '[:upper:]' '[:lower:]')

case "$VERDICT" in
    *approve*)
        log_success "Review verdict: APPROVE"
        EXIT_CODE=0
        ;;
    *request_changes*|*request*)
        log_warn "Review verdict: REQUEST_CHANGES"
        EXIT_CODE=1
        ;;
    *)
        log_info "Review verdict: COMMENT"
        EXIT_CODE=0
        ;;
esac

# Fix mode - offer to address issues
if [[ "$FIX_MODE" == "true" && "$EXIT_CODE" -ne 0 ]]; then
    echo ""
    read -p "Would you like Claude to fix these issues? [y/N] " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        log_info "Invoking Claude Code to fix issues..."

        FIX_PROMPT="The code review found issues that need fixing:

$REVIEW_OUTPUT

Please address each issue mentioned above. Make the necessary code changes and commit them with a proper commit message following Conventional Commits format."

        echo "$FIX_PROMPT" | claude --dangerously-skip-permissions 2>&1

        log_success "Fixes applied. Review the changes and run this script again."
    fi
fi

# Hook mode - exit with error if changes requested
if [[ "$HOOK_MODE" == "true" ]]; then
    if [[ "$EXIT_CODE" -ne 0 ]]; then
        log_error "Push blocked: Review requested changes."
        log_info "Fix the issues and try again, or use --no-verify to skip."
    fi
    exit $EXIT_CODE
fi

exit 0
