# Design Decisions

Each decision below uses the format: **Context → Choice → Rationale → Tradeoffs**.

---

## Single EC2 instance instead of ECS, EKS, or Fargate

**Context:** AgentLens is a portfolio/demo application. It runs 7 containers, has modest traffic, and all LLM inference is offloaded to the Ollama Cloud API. The primary audience is interviewers and evaluators, not production users.

**Choice:** Single t3.small EC2 instance with Docker Compose.

**Rationale:** The workload does not justify the operational overhead of a container orchestrator. ECS Fargate removes the need to manage EC2 but adds task definitions, ECR, service discovery via AWS Cloud Map or an ALB, and IAM complexity that multiplies the time-to-first-deploy significantly. EKS adds more still. For a demo deployment that needs to be up, observable, and easy to tear down and recreate, a single instance with Docker Compose is the shortest path from code to running service.

**Tradeoffs:**
- No automatic container restarts across instance reboots → mitigated by the `portfolio.service` systemd unit with `RemainAfterExit=yes` and `WantedBy=multi-user.target`.
- No automatic horizontal scaling → not a requirement. Vertical scaling (upgrading the instance type) is a one-line change in `terraform.tfvars`.
- No rolling deploys → `./scripts/update.sh` causes a brief restart of the affected compose stack. Acceptable for a demo.
- Single point of failure → acceptable for this use case. A portfolio site going down briefly is not a business incident.

---

## Docker Compose instead of Kubernetes

**Context:** 7 containers, all on the same host, with simple service-to-service HTTP communication via Docker DNS.

**Choice:** Docker Compose plugin (built into Docker CE).

**Rationale:** Docker Compose is the right tool for this scale. The services communicate by container name over a user-defined bridge network. There is no need for service meshes, ingress controllers, persistent volume claims, or replica sets. Compose files are readable at a glance and the entire stack starts with a single command. Kubernetes would require either a managed cluster (cost) or a self-managed cluster (operational burden) and would buy nothing for a single-host 7-container deployment.

**Tradeoffs:**
- Compose does not schedule across multiple hosts → not needed. If the workload ever requires horizontal scaling, migrating to ECS or EKS is straightforward because each service is already containerized with a clean environment interface.
- No built-in health-check-driven restart logic at the orchestrator level → mitigated by `restart: unless-stopped` on every service and the systemd unit managing the overall lifecycle.

---

## Cloudflare instead of CloudFront or ALB

**Context:** Need SSL termination, DNS management, and DDoS protection for a single domain. The backend is a single EC2 instance.

**Choice:** Cloudflare Free tier — DNS, SSL/TLS edge termination, CDN, and DDoS protection.

**Rationale:** Cloudflare handles DNS, issues origin certificates for the EC2↔Cloudflare leg, terminates browser-facing TLS at its edge, and provides CDN caching for static assets — all at zero marginal cost. An ALB would cost ~$16/month (minimum) before any requests, and does not include DNS or DDoS protection. CloudFront requires configuring an S3 origin or custom origin with manual certificate management via ACM, plus Route 53 (~$0.50/month per hosted zone). For a single-instance deployment where the EC2 is the entire backend, Cloudflare is operationally simpler and cheaper.

**Tradeoffs:**
- SSL termination happens at Cloudflare's edge, not on the ALB → the EC2↔Cloudflare connection is protected by a Cloudflare origin certificate, not a public CA cert. This is a standard Cloudflare pattern (Full SSL mode) and is secure.
- No native AWS health check integration → Cloudflare will serve cached responses during brief EC2 restarts, which is acceptable for this use case.
- Vendor dependency on Cloudflare → acceptable. Migrating DNS away from Cloudflare is a ~15-minute operation.

---

## Terraform instead of CloudFormation or CDK

**Context:** Need to provision a VPC, subnet, security group, EC2 instance, EIP, and key pair. The deployment target is AWS only.

**Choice:** Terraform with the hashicorp/aws provider.

**Rationale:** Terraform's declarative HCL is readable and the plan/apply cycle makes the diff explicit before any change is applied. The `terraform output` command makes it easy to script post-provisioning steps (SSH, SCP) by reading the public IP. CloudFormation uses verbose JSON/YAML and requires navigating the AWS console or CLI to see outputs. CDK (TypeScript or Python) adds a compilation step and is better suited for teams that want to share infrastructure as library code — overkill for a single-developer deployment of this size. The Terraform state file (`terraform.tfstate`) is kept local and excluded from the repo.

**Tradeoffs:**
- No remote state backend → acceptable for a personal deployment. If multiple people needed to run `terraform apply`, the state file would need to move to S3 + DynamoDB locking.
- Terraform is not native to AWS → requires installing a separate binary. CloudFormation is zero-install from the AWS CLI. This is a non-issue in practice.

---

## Shared Docker base images (`shared-base` and `shared-ml`)

**Context:** Five Python services across two compose stacks all need the same core dependencies. The ML embedding model (all-MiniLM-L6-v2) is ~400 MB and slow to download.

**Choice:** Two shared base images built once on the EC2 before any service images are built.

**Rationale:** Without shared bases, each of the five service images would independently install FastAPI, chromadb, tiktoken, and rank-bm25. That is 5× the download time and 5× the disk space. With `shared-base:latest` and `shared-ml:latest` built once, service images layer on top and are small. The ML image pre-caches the embedding model at build time (`python -c "SentenceTransformer('all-MiniLM-L6-v2')"`) so the container starts instantly with the model already in the image layer.

**Tradeoffs:**
- Any change to the base dependencies requires rebuilding all service images (`./scripts/update.sh images`). This is an intentional manual step rather than an automatic dependency.
- The ML image is ~2.5 GB — significant disk usage on a 30 GB volume. Acceptable given the full stack uses ~15 GB.

---

## Parametrized Dockerfile for service images

**Context:** Four backend services share identical structure: copy shared code, copy service-specific code, run uvicorn.

**Choice:** A single `Dockerfile.svc` that accepts a `SERVICE` build arg to select which service directory to copy.

**Rationale:** A single Dockerfile is easier to maintain than four near-identical Dockerfiles. The `SERVICE` build arg is passed in `compose/agentlens.yaml` for each service. The gateway uses a separate `Dockerfile.gateway` (same pattern but also copies `.html` files for the debugger UI).

**Tradeoffs:**
- Slightly less explicit than one Dockerfile per service — the build context and the SERVICE arg must match. In practice this is not a problem because the compose file is the single source of truth for which service maps to which Dockerfile arg.

---

## nginx as a Docker container rather than the host nginx

**Context:** The EC2 instance runs Ubuntu, which can install nginx as a system package. Alternatively, nginx can run as a Docker container alongside the other services.

**Choice:** Docker container (`nginx:alpine`), host nginx removed.

**Rationale:** Running nginx inside Docker keeps all seven services on the same Docker network, allowing nginx to resolve container names via Docker's embedded DNS (`127.0.0.11`). This is why the nginx config uses `resolver 127.0.0.11 valid=30s` and sets upstream addresses via variables (`set $upstream_gw lens-gateway`) — required for Docker DNS-based upstream resolution in nginx. If nginx were a host process, it would need to use `127.0.0.1` and the container port mapping, which is less clean and requires exposing service ports to the host. The `user-data.sh` bootstrap explicitly removes host nginx (`apt-get remove nginx`) to prevent port conflicts on first boot.

**Tradeoffs:**
- The docker socket is not mounted into the nginx container — nginx has no awareness of the Docker daemon. It reaches upstreams purely by container name.
- Updating nginx config requires `docker exec nginx nginx -s reload` rather than `systemctl reload nginx`. This is scripted in `update.sh`.
