# AgentLens — AWS Infrastructure

AgentLens is a streaming pipeline debugger for multi-agent RAG systems. It coordinates four autonomous agents — Retrieval Agent, Grader, Quality Judge, and Fallback — across a 4-service FastAPI microservice architecture, deployed to production on AWS. This repository contains the infrastructure-as-code and deployment configuration. Application code is private.

**Live demo:** [agentlens.adityonugroho.com](https://agentlens.adityonugroho.com)

---

## What this repo is

This repo documents the AWS deployment of AgentLens: Terraform configuration, Docker Compose stacks, nginx virtual host, and deployment scripts. It does not contain application source code. A hiring manager or infrastructure reviewer can use this repo to verify the deployment architecture without access to the application repos.

---

## Architecture

```
User Browser
     │ HTTPS
     ▼
Cloudflare  (DNS · SSL/TLS edge · CDN)
     │ HTTPS (Cloudflare origin cert)
     ▼
┌─────────────────────────────────────────────────────────┐
│  AWS EC2  t3.small · us-east-1 · Ubuntu 22.04 LTS       │
│                                                         │
│  nginx :80/:443  (Docker container)                     │
│    ├── /console /query /documents /health               │
│    │       └── lens-gateway :8080                       │
│    │             ├── lens-ingestion  :8001              │
│    │             ├── lens-retrieval  :8002  ──────────► Ollama Cloud API
│    │             └── lens-query      :8003              │  (api.ollama.com)
│    │                      └── ChromaDB :8000 (shared)   │
│    └── / (catch-all)                                    │
│             └── portfolio-ui :3000 (Next.js)            │
│                                                         │
│  7 containers · Docker bridge network (portfolio)       │
│  6 GB swap · systemd auto-start · 30 GB gp3 EBS        │
└─────────────────────────────────────────────────────────┘
```

See [ARCHITECTURE.md](ARCHITECTURE.md) for the full traffic path, component breakdown, and data flow.

The topology diagram is at [diagrams/architecture.svg](diagrams/architecture.svg).

---

## Tech stack

| Layer | Technology |
|-------|------------|
| Cloud | AWS EC2 (t3.small), Elastic IP, VPC, security groups |
| IaC | Terraform (hashicorp/aws ~> 5.0) |
| Containers | Docker, Docker Compose plugin |
| Orchestration | 7-container stack on a user-defined Docker bridge network |
| Reverse proxy | nginx (Alpine Docker image) |
| DNS + SSL | Cloudflare — edge SSL termination, origin certificates on nginx |
| LLM inference | Ollama Cloud API (api.ollama.com) — 30+ open-source models, no GPU on EC2 |
| Vector database | ChromaDB (HNSW cosine, 384-dim, persistent Docker volume) |
| Application | Python 3.12, FastAPI, uvicorn (4 microservices) |
| Frontend | Next.js (portfolio UI, served via catch-all) |
| Embedding model | all-MiniLM-L6-v2 (sentence-transformers, pre-cached at image build) |
| OS | Ubuntu 22.04 LTS (Jammy) |
| Boot automation | systemd (`portfolio.service`, Type=oneshot) |

---

## Repository layout

```
agentlens-infrastructure/
├── terraform/
│   ├── main.tf                   # VPC, subnet, SG, EC2, EIP, key pair
│   ├── variables.tf              # Input variables
│   ├── outputs.tf                # Public IP, SSH command, app URL
│   ├── user-data.sh              # EC2 bootstrap (Docker, git clone, systemd)
│   └── terraform.tfvars.example  # Configuration template
├── docker/
│   ├── Dockerfile.base           # Python 3.12-slim + FastAPI + core libs (~500 MB)
│   ├── Dockerfile.ml             # + sentence-transformers + all-MiniLM-L6-v2 (~2.5 GB)
│   ├── Dockerfile.svc            # Parametrized service builder (SERVICE build arg)
│   ├── Dockerfile.gateway        # Gateway builder (also copies debugger HTML)
│   └── Dockerfile.ui             # Next.js 4-stage build (node:20-alpine)
├── compose/
│   ├── shared.yaml               # ChromaDB + nginx (2 containers, shared by all apps)
│   ├── agentlens.yaml            # AgentLens stack (4 containers)
│   └── portfolio.yaml            # Portfolio UI (1 container)
├── nginx/
│   ├── nginx.conf                # Main config (gzip, 50 MB body, auto workers)
│   └── conf.d/agentlens.conf    # Virtual host: route split by path prefix
├── scripts/
│   ├── deploy.sh                 # Full deploy: terraform + images + services
│   ├── update.sh                 # Selective update (git pull + rebuild)
│   └── teardown.sh               # Stop services + terraform destroy
├── diagrams/
│   └── architecture.svg          # Architecture diagram
├── docs/
│   ├── deployment-runbook.md     # Step-by-step deploy and teardown
│   ├── design-decisions.md       # Why EC2 over ECS, Cloudflare over ALB, etc.
│   └── learnings.md              # Honest retrospective and scale considerations
├── .env.example                  # LLM config template
├── .gitignore                    # Excludes tfstate, .env, SSL keys
└── LICENSE                       # MIT
```

---

## Author

**Adityo Nugroho** — [github.com/adityonugrohoid](https://github.com/adityonugrohoid)

Designed and built end-to-end: microservice architecture, infrastructure-as-code, multi-agent orchestration with autonomous reasoning, quality evaluation, and retry feedback loops. Deployed to production on AWS with Terraform, Docker, and nginx. No frameworks, no LangChain, no LlamaIndex — 260+ tests.

---

## License

MIT
