# 45-Minute Live Technical Defense Playbook & Demo Script

Use this run-of-show during your 45-minute technical defense with the interview panel. You can run the automated demo in one shot (`make demo`) or step through it interactively on screen by pressing `Enter` between stages (`./scripts/interactive_walkthrough.sh`).

---

## 1. Pre-Call Local Terminal Checklist (5 Minutes Before Joining)

Open two terminal tabs and your IDE (VS Code / Cursor) in the `advocate-assist-platform` directory:

```bash
# Terminal 1: Verify everything is clean and warm
cd advocate-assist-platform
git status
./scripts/demo.sh
```

Keep these 4 files open in editor tabs for instant screen-share navigation:
1. `docs/adr/ADR-001-hub-and-spoke-shared-vpc-psc-and-cloud-run.md` (Network, Shared VPC, PSC, Cloud Armor)
2. `terraform/modules/advocate-platform/variables.tf` (Input validation guardrails)
3. `terraform/environments/prod/tests/environment.tftest.hcl` (Mocked plan/apply & negative safety tests)
4. `apps/enrichment-worker/worker.py` (Redis lock + PostgreSQL ACID idempotency + crash hook + DLQ)

---

## 2. Minute-by-Minute Live Walkthrough Script (45 Minutes Total)

### Part 1: Architecture & Continuity from Initial Interview (Minutes 00–10)
**What to show on screen:** `README.md` Architecture Diagram & `docs/adr/`.

**Exact talking points to say out loud:**
> "As we discussed in my initial interview, I designed this platform around four production boundaries:
> 1. **Edge & Hub-and-Spoke Shared VPC Boundary (`ADR-001`):** External CRM traffic enters through the Global External Application Load Balancer and Cloud Armor WAF over TLS. Cloud Run services run in isolated per-environment service projects (`prj-advocate-dev/stage/prod`) with `INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER` and Direct VPC Egress into the Shared VPC host subnet via least-privilege `roles/compute.networkUser`. Downstream CRM callbacks and Vertex AI calls traverse Private Service Connect endpoints resolved via private Cloud DNS.
> 2. **Two-Tier Coordination & ACID Idempotency (`ADR-002`):** Memorystore for Redis Cluster gives us 99.99% multi-zone in-flight locking (`SET NX EX`), but because Redis is ephemeral, Cloud SQL PostgreSQL with a `UNIQUE(interaction_id)` ledger is our durable system of record. Even if Redis is flushed or a worker crashes after committing the DB update but before acknowledging Pub/Sub, we never emit duplicate CRM updates.
> 3. **Decoupled OIDC CI/CD Pipelines:** Infrastructure (`infra-ci-cd.yml`) and Application (`app-ci-cd.yml`) pipelines are strictly separated, authenticate via GitHub OIDC Workload Identity Federation with zero static JSON keys, build the container image once, and promote the immutable `@sha256` digest across `dev -> stage -> prod`.
> 4. **OpenTelemetry AI Observability & Regional DR (`ADR-003`):** Both services emit correlated W3C traces and custom Vertex AI token/latency metrics (`advocate_vertex_ai_duration_seconds`), and production pairs `us-central1` with warm recovery standby in `us-east1` (`RPO = 0s` for acknowledged requests, `RTO < 15m`)."

---

### Part 2: Live Terraform Guardrail & Mocked Test Execution (Minutes 10–20)
**What to run in Terminal 1:**
```bash
make tf-test-all
cat docs/evidence/terraform-test-output.txt
```

**What to highlight in `terraform/environments/prod/tests/environment.tftest.hcl`:**
- Point out `mock_provider "google"` — zero cloud credentials required.
- Point out how `verify_prod_mocked_plan` and `verify_prod_mocked_apply_and_identity_separation` prove that `ingest_api_sa != worker_sa` and `project_id` is isolated per environment.
- Point out the 5 negative `expect_failures` runs in `prod`:
  - `reject_unsafe_public_cloud_run_ingress_in_prod` (blocks `INGRESS_TRAFFIC_ALL`)
  - `reject_disabled_deletion_protection_in_prod` (blocks `enable_deletion_protection = false`)
  - `reject_underprovisioned_min_instances_in_prod` (blocks `min_instances = 0` in `prod`)
  - `reject_wildcard_or_admin_iam_roles_in_prod` (blocks `roles/owner`, `roles/editor`, `roles/compute.networkAdmin`)
  - `reject_mutable_tag_without_sha256_digest` (blocks `:latest` mutable tags)

---

### Part 3: Live Fault-Injection & Resilience Demo (Minutes 20–30)
**What to run in Terminal 1:**
```bash
./scripts/interactive_walkthrough.sh
```
Walk through the 4 interactive pauses:
1. **Scenario 1 (`INT-2026-1001`):** Show the structured JSON log with `HTTP_202_SYNCHRONOUS_ACK` in `0.27ms` (`< 2000ms` SLO), followed by asynchronous AI enrichment and `BUSINESS_EFFECT_COMMITTED` (`business_effect_count = 1`).
2. **Scenario 2 (`3x Duplicate + Redis Flush`):** Show that even after flushing Redis (`redis_coord.flush_all_ephemeral_state()`), delivering `INT-2026-1001` two more times triggers `IDEMPOTENT_REPLAY_SKIP` and keeps `business_effect_count = 1`.
3. **Scenario 3 (`Worker Crash Exit 137 Before Pub/Sub ACK`):** Show `WORKER_CRASH_BEFORE_ACK_INJECTED` where a real child worker OS process commits `INT-2026-2002` to the database and immediately terminates with exit code `137` before acknowledging Pub/Sub. Show Pub/Sub redelivering the message (`attempt: 2`) and the worker safely recovering via `IDEMPOTENT_REPLAY_SKIP` with `business_effect_count = 1`.
4. **Scenario 4 & 5 (`Poison Event -> 5x Retry -> DLQ + /metrics`):** Show `INT-2026-POISON-999` failing 5 bounded times (`NACK_REQUEUED` x 4 -> `ROUTED_TO_DLQ`), followed by the Prometheus `/metrics` output and the SQLite/PostgreSQL ledger table query.

---

### Part 4: Incident Runbook & "One Small Unannounced Change" Defense (Minutes 30–45)

#### A. If Asked About the 503 + Growing Backlog Production Incident (`docs/runbooks/INCIDENT-503-AND-GROWING-BACKLOG.md`)
- **Step 1 (Mitigate in <5m):** Immediately shift Cloud Run traffic back to the prior revision (`gcloud run services update-traffic ... --to-revisions=PREV=100`) and run `rollback.yml` so Git `terraform.tfvars` reconciles with runtime state.
- **Step 2 (Isolate Root Cause):** Check Cloud Run 503 logs (`no available instance` = concurrency/max_instances or Shared VPC subnet IP exhaustion; `exit(137)` = OOMKill) and OTel `advocate_vertex_ai_duration_seconds` spans (downstream PSC/Vertex AI timeout saturation).
- **Step 3 (Drain Backlog Safely):** As the rolled-back worker drains the backlog, monitor `advocate_idempotent_skipped_total` and verify `advocate_duplicate_business_effect_total == 0`.

#### B. Cheat Sheet for the "One Small Unannounced Change" Live Exercise
The assessment states: *"You will walk through the architecture and implementation, answer failure and security questions, and make one small unannounced change."* Here are the 3 most common live changes and exact 3-line edits to make on screen:

1. **Change Type 1: "Change the bounded retry limit from 5 to 3 (or 7) in Terraform and the worker"**
   - In `terraform/modules/advocate-platform/pubsub.tf` (line 39): change `max_delivery_attempts = 5` to `3`.
   - In `scripts/run_local_demo.py` (line 113): change `max_delivery_attempts=5` to `3` and update the assertion list length.
   - Run `./scripts/demo.sh` to prove it live in 1 second.

2. **Change Type 2: "Add a Terraform validation rule restricting `primary_region` to `us-central1` or `us-east4`"**
   - In `terraform/modules/advocate-platform/variables.tf` under `variable "primary_region"`:
     ```hcl
     validation {
       condition     = contains(["us-central1", "us-east4"], var.primary_region)
       error_message = "primary_region must be an approved US region (us-central1 or us-east4)."
     }
     ```
   - Run `make tf-test-all` to verify.

3. **Change Type 3: "Add a new field (e.g., `model_version` or `region_processed`) to the enrichment record and API output"**
   - In `apps/enrichment-worker/worker.py`: include `[region=us-central1]` in `ai_result["summary"]`.
   - Run `./scripts/demo.sh` to show the updated output immediately.
