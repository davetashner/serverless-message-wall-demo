#!/bin/bash
# sync-confighub-to-git.sh
#
# Phase 1 of ADR-011 bidirectional sync: ConfigHub → Git
#
# This script exports the current state from ConfigHub and creates a PR
# if it differs from what Git would render. This ensures Git stays informed
# of all ConfigHub changes (bulk changes, policy adjustments, break-glass).
#
# Usage:
#   ./scripts/sync-confighub-to-git.sh [--dry-run] [--space SPACE] [--env ENV]
#
# Prerequisites:
#   - cub CLI installed and authenticated
#   - gh CLI installed and authenticated (for PR creation)
#   - Git working directory clean

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Defaults
DRY_RUN=false
SPACE=""
ENV="dev"
SYNC_DIR="confighub-sync"

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Export ConfigHub state and create a PR if it differs from Git.

Options:
    --dry-run       Show what would change without creating PR
    --space SPACE   ConfigHub space name (default: from config/<env>.env)
    --env ENV       Environment name (default: dev)
    -h, --help      Show this help message

Examples:
    $(basename "$0")                    # Sync dev environment
    $(basename "$0") --dry-run          # Preview changes without PR
    $(basename "$0") --env prod         # Sync prod environment
EOF
    exit 0
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --space)
            SPACE="$2"
            shift 2
            ;;
        --env)
            ENV="$2"
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

# Load environment config
ENV_FILE="$REPO_ROOT/config/${ENV}.env"
if [[ ! -f "$ENV_FILE" ]]; then
    echo "Error: Config file not found: $ENV_FILE"
    exit 1
fi

# shellcheck disable=SC1090
source "$ENV_FILE"

# Use provided space or from config
SPACE="${SPACE:-$CONFIGHUB_SPACE}"

echo "=== ConfigHub → Git Sync ==="
echo "Environment: $ENV"
echo "ConfigHub Space: $SPACE"
echo "Dry run: $DRY_RUN"
echo ""

# Check prerequisites
command -v cub >/dev/null 2>&1 || { echo "Error: cub CLI not found"; exit 1; }
command -v gh >/dev/null 2>&1 || { echo "Error: gh CLI not found"; exit 1; }

# Create temporary directory for sync
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

echo "Exporting units from ConfigHub space: $SPACE"

# Get list of units in the space
UNITS=$(cub unit list --space "$SPACE" --format json 2>/dev/null | jq -r '.[].name' || echo "")

if [[ -z "$UNITS" ]]; then
    echo "No units found in space $SPACE"
    exit 0
fi

# Export each unit
mkdir -p "$WORK_DIR/confighub"
for unit in $UNITS; do
    echo "  Exporting: $unit"
    cub unit export --space "$SPACE" "$unit" > "$WORK_DIR/confighub/${unit}.yaml" 2>/dev/null || {
        echo "  Warning: Failed to export unit $unit"
        continue
    }
done

# Render Git templates for comparison
echo ""
echo "Rendering Git templates for comparison..."
mkdir -p "$WORK_DIR/git"

for template in "$REPO_ROOT/infra/base/"*.yaml.template; do
    [[ -f "$template" ]] || continue
    outfile="$WORK_DIR/git/$(basename "${template%.template}")"
    envsubst '${AWS_ACCOUNT_ID} ${AWS_REGION} ${RESOURCE_PREFIX} ${ENVIRONMENT} ${BUCKET_NAME}' < "$template" > "$outfile"
done

# Compare and find differences
echo ""
echo "Comparing ConfigHub state with Git-rendered state..."

CHANGES_FOUND=false
CHANGE_SUMMARY=""

for ch_file in "$WORK_DIR/confighub/"*.yaml; do
    [[ -f "$ch_file" ]] || continue
    unit=$(basename "$ch_file")
    git_file="$WORK_DIR/git/$unit"

    if [[ ! -f "$git_file" ]]; then
        echo "  NEW: $unit (exists in ConfigHub, not in Git templates)"
        CHANGES_FOUND=true
        CHANGE_SUMMARY+="- NEW: $unit (ConfigHub has unit not in Git)\n"
        continue
    fi

    # Compare YAML content (normalize whitespace/ordering)
    if ! diff -q <(yq eval -P "$ch_file" 2>/dev/null || cat "$ch_file") \
                 <(yq eval -P "$git_file" 2>/dev/null || cat "$git_file") >/dev/null 2>&1; then
        echo "  CHANGED: $unit"
        CHANGES_FOUND=true
        CHANGE_SUMMARY+="- CHANGED: $unit\n"

        if [[ "$DRY_RUN" == "true" ]]; then
            echo "    Diff:"
            diff -u "$git_file" "$ch_file" | head -50 || true
        fi
    else
        echo "  MATCH: $unit"
    fi
done

# Check for units in Git but not in ConfigHub
for git_file in "$WORK_DIR/git/"*.yaml; do
    [[ -f "$git_file" ]] || continue
    unit=$(basename "$git_file")
    ch_file="$WORK_DIR/confighub/$unit"

    if [[ ! -f "$ch_file" ]]; then
        echo "  MISSING: $unit (in Git, not in ConfigHub)"
        # This is expected if CI hasn't run yet - not necessarily a change to sync back
    fi
done

echo ""

if [[ "$CHANGES_FOUND" == "false" ]]; then
    echo "No changes detected. Git and ConfigHub are in sync."
    exit 0
fi

echo "Changes detected between ConfigHub and Git."

if [[ "$DRY_RUN" == "true" ]]; then
    echo ""
    echo "Dry run complete. No PR created."
    echo ""
    echo "Summary of changes:"
    echo -e "$CHANGE_SUMMARY"
    exit 0
fi

# Create PR with ConfigHub state
echo ""
echo "Creating PR to sync ConfigHub state to Git..."

# Create a new branch
BRANCH_NAME="sync/confighub-to-git-$(date +%Y%m%d-%H%M%S)"
cd "$REPO_ROOT"

# Check if working directory is clean
if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "Error: Git working directory is not clean. Commit or stash changes first."
    exit 1
fi

git checkout -b "$BRANCH_NAME"

# Create the sync directory and copy ConfigHub exports
mkdir -p "$REPO_ROOT/$SYNC_DIR/$ENV"
cp "$WORK_DIR/confighub/"*.yaml "$REPO_ROOT/$SYNC_DIR/$ENV/" 2>/dev/null || true

# Also update the sync metadata
cat > "$REPO_ROOT/$SYNC_DIR/$ENV/.sync-metadata.json" <<EOF
{
  "synced_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "confighub_space": "$SPACE",
  "environment": "$ENV",
  "source": "confighub"
}
EOF

# Commit changes
git add "$SYNC_DIR/$ENV/"
git commit -m "sync: Import ConfigHub state for $ENV environment

ConfigHub space: $SPACE
Synced at: $(date -u +%Y-%m-%dT%H:%M:%SZ)

This PR syncs configuration changes made in ConfigHub back to Git
for visibility and audit purposes.

Changes:
$(echo -e "$CHANGE_SUMMARY")

Per ADR-011: Bidirectional GitOps with ConfigHub as Authority"

# Push and create PR
git push -u origin "$BRANCH_NAME"

gh pr create \
    --title "sync: Import ConfigHub state for $ENV" \
    --body "## Summary

This PR syncs configuration changes from ConfigHub back to Git.

**ConfigHub Space:** \`$SPACE\`
**Environment:** \`$ENV\`
**Synced at:** $(date -u +%Y-%m-%dT%H:%M:%SZ)

## Changes

$(echo -e "$CHANGE_SUMMARY")

## Why This Matters

Per [ADR-011](docs/decisions/011-ci-confighub-authority-conflict.md), ConfigHub is the authoritative source for configuration. This sync ensures:

- Git stays informed of all changes (bulk operations, policy adjustments, break-glass)
- Full history in Git for compliance/audit
- Developers see what operators changed
- Next CI run won't have stale data

## Review Guidelines

- Review the changes to understand what was modified in ConfigHub
- Merge to acknowledge the sync and update Git's view
- If changes should be reverted, use ConfigHub to roll back first

---
*Generated by sync-confighub-to-git.sh*" \
    --label "sync,confighub"

echo ""
echo "PR created successfully!"
echo "Branch: $BRANCH_NAME"

# Return to original branch
git checkout -
