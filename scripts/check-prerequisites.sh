#!/bin/sh
# check-prerequisites.sh - Check that required tools are installed
# Part of EPIC-9: Setup wizard for new users
# POSIX sh for maximum portability

set -e

# Colors for output (if terminal supports it)
if [ -t 1 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    NC='\033[0m' # No Color
else
    RED=''
    GREEN=''
    YELLOW=''
    NC=''
fi

# Track overall status
ALL_PASSED=true

# Print a check result
print_check() {
    status=$1
    tool=$2
    version=$3

    if [ "$status" = "pass" ]; then
        printf "${GREEN}✓${NC} %s: %s\n" "$tool" "$version"
    else
        printf "${RED}✗${NC} %s: not installed\n" "$tool"
        ALL_PASSED=false
    fi
}

# Print installation suggestion
suggest_install() {
    tool=$1
    brew_cmd=$2
    apt_cmd=$3
    other=$4

    printf "  ${YELLOW}Install with:${NC}\n"
    if [ -n "$brew_cmd" ]; then
        printf "    macOS (Homebrew): %s\n" "$brew_cmd"
    fi
    if [ -n "$apt_cmd" ]; then
        printf "    Ubuntu/Debian:    %s\n" "$apt_cmd"
    fi
    if [ -n "$other" ]; then
        printf "    Other:            %s\n" "$other"
    fi
    printf "\n"
}

echo "Checking prerequisites for serverless-message-wall-demo..."
echo ""

# Check Docker
if command -v docker >/dev/null 2>&1; then
    docker_version=$(docker --version 2>/dev/null | sed 's/Docker version //' | cut -d',' -f1)
    print_check "pass" "docker" "$docker_version"

    # Also check if Docker daemon is running
    if ! docker info >/dev/null 2>&1; then
        printf "  ${YELLOW}Warning:${NC} Docker is installed but not running. Start Docker Desktop.\n\n"
    fi
else
    print_check "fail" "docker" ""
    suggest_install "docker" \
        "brew install --cask docker" \
        "sudo apt-get install docker.io" \
        "https://docs.docker.com/get-docker/"
fi

# Check kind
if command -v kind >/dev/null 2>&1; then
    kind_version=$(kind version 2>/dev/null | sed 's/kind //' | cut -d' ' -f1)
    print_check "pass" "kind" "$kind_version"
else
    print_check "fail" "kind" ""
    suggest_install "kind" \
        "brew install kind" \
        "go install sigs.k8s.io/kind@latest" \
        "https://kind.sigs.k8s.io/docs/user/quick-start/#installation"
fi

# Check kubectl
if command -v kubectl >/dev/null 2>&1; then
    kubectl_version=$(kubectl version --client -o json 2>/dev/null | grep gitVersion | head -1 | sed 's/.*"gitVersion": "//' | sed 's/".*//')
    if [ -z "$kubectl_version" ]; then
        kubectl_version=$(kubectl version --client 2>/dev/null | head -1 | sed 's/Client Version: //')
    fi
    print_check "pass" "kubectl" "$kubectl_version"
else
    print_check "fail" "kubectl" ""
    suggest_install "kubectl" \
        "brew install kubectl" \
        "sudo apt-get install -y kubectl" \
        "https://kubernetes.io/docs/tasks/tools/"
fi

# Check helm
if command -v helm >/dev/null 2>&1; then
    helm_version=$(helm version --short 2>/dev/null | cut -d'+' -f1)
    print_check "pass" "helm" "$helm_version"
else
    print_check "fail" "helm" ""
    suggest_install "helm" \
        "brew install helm" \
        "sudo snap install helm --classic" \
        "https://helm.sh/docs/intro/install/"
fi

# Check AWS CLI
if command -v aws >/dev/null 2>&1; then
    aws_version=$(aws --version 2>/dev/null | cut -d' ' -f1 | sed 's/aws-cli\///')
    print_check "pass" "aws" "$aws_version"
else
    print_check "fail" "aws" ""
    suggest_install "aws" \
        "brew install awscli" \
        "sudo apt-get install awscli" \
        "https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
fi

echo ""

# Final status
if [ "$ALL_PASSED" = "true" ]; then
    printf "${GREEN}All prerequisites are installed.${NC}\n"
    exit 0
else
    printf "${RED}Some prerequisites are missing.${NC} Please install them before continuing.\n"
    exit 1
fi
