# Advocate Assist — CRM Interaction Enrichment Platform

Production-shaped GCP platform architecture, reusable Terraform Infrastructure-as-Code, OIDC CI/CD automation, and local fault-injection demonstration for the **Advocate Assist CRM Interaction Enrichment** capability.

## 1. Architecture & System Design Overview

During a live contact-center interaction, the enterprise CRM sends an interaction enrichment request containing an `interaction_id` and approved business context. This platform satisfies the **< 2-second synchronous acknowledgement** and **< 30-second asynchronous completion** expectations while guaranteeing **exactly-once downstream business updates** across duplicate Pub/Sub deliveries, Redis cache loss, and worker process crashes.

```
+---------------------------------------------------------------------------------------------------+
| EXTERNAL TRUST BOUNDARY (Enterprise CRM Consumer)                                                 |
|   [Enterprise CRM] --(HTTPS TLS 1.3 + M2M OAuth Bearer + X-Correlation-ID + Idempotency-Key)-->   |
+-------------------------------------------------|-------------------------------------------------+
                                                  |
+-------------------------------------------------v-------------------------------------------------+
| SHARED VPC HOST PROJECT (prj-net-host-{env} | Owned by Central Network Team)                      |
|   [Global External Application Load Balancer] + [Cloud Armor WAF & Rate Quota Policy]             |
|     - Blocks OWASP SQLi/XSS, enforces per-consumer rate limits (500 req/min -> HTTP 429)          |
|     - Routes via Serverless NEG into Service Project (Direct Cloud Run URL disabled)              |
+-------------------------------------------------|-------------------------------------------------+
                                                  |
+-------------------------------------------------v-------------------------------------------------+
| SERVICE PROJECT (prj-advocate-{env} | Attached via Subnet-Scoped roles/compute.networkUser)       |
|                                                                                                   |
|  1. [Cloud Run: advocate-assist-ingest-api-{env}] (SA: advocate-assist-api-{env})                 |
|     - Ingress: INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCING (blocks direct public internet bypass)     |
|     - Validates M2M token, writes initial ACCEPTED state, publishes to Pub/Sub with W3C trace     |
|     - Returns HTTP 202 Accepted (< 2s SLO)                                                        |
|                                         |                                                         |
|                                         v                                                         |
|  2. [Cloud Pub/Sub: advocate-assist-interactions-{env}]                                           |
|     - Multi-zone persistence + Bounded retry (max_delivery_attempts = 5)                          |
|     - Permanently failing messages route to [advocate-assist-interactions-dlq-{env}]              |
|                                         |                                                         |
|                                         v                                                         |
|  3. [Cloud Run: advocate-assist-worker-{env}] (SA: advocate-assist-wrk-{env})                     |
|     - Ingress: INGRESS_TRAFFIC_INTERNAL_ONLY                                                      |
|     - Acquires short coordination lock in [Memorystore for Redis Cluster (99.99% Multi-Zone)]     |
|     - Checks & commits ACID idempotency ledger in [Cloud SQL PostgreSQL (UNIQUE interaction_id)]  |
|     - Invokes [Vertex AI Gemini] & private downstream CRM via [Private Service Connect (PSC)]     |
|     - Exports OpenTelemetry traces & LLM token/latency metrics via [OTel Collector]               |
+---------------------------------------------------------------------------------------------------+

```

### Key Architectural Decisions (See `docs/adr/` for Full ADRs)

* [**ADR-001: Hub-and-Spoke Shared VPC, Private Service Connect & Cloud Run Boundary**](docs/adr/ADR-001-hub-and-spoke-shared-vpc-psc-and-cloud-run.md)**:** Explains how Cloud Run services run in isolated service projects (`prj-advocate-{env}`), consume Shared VPC subnets via least-privilege `roles/compute.networkUser`, block direct edge bypass via `INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCING`, and reach private downstream CRM and Vertex AI endpoints via Private Service Connect (PSC) forwarding rules and private Cloud DNS (`crm-callback.internal.advocate.local`).

* [**ADR-002: Memorystore for Redis Cluster Paired with ACID PostgreSQL Correctness Store**](docs/adr/ADR-002-memorystore-redis-cluster-and-acid-idempotency-store.md)**:** Explains why **Memorystore for Redis Cluster** (`google_redis_cluster`, multi-zone per-shard failover, 99.99% SLA) is used strictly for fast in-flight coordination locking (`SET NX EX`) while **Cloud SQL for PostgreSQL** (`UNIQUE(interaction_id)`) serves as the durable transactional correctness store so cache evictions, Pub/Sub redeliveries, or worker crashes before `ACK` never produce duplicate customer updates.

* [**ADR-003: Multi-Region Recovery (RTO < 15m, RPO = 0s) & OpenTelemetry AI Observability**](docs/adr/ADR-003-multi-region-resilience-rto-rpo-and-observability.md)**:** Defines measurable SLIs/SLOs, error-budget burn alerts, and regional failover between `us-central1` and `us-east1`.

## 2. Quickstart: Local Execution & Fault-Injection Demonstration

No GCP account, cloud credentials, or paid services are required. You can run the complete verification and 5-scenario resilience demonstration with **one command**:

```
make demo
# Or directly:
./scripts/demo.sh

```

If you prefer to run the full multi-container stack (`postgres:16-alpine`, `redis:7-alpine`, `otel/opentelemetry-collector-contrib`, and the Python runner) inside Docker Compose:

```
make demo-docker
# Or: ./scripts/demo.sh --docker

```

### What `make demo` Proves Automatically

1. **Scenario 1 — Valid CRM Request & Fast Correlated Ack (< 2s):** Submits interaction `INT-2026-1001` with correlation ID `corr-happy-1001` and W3C `traceparent`, verifies sub-second `HTTP 202 Accepted` acknowledgement, asynchronous Vertex AI mock enrichment, and `COMPLETED` state.

2. **Scenario 2 — Duplicate Delivery (3x) + Redis Cache Flush:** Flushes the ephemeral Redis state and delivers `INT-2026-1001` two additional times. Proves that the durable ACID store detects the prior commit (`ACK_IDEMPOTENT_SKIP`) and maintains `business_effect_count == 1`.

3. **Scenario 3 — Worker Termination (`SIGKILL` / Exit 137) After Business Update Before Pub/Sub Ack:** Spawns a real child worker OS process for `INT-2026-2002` with `simulate_crash_before_ack=True`. The worker commits the downstream business update to the database and immediately terminates (`os._exit(137)`) before sending the Pub/Sub `ACK`. When the message is redelivered to a healthy worker instance, it reconciles state from the durable store, skips duplicate execution, acknowledges the message, and proves `business_effect_count == 1`.

4. **Scenario 4 — Permanently Failing Event & Bounded Retry to DLQ:** Submits poison interaction `INT-2026-POISON-999`, exercises 5 bounded delivery attempts (`NACK_REQUEUED` x 4 -> `ROUTED_TO_DLQ` on attempt 5), and verifies the event lands in `advocate-assist-interactions-dlq` with `business_effect_count == 0`.

5. **Scenario 5 — OpenTelemetry & Prometheus Metrics Evidence:** Prints structured JSON logs correlated by `correlation_id`, `interaction_id`, and `logging.googleapis.com/trace`, followed by the Prometheus `/metrics` scrape output (`advocate_http_ack_duration_seconds`, `advocate_vertex_ai_duration_seconds`, `advocate_idempotent_skipped_total`, `advocate_dlq_messages_routed_total`).

See retained output in [docs/evidence/local-demo-transcript.log](docs/evidence/local-demo-transcript.log).

## 3. Terraform Verification & Day-2 Operations

### Repository Layout

```
terraform/
├── modules/
│   ├── advocate-platform/     # Reusable platform capability module
│   │   ├── versions.tf        # Explicit Terraform (>=1.7) & Google provider (>=5.20,<6.0) constraints
│   │   ├── variables.tf       # Input validation guardrails blocking unsafe prod settings
│   │   ├── iam.tf             # Dedicated API/Worker SAs, subnet networkUser, GitHub OIDC WIF pool
│   │   ├── secrets.tf         # Multi-region Secret Manager resources & least-privilege accessors
│   │   ├── network.tf         # Cloud Armor WAF, External ALB Serverless NEG, PSC endpoint & Private DNS
│   │   ├── pubsub.tf          # Primary topic, subscription, retry policy (2s-30s), and 5x DLQ
│   │   ├── data.tf            # Memorystore for Redis Cluster (MULTI_ZONE) + Cloud SQL PG + DR Replica
│   │   ├── cloud_run.tf       # Primary & DR Cloud Run services pinned to @sha256 image digests
│   │   ├── observability.tf   # Cloud Monitoring SLO & backlog/503 alert policies
│   │   └── outputs.tf         # Strongly typed outputs for downstream consumers
│   └── repo-governance/       # Terraform-managed GitHub branch protection & shift-left checks
└── environments/
    ├── dev/                   # Isolated dev project, state, and .tftest.hcl suite
    ├── stage/                 # Isolated stage project, state, and .tftest.hcl suite
    └── prod/                  # Isolated prod project, multi-region HA, and negative safety tests

```

### Running Terraform Verification Without Cloud Credentials

Every environment includes a native Terraform 1.7+ test suite (`tests/environment.tftest.hcl`) using `mock_provider "google"`:

```
# Run across all environments via Makefile wrapper:
make tf-test-all

# Or run native Terraform commands directly inside any environment:
cd terraform/environments/prod
terraform init -backend=false
terraform fmt -check -recursive
terraform validate
terraform test -verbose

```

See retained test and plan evidence in:

* [docs/evidence/terraform-test-output.txt](docs/evidence/terraform-test-output.txt)

* [docs/evidence/prod-redacted-plan.txt](docs/evidence/prod-redacted-plan.txt)

* [docs/evidence/security-scan-report.txt](docs/evidence/security-scan-report.txt)

### Onboarding Another Service (Self-Service Platform Pattern)

Application teams onboard a new service without duplicating platform Terraform by instantiating `modules/advocate-platform` with their `service_name`, `project_id`, and `@sha256` digests:

```
module "claims_enrichment_service" {
  source                      = "../../modules/advocate-platform"
  environment                 = "prod"
  service_name                = "claims-enrichment"
  project_id                  = "prj-claims-prod"
  shared_vpc_host_project_id  = "prj-net-host-prod"
  shared_vpc_subnet_self_link = "projects/prj-net-host-prod/regions/us-central1/subnetworks/sb-claims-prod-usc1"
  api_image_digest            = "us-central1-docker.pkg.dev/prj-shared-artifacts/claims/api@sha256:..."
  worker_image_digest         = "us-central1-docker.pkg.dev/prj-shared-artifacts/claims/worker@sha256:..."
  psc_crm_service_attachment  = "projects/prj-crm-producer-prod/regions/us-central1/serviceAttachments/sa-crm-prod"
  crm_oauth_secret_id         = "claims-crm-oauth-secret"
}

```

### Day-2 Terraform Lifecycle Handling

1. **Provider Upgrades:** Provider versions are pinned in `versions.tf` (`>= 5.20.0, < 6.0.0`) and locked in committed `.terraform.lock.hcl` files. Upgrades are performed via `terraform init -upgrade` in a dedicated PR, verified against `terraform test` in `dev` and `stage` before `prod`.

2. **Drift Detection:** Scheduled GitHub Actions workflow runs `terraform plan -detailed-exitcode` read-only every 6 hours. Exit code `2` (drift detected) opens an automated incident issue with the redacted diff.

3. **Brownfield Imports:** Use declarative Terraform 1.5+ `import {}` blocks in code (never ad-hoc CLI `terraform import` without version control):

   ```
   import {
     to = module.advocate_assist.google_pubsub_topic.crm_interactions
     id = "projects/prj-advocate-prod/topics/advocate-assist-interactions-prod"
   }
   
   ```

4. **Refactoring Without Resource Destruction:** Use declarative `moved {}` blocks when renaming module resources so state updates in-place with zero downtime:

   ```
   moved {
     from = module.advocate_assist.google_cloud_run_v2_service.worker
     to   = module.advocate_assist.google_cloud_run_v2_service.enrichment_worker
   }
   
   ```

5. **State Recovery & Destructive Change Protection:** Remote state is stored in per-environment GCS buckets with **Object Versioning** and **Bucket Lock** enabled. Stateful resources (`google_sql_database_instance`, `google_redis_cluster`, `google_cloud_run_v2_service`) enforce `deletion_protection = true` in `prod` (verified via `expect_failures` in `environment.tftest.hcl`).

## 4. CI/CD Behavior, Promotion & Rollback

We enforce strict blast-radius separation by decoupling Infrastructure and Application pipelines in `.github/workflows/`:

1. [**.github/workflows/infra-ci-cd.yml**](https://www.google.com/search?q=.github/workflows/infra-ci-cd.yml)**:**

   * Triggers on `terraform/**` PRs and merges to `main`.

   * Executes `terraform fmt -check`, `terraform validate`, `terraform test` (mocked plan & apply across `dev`, `stage`, `prod`), and **Trivy IaC scanning**.

   * Authenticates to GCP via **GitHub OIDC Workload Identity Federation** (`google-github-actions/auth@v2` -> `gh-oidc-pool-{env}`, zero static service-account keys).

   * Uses `concurrency: { group: tf-infra-prod, cancel-in-progress: false }`, requires `production` environment approval, and fails closed if `terraform/environments/prod/terraform.tfvars` is missing.

2. [**.github/workflows/app-ci-cd.yml**](https://www.google.com/search?q=.github/workflows/app-ci-cd.yml)**:**

   * Runs SAST and the local E2E resilience demo (`./scripts/demo.sh`) on every PR.

   * On merge to `main`, builds the artifact **once**, computes its immutable `sha256:...` digest, publishes `release-manifest.json`, and promotes the **exact same `sha256` digest** sequentially across `dev -> stage -> prod`.

3. [**.github/workflows/rollback.yml**](https://www.google.com/search?q=.github/workflows/rollback.yml)**:**

   * Triggered via `workflow_dispatch` with a previously validated `sha256` digest and `incident_ticket_id`.

   * Shifts Cloud Run traffic back to the validated revision AND updates `terraform/environments/{env}/terraform.tfvars` in Git so desired state in source control and runtime state remain reconciled.

## 5. Incident Runbook: Production 503s & Growing Backlog

See the complete step-by-step operational runbook in [docs/runbooks/INCIDENT-503-AND-GROWING-BACKLOG.md](docs/runbooks/INCIDENT-503-AND-GROWING-BACKLOG.md).

## 6. Assumptions, Implemented vs. Conceptual Scope & Disclosures

### Explicit Assumptions

* External CRM authenticates using M2M OAuth 2.0 Bearer tokens validated at the edge/API layer and supplies a unique `interaction_id` per customer interaction.

* The Central Network Team pre-provisions the Shared VPC Host Project (`prj-net-host-{env}`) and delegates subnet-level `roles/compute.networkUser` to the service project identities.

* Downstream CRM exposes a Private Service Connect (`google_compute_service_attachment`) endpoint accepting an `Idempotency-Key` header.

### Implemented vs. Conceptual Scope

* **Fully Implemented & Executable in Repo:** Reusable Terraform modules (`advocate-platform`, `repo-governance`), `dev`/`stage`/`prod` environments, `.tftest.hcl` positive and negative test suites, FastAPI Ingest API, asynchronous Enrichment Worker, Vertex AI Mock, ACID idempotency & crash-recovery store, ephemeral Redis lock coordinator, OpenTelemetry/Prometheus instrumentation, Docker Compose stack, one-command `make demo` harness, decoupled GitHub Actions workflows (`infra-ci-cd.yml`, `app-ci-cd.yml`, `rollback.yml`), ADRs 001–003, and the Production 503/Backlog Runbook.

* **Represented Conceptually / Mocked (Per Candidate Safeguards):** Live GCP deployment, live Shared VPC host project, live Vertex AI billing endpoint, and live Cloud Armor edge certificates are modeled in Terraform and verified via mocked providers and local service emulators without incurring cloud spend.

### Timebox & AI-Assisted Tooling Disclosure

* **Time Spent:** \~8.5 hours total across architecture design, Terraform module authoring and testing, local Python/OpenTelemetry resilience harness, CI/CD workflow automation, and SRE documentation (within the 8–10 hour assessment timebox).

* **AI Tooling Disclosure:** Generative AI coding and documentation assistance (alongside Cursor / Google Cloud Code patterns) was used to accelerate Terraform boilerplate scaffolding, `.tftest.hcl` test cases, and Markdown formatting. All architectural boundaries, Shared VPC/PSC networking patterns, idempotency transaction logic, failure-injection scenarios, and test outputs were verified and executed locally.

* **Sources Consulted:** HashiCorp Terraform 1.7+ Mock Provider Testing Documentation, Google Cloud Run Shared VPC Direct Egress & Private Service Connect Reference Architecture, Google Cloud Memorystore for Redis Cluster High Availability Documentation, and OpenTelemetry Python SDK Specification.