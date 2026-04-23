# Deployment Runbook

## Prerequisites

| Requirement | Notes |
|-------------|-------|
| AWS account | IAM user with VPC, EC2, EIP permissions |
| AWS CLI | Configured with `aws configure` or environment variables |
| Terraform >= 1.0 | `terraform version` to verify |
| SSH key pair | ED25519 recommended: `ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519` |
| Ollama Cloud API key | Sign up at [ollama.com](https://ollama.com) |
| GitHub fine-grained PAT | Read-only access to the agentlens and portfolio repos |
| Cloudflare origin certificate | Issued from Cloudflare dashboard → SSL/TLS → Origin Server |
| Domain with Cloudflare DNS | An A record pointing your subdomain to the Elastic IP |

---

## Step 1 — Configure

```bash
# Clone this repo
git clone https://github.com/adityonugrohoid/agentlens-infrastructure.git
cd agentlens-infrastructure

# Terraform variables
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
# Edit terraform.tfvars:
#   aws_region      = "us-east-1"
#   instance_type   = "t3.small"
#   ollama_api_key  = "your_key_here"
#   github_pat      = "github_pat_xxxx"
#   allowed_ssh_cidr = ["your.ip.address/32"]  # restrict in production
```

---

## Step 2 — Provision infrastructure

```bash
cd terraform
terraform init
terraform plan
```

Review the plan. Expected resources:
- `aws_vpc.main`
- `aws_internet_gateway.main`
- `aws_subnet.public`
- `aws_route_table.public` + `aws_route_table_association.public`
- `aws_security_group.app`
- `aws_key_pair.deployer`
- `aws_instance.app`
- `aws_eip.app`

```bash
terraform apply
```

Expected outputs after apply:

```
instance_id     = "i-0..."
public_ip       = "x.x.x.x"
ssh_command     = "ssh -i ~/.ssh/id_ed25519 ubuntu@x.x.x.x"
agentlens_url   = "https://agentlens.example.com"
security_group_id = "sg-0..."
```

The EC2 instance runs `user-data.sh` on first boot. This takes 3–5 minutes and installs Docker, creates swap, clones repos, and configures the systemd service.

---

## Step 3 — Upload Cloudflare origin certificate

Before starting services, nginx needs the origin certificate:

```bash
# From your local machine (cert must exist at this path)
scp -i ~/.ssh/id_ed25519 \
    /path/to/example.com.pem \
    /path/to/example.com.key \
    ubuntu@<PUBLIC_IP>:/tmp/

ssh -i ~/.ssh/id_ed25519 ubuntu@<PUBLIC_IP>
sudo mkdir -p /etc/ssl/cloudflare
sudo mv /tmp/example.com.pem /etc/ssl/cloudflare/
sudo mv /tmp/example.com.key /etc/ssl/cloudflare/
sudo chmod 600 /etc/ssl/cloudflare/*
```

Alternatively, run the full automated deploy:

```bash
./scripts/deploy.sh
```

`deploy.sh` runs terraform, waits for SSH readiness, uploads certs, builds images, and starts all services.

---

## Step 4 — DNS

In Cloudflare:
1. Add an A record: `agentlens.yourdomain.com` → `<ELASTIC_IP>`, proxied (orange cloud).
2. SSL/TLS → Full (strict) mode.
3. No additional Page Rules needed.

---

## Step 5 — Start services

If you ran `deploy.sh`, services are already running. To start manually:

```bash
ssh -i ~/.ssh/id_ed25519 ubuntu@<PUBLIC_IP>
sudo systemctl start portfolio
```

The systemd unit runs `start-portfolio.sh` which:
1. Creates the `portfolio` Docker bridge network if missing.
2. Builds `shared-base:latest` and `shared-ml:latest` if not already built.
3. Starts `compose/shared.yaml` (chromadb + nginx).
4. Starts `compose/agentlens.yaml` (4 AgentLens services).
5. Starts `compose/portfolio.yaml` (portfolio UI).

Expected state after start:

```bash
docker ps --format "table {{.Names}}\t{{.Status}}"
# NAMES             STATUS
# lens-gateway      Up X minutes
# lens-query        Up X minutes
# lens-retrieval    Up X minutes
# lens-ingestion    Up X minutes
# portfolio-ui      Up X minutes
# chromadb          Up X minutes
# nginx             Up X minutes
```

---

## Step 6 — Verify

```bash
# Health check (should return {"status":"healthy",...})
curl https://agentlens.yourdomain.com/health

# Ingest sample documents (12 docs, 6 categories)
curl -X POST https://agentlens.yourdomain.com/documents/ingest-samples

# Open the pipeline debugger
open https://agentlens.yourdomain.com/console
```

---

## Updating

```bash
# Update agentlens app (git pull + rebuild)
./scripts/update.sh agentlens

# Update portfolio UI
./scripts/update.sh portfolio

# Reload nginx config
./scripts/update.sh deploy

# Rebuild shared base images (after dependency changes)
./scripts/update.sh images

# Update everything
./scripts/update.sh all
```

Each update SSHs into the EC2, pulls the latest code, and runs `docker compose up -d --build` for the affected stack.

---

## Teardown

```bash
./scripts/teardown.sh
# Type: destroy
```

This stops all Docker services via SSH, then runs `terraform destroy`.

Resources removed: EC2 instance, EBS volume, Elastic IP, security group, subnet, route table, internet gateway, VPC, key pair.

The Cloudflare DNS record, the Ollama API key, and the GitHub PAT are not managed by Terraform and must be cleaned up manually.

---

## Troubleshooting

**Services not starting after deploy:**
```bash
# Check user-data execution
sudo cat /var/log/user-data.log

# Check systemd service status
sudo systemctl status portfolio

# Check individual container logs
docker logs lens-gateway
docker logs nginx
```

**nginx 502 Bad Gateway:**
- A service container may still be starting. Wait 30s and retry.
- Check `docker ps` to confirm all 7 containers are running.
- Check `docker logs lens-gateway` for upstream errors.

**ChromaDB not persisting data across restarts:**
- The `chromadb_data` Docker volume persists the index. Verify with `docker volume ls`.
- If the volume is missing, the data was lost (e.g., `docker compose down -v` was used). Re-ingest.

**OOM / containers killed:**
- t3.small has 2 GB RAM + 6 GB swap. The ML model build is the peak memory event (~2.5 GB).
- Check `free -h` and `dmesg | grep -i oom` on the instance.
- If the base images are not built, `shared-ml:latest` build will be the first OOM risk. Ensure swap is active: `swapon --show`.
