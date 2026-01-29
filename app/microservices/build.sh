#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_NAME="messagewall-microservice"
TAG="${1:-latest}"

echo "Building microservice image: ${IMAGE_NAME}:${TAG}"

docker build -t "${IMAGE_NAME}:${TAG}" "${SCRIPT_DIR}"

echo ""
echo "Built: ${IMAGE_NAME}:${TAG}"
echo ""
echo "To load into kind clusters:"
echo "  kind load docker-image ${IMAGE_NAME}:${TAG} --name actuator"
echo "  kind load docker-image ${IMAGE_NAME}:${TAG} --name workload"
echo ""
echo "Or push to a registry:"
echo "  docker tag ${IMAGE_NAME}:${TAG} your-registry/${IMAGE_NAME}:${TAG}"
echo "  docker push your-registry/${IMAGE_NAME}:${TAG}"
