#!/usr/bin/env bash
#
# PR Feedback Loop
# Watches a PR for review comments and invokes Claude Code to address them.
#
# Usage: ./scripts/pr-feedback-loop.sh <PR_NUMBER>
#
# Requirements:
# - gh CLI installed and authenticated
# - claude CLI installed (Claude Code)
#
# The script will:
# 1. Poll for new review comments on the PR
# 2. When found, invoke Claude Code to address the feedback
# 3. Commit and push fixes
# 4. Repeat until PR is approved or you press Ctrl+C
#

set -euo pipefail

# Configuration
POLL_INTERVAL=${POLL_INTERVAL:-30}  # seconds between checks
MAX_ITERATIONS=${MAX_ITERATIONS:-10}  # prevent infinite loops
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

usage() {
    cat << EOF
Usage: $(basename "$0") <PR_NUMBER> [OPTIONS]

Watch a PR for review comments and use Claude Code to address them.

Arguments:
  PR_NUMBER          The pull request number to watch

Options:
  --interval SECS    Polling interval in seconds (default: 30)
  --max-iterations N Maximum feedback iterations (default: 10)
  --dry-run          Show what would happen without making changes
  --help             Show this help message

Environment:
  POLL_INTERVAL      Same as --interval
  MAX_ITERATIONS     Same as --max-iterations

Examples:
  $(basename "$0") 42
  $(basename "$0") 42 --interval 60 --max-iterations 5
EOF
    exit 0
}

# Parse arguments
DRY_RUN=false
PR_NUMBER=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --interval)
            POLL_INTERVAL="$2"
            shift 2
            ;;
        --max-iterations)
            MAX_ITERATIONS="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --help)
            usage
            ;;
        -*)
            log_error "Unknown option: $1"
            usage
            ;;
        *)
            if [[ -z "$PR_NUMBER" ]]; then
                PR_NUMBER="$1"
            else
                log_error "Unexpected argument: $1"
                usage
            fi
            shift
            ;;
    esac
done

if [[ -z "$PR_NUMBER" ]]; then
    log_error "PR number is required"
    usage
fi

# Check dependencies
check_dependencies() {
    local missing=()

    if ! command -v gh &> /dev/null; then
        missing+=("gh (GitHub CLI)")
    fi

    if ! command -v claude &> /dev/null; then
        missing+=("claude (Claude Code CLI)")
    fi

    if ! command -v jq &> /dev/null; then
        missing+=("jq")
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required dependencies:"
        for dep in "${missing[@]}"; do
            echo "  - $dep"
        done
        exit 1
    fi

    # Check gh auth
    if ! gh auth status &> /dev/null; then
        log_error "GitHub CLI not authenticated. Run: gh auth login"
        exit 1
    fi
}

# Get PR details
get_pr_info() {
    gh pr view "$PR_NUMBER" --json number,title,state,reviewDecision,headRefName,url
}

# Get review comments that need addressing
get_pending_reviews() {
    # Get reviews that requested changes or have unresolved comments
    gh api "repos/{owner}/{repo}/pulls/$PR_NUMBER/reviews" \
        --jq '[.[] | select(.state == "CHANGES_REQUESTED" or .state == "COMMENTED")] | last'
}

# Get the latest review comment/body
get_latest_review_feedback() {
    local review_json="$1"

    if [[ -z "$review_json" || "$review_json" == "null" ]]; then
        echo ""
        return
    fi

    # Extract the review body
    echo "$review_json" | jq -r '.body // ""'
}

# Get unresolved review comments (line-level comments)
get_unresolved_comments() {
    gh api "repos/{owner}/{repo}/pulls/$PR_NUMBER/comments" \
        --jq '[.[] | select(.in_reply_to_id == null)] | .[-5:] | .[].body' 2>/dev/null || echo ""
}

# Check if PR is approved
is_pr_approved() {
    local review_decision
    review_decision=$(gh pr view "$PR_NUMBER" --json reviewDecision --jq '.reviewDecision')
    [[ "$review_decision" == "APPROVED" ]]
}

# Check if PR is merged or closed
is_pr_closed() {
    local state
    state=$(gh pr view "$PR_NUMBER" --json state --jq '.state')
    [[ "$state" != "OPEN" ]]
}

# Build prompt for Claude with the feedback
build_claude_prompt() {
    local feedback="$1"
    local comments="$2"

    cat << EOF
A PR review has provided feedback that needs to be addressed. Please:

1. Read and understand the feedback
2. Make the necessary code changes to address the issues
3. Commit the changes with a proper commit message
4. Do NOT push (I will handle that)

## Review Feedback

$feedback

## Additional Comments

$comments

## Instructions

- Address each point raised in the feedback
- Follow the project's commit message format (Conventional Commits)
- If you disagree with feedback, explain why in the commit message body
- Focus on substantive issues, not style nitpicks unless specifically called out
EOF
}

# Invoke Claude Code to address feedback
invoke_claude() {
    local prompt="$1"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would invoke Claude with prompt:"
        echo "---"
        echo "$prompt"
        echo "---"
        return 0
    fi

    log_info "Invoking Claude Code to address feedback..."

    # Run claude in the repo directory with the prompt
    # Using --print to get output, --dangerously-skip-permissions for automation
    cd "$REPO_ROOT"

    echo "$prompt" | claude --print --dangerously-skip-permissions 2>&1 || {
        log_error "Claude Code invocation failed"
        return 1
    }
}

# Push changes if any
push_changes() {
    cd "$REPO_ROOT"

    # Check if there are new commits to push
    local local_commits
    local_commits=$(git rev-list --count HEAD ^@{u} 2>/dev/null || echo "0")

    if [[ "$local_commits" -gt 0 ]]; then
        if [[ "$DRY_RUN" == "true" ]]; then
            log_info "[DRY RUN] Would push $local_commits commit(s)"
            return 0
        fi

        log_info "Pushing $local_commits new commit(s)..."
        git push
        log_success "Changes pushed"
        return 0
    else
        log_info "No new commits to push"
        return 1
    fi
}

# Main feedback loop
main() {
    check_dependencies

    log_info "Starting PR feedback loop for PR #$PR_NUMBER"
    log_info "Poll interval: ${POLL_INTERVAL}s, Max iterations: $MAX_ITERATIONS"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_warn "DRY RUN MODE - no changes will be made"
    fi

    # Get initial PR info
    local pr_info
    pr_info=$(get_pr_info)
    local pr_title pr_url pr_branch
    pr_title=$(echo "$pr_info" | jq -r '.title')
    pr_url=$(echo "$pr_info" | jq -r '.url')
    pr_branch=$(echo "$pr_info" | jq -r '.headRefName')

    log_info "PR: $pr_title"
    log_info "URL: $pr_url"
    log_info "Branch: $pr_branch"
    echo ""

    # Checkout the PR branch
    log_info "Checking out branch: $pr_branch"
    cd "$REPO_ROOT"
    git checkout "$pr_branch" 2>/dev/null || git checkout -b "$pr_branch" "origin/$pr_branch"
    git pull --rebase origin "$pr_branch" 2>/dev/null || true

    local iteration=0
    local last_review_id=""

    while [[ $iteration -lt $MAX_ITERATIONS ]]; do
        ((iteration++))

        log_info "=== Iteration $iteration/$MAX_ITERATIONS ==="

        # Check if PR is closed
        if is_pr_closed; then
            log_success "PR is no longer open (merged or closed). Exiting."
            exit 0
        fi

        # Check if PR is approved
        if is_pr_approved; then
            log_success "PR is approved! Exiting feedback loop."
            exit 0
        fi

        # Get latest review
        local review_json
        review_json=$(get_pending_reviews)

        local review_id=""
        if [[ -n "$review_json" && "$review_json" != "null" ]]; then
            review_id=$(echo "$review_json" | jq -r '.id')
        fi

        # Check if this is new feedback
        if [[ -n "$review_id" && "$review_id" != "$last_review_id" ]]; then
            log_info "New review feedback detected (ID: $review_id)"

            local feedback comments
            feedback=$(get_latest_review_feedback "$review_json")
            comments=$(get_unresolved_comments)

            if [[ -n "$feedback" || -n "$comments" ]]; then
                log_info "Feedback to address:"
                echo "---"
                [[ -n "$feedback" ]] && echo "$feedback"
                [[ -n "$comments" ]] && echo -e "\nComments:\n$comments"
                echo "---"
                echo ""

                # Build prompt and invoke Claude
                local prompt
                prompt=$(build_claude_prompt "$feedback" "$comments")

                if invoke_claude "$prompt"; then
                    # Try to push changes
                    if push_changes; then
                        log_success "Changes pushed. Waiting for new review..."
                        last_review_id="$review_id"
                    fi
                fi
            else
                log_info "Review has no actionable feedback text"
                last_review_id="$review_id"
            fi
        else
            log_info "No new feedback. Waiting..."
        fi

        # Wait before next poll
        log_info "Sleeping for ${POLL_INTERVAL}s... (Ctrl+C to exit)"
        sleep "$POLL_INTERVAL"
    done

    log_warn "Reached maximum iterations ($MAX_ITERATIONS). Exiting."
    log_info "Run again to continue, or address remaining feedback manually."
    exit 1
}

# Handle Ctrl+C gracefully
trap 'echo ""; log_info "Interrupted by user. Exiting."; exit 0' INT

main
