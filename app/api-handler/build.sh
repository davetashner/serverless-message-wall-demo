#!/bin/bash
# Build script for api-handler Lambda
# Produces api-handler.zip for deployment

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${SCRIPT_DIR}/build"
ZIP_FILE="${SCRIPT_DIR}/api-handler.zip"

echo "Building api-handler Lambda..."

# Clean previous build
rm -rf "${BUILD_DIR}" "${ZIP_FILE}"
mkdir -p "${BUILD_DIR}"

# Copy handler
cp "${SCRIPT_DIR}/handler.py" "${BUILD_DIR}/"

# Create zip (boto3 is included in Lambda runtime)
# Use subshell to avoid changing caller's working directory
(cd "${BUILD_DIR}" && zip -r "${ZIP_FILE}" .)

# Cleanup
rm -rf "${BUILD_DIR}"

echo "Created: ${ZIP_FILE}"
echo "Size: $(du -h "${ZIP_FILE}" | cut -f1)"
