# Incident Runbook: Production Release Succeeds in CI but Causes Intermittent 503s and Growing Message Backlog

- **Runbook ID:** RB-ADV-001
- **Severity:** SEV-1 / P1 (Customer-Facing Latency & Backlog SLO Breach)
- **Triggering Alerts:**
  - `AdvocateHighEdge503Rate`: HTTP 503 responses on External ALB / Cloud Run `ingest-api` or Push Subscription > 0.5% over 3 minutes.
  - `AdvocatePubSubBacklogGrowing`: `oldest_unacked_message_age_seconds > 120s` AND `num_undelivered_messages` slope > 0 after a production deployment.

---

## 1. Why a Release Can Pass CI Yet Fail with 503s + Backlog in Production
Even when unit tests, `terraform test`, and single-request integration tests pass in CI, production traffic exposes concurrency and resource-exhaustion failure modes:
1. **Downstream Vertex AI / PSC Timeout & Concurrency Saturation:** A code or config change increases LLM prompt complexity or timeout from 3s to 25s, or breaks Private Service Connect DNS keep-alive. Worker threads block waiting on I/O, exhausting Cloud Run container concurrency (`max_instance_request_concurrency`) and causing Cloud Run to return `503 Service Unavailable (queue full / instance limit reached)`.
2. **Cloud SQL Connection Pool Starvation:** The new release opens unpooled database connections per request or raises Cloud Run `max_instances` beyond PostgreSQL `max_connections`, causing workers to fail health/readiness probes and NACK Pub/Sub messages continuously.
3. **Shared VPC Subnet IP / Cloud NAT Port Exhaustion:** Scaling Cloud Run revisions with Direct VPC Egress during a rollout temporarily doubles active instances, exhausting `/26` subnet IPs or ephemeral NAT ports.
4. **Memory Leak / OOMKill Under Batch Load:** Large enrichment payloads exceed container memory (`512Mi`), causing container crash loops (`503` on in-flight requests) and unacknowledged Pub/Sub messages returning to the queue after `ack_deadline_seconds`.

---

## 2. Phase 1: Immediate Triage & Mitigation (First 5 Minutes — Stop the Bleeding)

### Step 1: Verify the Active Revision and Correlate with Release Evidence
```bash
gcloud run services describe advocate-ingest-api-prod --region=us-central1 --format="value(status.traffic)"
gcloud run services describe advocate-enrichment-worker-prod --region=us-central1 --format="value(status.traffic)"
```
Check the `X-Release-Digest` and Git SHA in the latest GitHub Actions `app-ci-cd.yml` deployment summary.

### Step 2: Execute Immediate Traffic Rollback to the Previous Validated Digest
Do **not** debug forward in production while error budget is burning. Roll back immediately using either the automated GitHub Actions `rollback.yml` workflow or the emergency CLI command:
```bash
# 1. Roll back Worker to prior known-good revision immediately
gcloud run services update-traffic advocate-enrichment-worker-prod \
  --region=us-central1 \
  --to-revisions=advocate-enrichment-worker-prod-PREVIOUS=100

# 2. Roll back API to prior known-good revision if 503s originate at ingress
gcloud run services update-traffic advocate-ingest-api-prod \
  --region=us-central1 \
  --to-revisions=advocate-ingest-api-prod-PREVIOUS=100
```

### Step 3: Reconcile Source Control with Runtime State
Immediately trigger `.github/workflows/rollback.yml` with the previous `image_digest` (`sha256:...`). This workflow updates `terraform/environments/prod/terraform.tfvars` via an emergency reconciliation PR so the next `terraform apply` does not accidentally re-deploy the broken image digest.

---

## 3. Phase 2: Root-Cause Diagnosis via OpenTelemetry & GCP Telemetry (Minutes 5–15)

Run the following diagnostic queries to pinpoint the bottleneck before re-attempting promotion:

1. **Distinguish Edge 503 vs. Worker 503:**
   ```bash
   gcloud logging read 'resource.type="cloud_run_revision" AND httpRequest.status=503' \
     --project=prj-advocate-prod --limit=20 \
     --format="table(timestamp, resource.labels.service_name, resource.labels.revision_name, textPayload)"
   ```
   - If `textPayload` contains `"The request was aborted because there was no available instance"`, `max_instances` or Shared VPC subnet IP space is exhausted.
   - If `textPayload` contains `"Container called exit(137)"`, the container was OOMKilled.

2. **Inspect OpenTelemetry Downstream Spans (`vertex_ai.latency_ms` & `db.lock_wait_ms`):**
   Query Prometheus / Cloud Monitoring:
   ```promql
   # Check if Vertex AI or PSC callback latency spiked in the bad revision
   histogram_quantile(0.99, sum(rate(advocate_vertex_ai_duration_seconds_bucket[5m])) by (le, revision))
   ```

3. **Monitor Safe Backlog Drain & Idempotency Protection:**
   As the rolled-back revision drains the accumulated Pub/Sub backlog, verify that redelivered messages from the outage window do **not** create duplicate CRM updates:
   ```promql
   # Must remain 0
   sum(increase(advocate_duplicate_business_effect_total[30m]))
   # Expect positive spikes as partially processed messages are safely deduplicated
   sum(rate(advocate_idempotent_skipped_total[5m]))
   ```
   Check the Dead-Letter Queue (`crm-interactions-dlq-sub`): if valid messages exhausted 5 delivery attempts during the 503 outage window, replay them safely using the DLQ replay script (`./scripts/replay_dlq.py`)—our PostgreSQL `UNIQUE(interaction_id)` idempotency ledger guarantees that replaying already-completed messages is a safe no-op.
