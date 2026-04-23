# Learnings

Honest retrospective on this architecture. What I would do differently at scale, where costs accumulate, and where the current design reaches its limits.

---

## What I would do differently at 10× scale

**Separate stateless and stateful concerns.** The current design co-locates all seven containers on a single instance. At 10× traffic, the right decomposition is:

- **Stateless services** (lens-gateway, lens-query, lens-retrieval) → ECS Fargate tasks behind an ALB. Auto-scaling based on CPU or request count. Each service scales independently; the retrieval service might need more copies than the gateway.
- **Ingestion** → an async worker reading from SQS. Ingestion is bursty (bulk uploads) and should not compete for CPU with query serving.
- **ChromaDB** → replaced by a managed vector database (OpenSearch with k-NN, or Pinecone, or Weaviate Cloud). Self-managed ChromaDB on a single node has no replication and no HA failover. The persistent Docker volume is the single point of data loss risk.
- **nginx** → replaced by an ALB with path-based routing rules. Removes the need to manage an nginx container and Cloudflare origin certs separately.

**Remote Terraform state.** Move `terraform.tfstate` to an S3 backend with DynamoDB locking. Critical as soon as more than one person runs `terraform apply`.

**Secrets management.** Replace `terraform.tfvars` as the secrets carrier with AWS Secrets Manager or Parameter Store. Inject API keys at container start via task definitions, not at EC2 provision time via user-data.

**Structured logging and metrics.** The current setup has no centralized log collection. At scale: CloudWatch Logs (or Datadog) for container stdout, plus custom metrics for pipeline latency by agent role (retrieval time, grader time, judge time). The AgentLens pipeline already emits per-stage timing in its response JSON; collecting these into a time-series store would allow SLA monitoring and model performance regression detection.

---

## Cost observations

| Item | Current | At 10× |
|------|---------|--------|
| EC2 | t3.small ~$17/month | Multiple Fargate tasks; cost depends on task size and scaling policy |
| EBS | 30 GB gp3 ~$2.40/month | Eliminated for stateless tasks; vector DB cost depends on managed service |
| Elastic IP | $0 (attached) | ALB ~$16/month base + data processing |
| Cloudflare | $0 (free tier) | Still $0 for DNS and edge SSL; Pro tier if advanced WAF rules needed |
| Ollama Cloud API | Pay-per-inference | Dominant cost at scale. The 117B judge model is the most expensive per call. |
| Total | ~$26/month | Depends heavily on traffic and model selection |

**Biggest cost lever:** the Quality Judge calls a 117B parameter model (`gpt-oss:120b`). At scale, swapping the judge for a smaller reasoning model (e.g., a 30B model with extended thinking enabled) would reduce inference cost significantly with minimal quality loss, since the judge is given well-filtered chunks by the grader.

**Swap is a cost workaround, not a feature.** The 6 GB of swap exists because t3.small has 2 GB RAM and the sentence-transformers build peaks around 2.5 GB. This works but adds latency under memory pressure. A t3.medium (4 GB RAM) would eliminate swap dependency for ~$10/month more and is worth it if the instance is running continuously.

---

## What this architecture is not suited for

**Multi-tenant or multi-user production workloads.** A single EC2 instance with shared ChromaDB is not designed for user isolation. All users share the same document corpus and the same container resources. There is no authentication on the AgentLens API itself; Cloudflare provides basic protection but the endpoints are publicly reachable.

**High-volume concurrent queries.** The multi-agent pipeline makes 2–7 sequential LLM calls per query, with the 117B judge being the bottleneck. A t3.small CPU cannot parallelize these calls in a meaningful way. At sustained concurrent load (>5 simultaneous queries), the instance would saturate and queries would queue. Fargate + auto-scaling solves this by adding tasks, but the Ollama Cloud API would become the throughput ceiling.

**Stateful ML pipelines requiring reproducibility.** The embedding model (all-MiniLM-L6-v2) is pinned by being cached at image build time, but the LLM models served by Ollama Cloud API change as new versions are released. There is no model version pinning for the judge or retrieval agent. For research or evaluation pipelines that need reproducible results, model versioning and snapshot infrastructure would be required.

**Long-running ingestion jobs.** The ingestion service processes documents synchronously in an HTTP request. Large document batches will hit the 300-second nginx `proxy_read_timeout`. The right fix is an async worker queue (SQS + a separate ingestion worker) that returns a job ID immediately and processes in the background.

---

## What went well

**The two-tier shared base image strategy worked exactly as intended.** Building `shared-base` and `shared-ml` once reduced total image build time from ~20 minutes (if each service pulled its own dependencies) to ~6 minutes. The pre-cached embedding model means each container start is immediate, with no model download delay.

**Cloudflare origin certificates are simpler than Let's Encrypt in this topology.** Let's Encrypt requires ACME validation and automatic renewal, which is complex when nginx runs inside Docker and the instance may be terminated and recreated by Terraform. Cloudflare origin certs have a 15-year validity and are issued on demand from the dashboard. The tradeoff is that they are only trusted by Cloudflare's edge, not by a browser hitting the origin directly — which is the correct security posture here.

**The Docker embedded DNS resolver requirement in nginx was a non-obvious production detail.** nginx resolves upstream names at startup by default, which fails when container names do not yet exist. Using `resolver 127.0.0.11 valid=30s` and assigning upstream addresses to variables forces nginx to resolve names at request time via Docker's internal DNS, allowing services to start in any order without nginx crashing.
