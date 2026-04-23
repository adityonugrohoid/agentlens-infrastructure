#!/bin/bash
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

echo -e "${RED}GenAI Portfolio - Teardown${NC}"
echo "=========================="

echo -e "\n${RED}WARNING: This will destroy all infrastructure!${NC}"
echo -e "Type 'destroy' to continue:"
read -r CONFIRM

if [ "$CONFIRM" != "destroy" ]; then
    echo "Teardown cancelled"
    exit 0
fi

# Stop services on EC2 first (best-effort)
echo -e "\n${YELLOW}Attempting to stop services on EC2...${NC}"
cd "$REPO_DIR/terraform"
PUBLIC_IP=$(terraform output -raw public_ip 2>/dev/null || echo "")

if [ -n "$PUBLIC_IP" ]; then
    ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -i ~/.ssh/id_ed25519 ubuntu@$PUBLIC_IP \
        'cd ~/deploy && docker compose -f compose/agentlens.yaml down; docker compose -f compose/portfolio.yaml down; docker compose -f compose/shared.yaml down' 2>/dev/null || true
fi

# Destroy infrastructure
echo -e "\n${YELLOW}Destroying infrastructure...${NC}"
terraform destroy

echo -e "\n${GREEN}Infrastructure destroyed.${NC}"
echo "Resources removed: EC2 instance, EBS volume, Elastic IP, security group, subnet, VPC."
