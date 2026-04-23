#!/bin/bash
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

echo -e "${GREEN}GenAI Portfolio - Multi-App Deployment${NC}"
echo "========================================"

# Check prerequisites
echo -e "\n${YELLOW}Checking prerequisites...${NC}"

for cmd in terraform aws ssh scp; do
    if ! command -v $cmd &>/dev/null; then
        echo -e "${RED}Error: $cmd is not installed${NC}"
        exit 1
    fi
done

if [ ! -f "$REPO_DIR/terraform/terraform.tfvars" ]; then
    echo -e "${RED}Error: terraform/terraform.tfvars not found${NC}"
    echo "Copy terraform/terraform.tfvars.example to terraform/terraform.tfvars and configure it"
    exit 1
fi

# Terraform init + plan + apply
echo -e "\n${YELLOW}Initializing Terraform...${NC}"
cd "$REPO_DIR/terraform"
terraform init

echo -e "\n${YELLOW}Planning deployment...${NC}"
terraform plan -out=tfplan

echo -e "\n${YELLOW}Ready to deploy. Continue? (yes/no)${NC}"
read -r CONFIRM
if [ "$CONFIRM" != "yes" ]; then
    echo "Deployment cancelled"
    rm -f tfplan
    exit 0
fi

echo -e "\n${YELLOW}Deploying infrastructure...${NC}"
terraform apply tfplan
rm -f tfplan

# Get outputs
PUBLIC_IP=$(terraform output -raw public_ip)
SSH_CMD="ssh -i ~/.ssh/id_ed25519 ubuntu@$PUBLIC_IP"

echo -e "\n${GREEN}Infrastructure deployed!${NC}"
echo -e "Public IP: ${GREEN}$PUBLIC_IP${NC}"

# Wait for instance to be reachable
echo -e "\n${YELLOW}Waiting for instance to be ready...${NC}"
for i in $(seq 1 30); do
    if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -i ~/.ssh/id_ed25519 ubuntu@$PUBLIC_IP "echo ready" 2>/dev/null; then
        echo -e "${GREEN}Instance is ready.${NC}"
        break
    fi
    echo "Attempt $i/30 - waiting 10s..."
    sleep 10
done

# Upload SSL certs (Cloudflare origin certs — must exist locally before deploy)
echo -e "\n${YELLOW}Uploading SSL certificates...${NC}"
scp -o StrictHostKeyChecking=no -i ~/.ssh/id_ed25519 \
    /etc/ssl/cloudflare/example.com.pem \
    /etc/ssl/cloudflare/example.com.key \
    ubuntu@$PUBLIC_IP:/tmp/

ssh -o StrictHostKeyChecking=no -i ~/.ssh/id_ed25519 ubuntu@$PUBLIC_IP <<'ENDSSH'
sudo mkdir -p /etc/ssl/cloudflare
sudo mv /tmp/example.com.pem /etc/ssl/cloudflare/
sudo mv /tmp/example.com.key /etc/ssl/cloudflare/
sudo chmod 600 /etc/ssl/cloudflare/*
ENDSSH

# Build images and start services
echo -e "\n${YELLOW}Building images and starting services...${NC}"
ssh -o StrictHostKeyChecking=no -i ~/.ssh/id_ed25519 ubuntu@$PUBLIC_IP <<'ENDSSH'
cd ~/deploy

# Create Docker network
docker network inspect portfolio >/dev/null 2>&1 || docker network create portfolio

# Build shared base images
echo "Building shared-base image..."
docker build -f docker/Dockerfile.base -t shared-base:latest docker/

echo "Building shared-ml image..."
docker build -f docker/Dockerfile.ml -t shared-ml:latest docker/

# Start shared infrastructure
echo "Starting shared infrastructure..."
docker compose -f compose/shared.yaml --env-file .env up -d

# Wait for chromadb
echo "Waiting for ChromaDB..."
sleep 10

# Start app stacks
echo "Starting agentlens..."
docker compose -f compose/agentlens.yaml --env-file .env up -d --build

echo "Starting portfolio..."
docker compose -f compose/portfolio.yaml --env-file .env up -d --build

echo "All services started!"
docker ps --format "table {{.Names}}\t{{.Status}}"
ENDSSH

# Ingest sample documents via lens-gateway
echo -e "\n${YELLOW}Ingesting sample documents...${NC}"
ssh -o StrictHostKeyChecking=no -i ~/.ssh/id_ed25519 ubuntu@$PUBLIC_IP <<'ENDSSH'
echo "Waiting for lens-gateway to be ready..."
for i in $(seq 1 30); do
    if docker exec lens-gateway curl -sf http://localhost:8080/health >/dev/null 2>&1; then
        break
    fi
    sleep 5
done

docker exec lens-gateway curl -sf -X POST http://localhost:8080/documents/ingest-samples || echo "Ingestion may need manual trigger"
ENDSSH

echo -e "\n${GREEN}Deployment complete!${NC}"
echo -e "AgentLens: ${GREEN}https://agentlens.example.com${NC}"
echo -e "\nSSH: ${GREEN}$SSH_CMD${NC}"
