#!/bin/bash
set -e

# Logging
exec > >(tee /var/log/user-data.log)
exec 2>&1

echo "=== GenAI Portfolio - Multi-App Deployment ==="
echo "Started at $(date)"

# System update
apt-get update
apt-get upgrade -y

# Install Docker
apt-get install -y ca-certificates curl gnupg
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  tee /etc/apt/sources.list.d/docker.list > /dev/null

apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Add ubuntu user to docker group
usermod -aG docker ubuntu

# Remove host nginx if installed (we use Docker nginx)
systemctl stop nginx 2>/dev/null || true
systemctl disable nginx 2>/dev/null || true
apt-get remove -y nginx nginx-common 2>/dev/null || true

# Create SSL directory for Cloudflare origin certs
mkdir -p /etc/ssl/cloudflare

# Add 6 GB swap (t3.small has 2 GB RAM; ML containers fill it quickly)
fallocate -l 1G /swapfile
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile
echo '/swapfile none swap sw 0 0' >> /etc/fstab

fallocate -l 2G /swapfile2
chmod 600 /swapfile2
mkswap /swapfile2
swapon /swapfile2
echo '/swapfile2 none swap sw 0 0' >> /etc/fstab

fallocate -l 3G /swapfile3
chmod 600 /swapfile3
mkswap /swapfile3
swapon /swapfile3
echo '/swapfile3 none swap sw 0 0' >> /etc/fstab

# Clone deployment repo
GITHUB_PAT="${github_pat}"
DEPLOY_DIR="/home/ubuntu/deploy"

sudo -u ubuntu git clone "https://$GITHUB_PAT@github.com/adityonugrohoid/rag-knowledge-assistant-aws.git" "$DEPLOY_DIR"

# Clone app repos
APPS_DIR="/home/ubuntu/apps"
mkdir -p "$APPS_DIR"
chown ubuntu:ubuntu "$APPS_DIR"

sudo -u ubuntu git clone "https://$GITHUB_PAT@github.com/adityonugrohoid/agentlens.git" "$APPS_DIR/agentlens"
sudo -u ubuntu git clone "https://$GITHUB_PAT@github.com/adityonugrohoid/portfolio.git" "$APPS_DIR/portfolio"

# Create .env file
cat > "$DEPLOY_DIR/.env" <<EOF
OLLAMA_HOST=https://api.ollama.com
OLLAMA_API_KEY=${ollama_api_key}
LLM_MODEL=gemini-3-flash-preview
LLM_MODEL_AGENT=devstral-small-2:24b
LLM_MODEL_GRADER=nemotron-3-nano:30b
LLM_MODEL_JUDGE=gpt-oss:120b
LLM_MODEL_FALLBACK=gemini-3-flash-preview
LLM_THINK=true
EOF

chown ubuntu:ubuntu "$DEPLOY_DIR/.env"
chmod 600 "$DEPLOY_DIR/.env"

# Create startup script
cat > /home/ubuntu/start-portfolio.sh <<'SCRIPT'
#!/bin/bash
set -e

DEPLOY_DIR="/home/ubuntu/deploy"
cd "$DEPLOY_DIR"

# Create Docker network if missing
docker network inspect portfolio >/dev/null 2>&1 || docker network create portfolio

# Build shared base images if missing
if ! docker image inspect shared-base:latest >/dev/null 2>&1; then
    echo "Building shared-base image..."
    docker build -f docker/Dockerfile.base -t shared-base:latest docker/
fi

if ! docker image inspect shared-ml:latest >/dev/null 2>&1; then
    echo "Building shared-ml image..."
    docker build -f docker/Dockerfile.ml -t shared-ml:latest docker/
fi

# Start shared infrastructure (chromadb + nginx)
docker compose -f compose/shared.yaml --env-file .env up -d

# Start all app stacks
docker compose -f compose/agentlens.yaml --env-file .env up -d --build
docker compose -f compose/portfolio.yaml --env-file .env up -d --build

echo "All services started."
SCRIPT
chown ubuntu:ubuntu /home/ubuntu/start-portfolio.sh
chmod +x /home/ubuntu/start-portfolio.sh

# Create systemd service for auto-start
cat > /etc/systemd/system/portfolio.service <<'EOF'
[Unit]
Description=GenAI Portfolio Suite
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/home/ubuntu/deploy
User=ubuntu
Group=ubuntu
ExecStart=/home/ubuntu/start-portfolio.sh
ExecStop=/bin/bash -c "cd /home/ubuntu/deploy && docker compose -f compose/portfolio.yaml down; docker compose -f compose/agentlens.yaml down; docker compose -f compose/shared.yaml down"

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable portfolio.service

echo "=== Deployment complete ==="
echo "SSL certs must be uploaded to /etc/ssl/cloudflare/ before starting services."
echo "Then run: sudo systemctl start portfolio"
