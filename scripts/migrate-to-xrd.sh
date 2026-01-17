#!/bin/bash
# Migrate from raw managed resources to ServerlessEventApp XRD
#
# This script:
#   1. Backs up existing managed resources
#   2. Deletes existing raw managed resources
#   3. Applies the new Claim
#   4. Verifies recreation
#
# IMPORTANT: This script deletes AWS resources! The Claim will recreate them,
# but there may be brief downtime during migration.
#
# Prerequisites:
#   - XRD and Composition installed (run install-xrd.sh first)
#   - kubectl configured with access to the actuator cluster
#
# Usage:
#   ./scripts/migrate-to-xrd.sh [--dry-run]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Parse arguments
DRY_RUN=false
if [[ "${1:-}" == "--dry-run" ]]; then
    DRY_RUN=true
    echo "==> DRY RUN MODE - no changes will be made"
fi

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
RESOURCE_PREFIX="messagewall"
ENVIRONMENT="dev"
BACKUP_DIR="$PROJECT_ROOT/migration-backup-$(date +%Y%m%d-%H%M%S)"

echo "================================================"
echo "Migrate to ServerlessEventApp XRD"
echo "================================================"
echo ""
echo "Resource prefix: $RESOURCE_PREFIX"
echo "Environment:     $ENVIRONMENT"
echo "Backup dir:      $BACKUP_DIR"
echo ""

# ============================================================
# STEP 1: Pre-flight checks
# ============================================================
echo "==> Running pre-flight checks..."

# Check if XRD is installed
if ! kubectl get xrd serverlesseventapps.messagewall.demo &>/dev/null; then
    echo -e "${RED}ERROR${NC}: XRD not installed. Run install-xrd.sh first."
    exit 1
fi
echo -e "${GREEN}OK${NC}: XRD is installed"

# Check if Composition is installed
if ! kubectl get composition serverlesseventapp-aws &>/dev/null; then
    echo -e "${RED}ERROR${NC}: Composition not installed. Run install-xrd.sh first."
    exit 1
fi
echo -e "${GREEN}OK${NC}: Composition is installed"

# Check if there are existing managed resources
EXISTING_RESOURCES=$(kubectl get managed -l app.kubernetes.io/name=$RESOURCE_PREFIX 2>/dev/null | tail -n +2 || echo "")
if [ -z "$EXISTING_RESOURCES" ]; then
    echo -e "${YELLOW}NOTE${NC}: No existing managed resources with label app.kubernetes.io/name=$RESOURCE_PREFIX"
    echo "Looking for resources by name pattern..."
    EXISTING_RESOURCES=$(kubectl get managed 2>/dev/null | grep "$RESOURCE_PREFIX" || echo "")
fi

if [ -z "$EXISTING_RESOURCES" ]; then
    echo -e "${YELLOW}NOTE${NC}: No existing managed resources found. Skipping migration, applying Claim directly."
    if [ "$DRY_RUN" = true ]; then
        echo "[DRY RUN] Would apply: examples/claims/messagewall-dev.yaml"
    else
        kubectl apply -f "$PROJECT_ROOT/examples/claims/messagewall-dev.yaml"
        echo -e "${GREEN}OK${NC}: Claim applied successfully"
    fi
    exit 0
fi

echo "Found existing resources:"
echo "$EXISTING_RESOURCES" | head -20
echo ""

# ============================================================
# STEP 2: Create backup
# ============================================================
echo "==> Creating backup..."

if [ "$DRY_RUN" = true ]; then
    echo "[DRY RUN] Would create backup at: $BACKUP_DIR"
else
    mkdir -p "$BACKUP_DIR"

    # Export all managed resources with the prefix
    kubectl get managed -o yaml 2>/dev/null | grep -A 1000 "$RESOURCE_PREFIX" > "$BACKUP_DIR/managed-resources.yaml" || true

    # Export individual resources by type
    for resource_type in buckets.s3 tables.dynamodb functions.lambda roles.iam rolepolicies.iam functionurls.lambda rules.cloudwatchevents targets.cloudwatchevents permissions.lambda bucketownershipcontrols.s3 bucketpublicaccessblocks.s3 bucketwebsiteconfigurations.s3 bucketcorsconfigurations.s3 bucketpolicies.s3; do
        kubectl get "$resource_type" -o yaml 2>/dev/null | grep -B 100 -A 100 "$RESOURCE_PREFIX" > "$BACKUP_DIR/$resource_type.yaml" 2>/dev/null || true
    done

    echo -e "${GREEN}OK${NC}: Backup created at $BACKUP_DIR"
fi

# ============================================================
# STEP 3: Confirmation
# ============================================================
if [ "$DRY_RUN" = false ]; then
    echo ""
    echo -e "${YELLOW}WARNING${NC}: This will delete the following resources and recreate them via the XRD Claim."
    echo "There may be brief downtime during migration."
    echo ""
    echo "Resources to delete:"
    echo "$EXISTING_RESOURCES" | head -20
    echo ""
    read -p "Continue with migration? (yes/no): " confirm
    if [ "$confirm" != "yes" ]; then
        echo "Migration cancelled."
        exit 0
    fi
fi

# ============================================================
# STEP 4: Delete existing resources
# ============================================================
echo ""
echo "==> Deleting existing managed resources..."

# List of resource types to delete (in reverse dependency order)
RESOURCE_TYPES=(
    "permissions.lambda"
    "targets.cloudwatchevents"
    "rules.cloudwatchevents"
    "functionurls.lambda"
    "functions.lambda"
    "rolepolicies.iam"
    "roles.iam"
    "bucketpolicies.s3"
    "bucketcorsconfigurations.s3"
    "bucketwebsiteconfigurations.s3"
    "bucketpublicaccessblocks.s3"
    "bucketownershipcontrols.s3"
    "buckets.s3"
    "tables.dynamodb"
)

for resource_type in "${RESOURCE_TYPES[@]}"; do
    resources=$(kubectl get "$resource_type" 2>/dev/null | grep "$RESOURCE_PREFIX" | awk '{print $1}' || echo "")
    if [ -n "$resources" ]; then
        for resource in $resources; do
            if [ "$DRY_RUN" = true ]; then
                echo "[DRY RUN] Would delete: $resource_type/$resource"
            else
                echo "Deleting $resource_type/$resource..."
                kubectl delete "$resource_type" "$resource" --wait=false 2>/dev/null || true
            fi
        done
    fi
done

if [ "$DRY_RUN" = false ]; then
    echo ""
    echo "Waiting for resources to be deleted..."
    sleep 10
fi

# ============================================================
# STEP 5: Apply Claim
# ============================================================
echo ""
echo "==> Applying ServerlessEventApp Claim..."

if [ "$DRY_RUN" = true ]; then
    echo "[DRY RUN] Would apply: examples/claims/messagewall-dev.yaml"
else
    kubectl apply -f "$PROJECT_ROOT/examples/claims/messagewall-dev.yaml"
    echo -e "${GREEN}OK${NC}: Claim applied"
fi

# ============================================================
# STEP 6: Verify recreation
# ============================================================
echo ""
echo "==> Verifying resource recreation..."

if [ "$DRY_RUN" = true ]; then
    echo "[DRY RUN] Would verify resources are created"
else
    # Wait for Claim to be ready
    echo "Waiting for Claim to be ready (this may take a few minutes)..."

    for i in {1..60}; do
        status=$(kubectl get serverlesseventappclaim messagewall-dev -n default -o jsonpath='{.status.ready}' 2>/dev/null || echo "")
        if [ "$status" = "true" ]; then
            echo -e "${GREEN}OK${NC}: Claim is ready"
            break
        fi
        echo "  Waiting... ($i/60)"
        sleep 5
    done

    # Show managed resources
    echo ""
    echo "Managed resources created:"
    kubectl get managed -l crossplane.io/claim-name=messagewall-dev 2>/dev/null || echo "No resources found yet"

    # Show Claim status
    echo ""
    echo "Claim status:"
    kubectl get serverlesseventappclaim messagewall-dev -n default -o yaml | grep -A 10 "status:" || true
fi

# ============================================================
# DONE
# ============================================================
echo ""
echo "================================================"
echo "Migration Complete"
echo "================================================"
echo ""
if [ "$DRY_RUN" = true ]; then
    echo "This was a dry run. No changes were made."
    echo "Run without --dry-run to perform the migration."
else
    echo "Backup saved to: $BACKUP_DIR"
    echo ""
    echo "Verify the migration:"
    echo "  kubectl get serverlesseventappclaim messagewall-dev -n default"
    echo "  kubectl get managed -l crossplane.io/claim-name=messagewall-dev"
    echo ""
    echo "Run smoke tests:"
    echo "  ./scripts/test-xrd.sh smoke"
fi
