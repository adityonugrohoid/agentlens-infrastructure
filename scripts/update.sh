#!/bin/bash
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

# Get public IP from terraform state
PUBLIC_IP=$(cd "$REPO_DIR/terraform" && terraform output -raw public_ip 2>/dev/null)
if [ -z "$PUBLIC_IP" ]; then
    echo -e "${RED}Error: Could not get public IP from terraform output${NC}"
    exit 1
fi

SSH="ssh -o StrictHostKeyChecking=no -i ~/.ssh/id_ed25519 ubuntu@$PUBLIC_IP"
APP="${1:-all}"

usage() {
    echo "Usage: $0 [all|agentlens|portfolio|deploy|images]"
    echo ""
    echo "  all       - Update all apps and deploy config"
    echo "  agentlens - Update agentlens only"
    echo "  portfolio - Update portfolio only"
    echo "  deploy    - Update deploy config only (compose, docker, nginx)"
    echo "  images    - Rebuild shared base images"
    exit 1
}

update_app() {
    local name="$1"
    local repo="$2"
    local compose_file="$3"

    echo -e "${YELLOW}Updating $name...${NC}"
    $SSH "cd ~/apps/$repo && git pull"
    $SSH "cd ~/deploy && docker compose -f compose/$compose_file --env-file .env up -d --build"
    echo -e "${GREEN}$name updated.${NC}"
}

update_deploy() {
    echo -e "${YELLOW}Updating deploy config...${NC}"
    $SSH "cd ~/deploy && git pull"
    $SSH "docker exec nginx nginx -s reload 2>/dev/null" || true
    echo -e "${GREEN}Deploy config updated.${NC}"
}

rebuild_images() {
    echo -e "${YELLOW}Rebuilding shared base images...${NC}"
    $SSH "cd ~/deploy && docker build -f docker/Dockerfile.base -t shared-base:latest docker/"
    $SSH "cd ~/deploy && docker build -f docker/Dockerfile.ml -t shared-ml:latest docker/"
    echo -e "${GREEN}Base images rebuilt.${NC}"
}

case "$APP" in
    agentlens)
        update_app "agentlens" "agentlens" "agentlens.yaml"
        ;;
    portfolio)
        update_app "portfolio" "portfolio" "portfolio.yaml"
        ;;
    deploy)
        update_deploy
        ;;
    images)
        rebuild_images
        ;;
    all)
        update_deploy
        update_app "agentlens" "agentlens" "agentlens.yaml"
        update_app "portfolio" "portfolio" "portfolio.yaml"
        ;;
    *)
        usage
        ;;
esac

echo -e "\n${GREEN}Update complete.${NC}"
$SSH "docker ps --format 'table {{.Names}}\t{{.Status}}'"
