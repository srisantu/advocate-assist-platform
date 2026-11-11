# ADR-003: Multi-Region Disaster Recovery (RTO/RPO) and OpenTelemetry AI Observability

- **Status:** Accepted
- **Date:** 2026-11-11
- **Owner:** Platform Engineering (Advocate Assist)

## Context
Production must survive a regional service disruption (e.g., `us-central1` outage) with defined, measurable **RTO** and **RPO** across stateless compute, messaging, Redis coordination, Secret Manager, Vertex AI, and the durable PostgreSQL state store. Additionally, standard CPU/memory infrastructure metrics do not capture LLM/Vertex AI latency, token throughput, or asynchronous backlog age.

## Decision

### 1. Regional Recovery Architecture & Target Objectives
- **Primary Region:** `us-central1` | **Secondary (Recovery) Region:** `us-east1`
- **Target RPO (Recovery Point Objective): `0 seconds` for acknowledged requests**
  - **How Achieved:** A synchronous `202 Accepted` response is only returned to the CRM after the interaction record is committed to Regional HA Cloud SQL (with synchronous cross-zone replication and continuous cross-region replication to `us-east1`) and published to Google Cloud Pub/Sub (which replicates message data across multiple zones and routes globally).
  - **How Measured:** Continuous synthetic canary transactions (`canary-interaction-probe`) every 60 seconds comparing acknowledged `interaction_id` timestamps at the edge against committed rows in the `us-east1` replica (`replication_lag_seconds` SLI).
- **Target RTO (Recovery Time Objective): `< 15 minutes` (Warm Active-Passive / Multi-Region Cloud Run)**
  - **Stateless Compute (`ingest-api`, `enrichment-worker`):** Warm standby Cloud Run services are pre-deployed in `us-east1` (`min_instance_count = 2` in `prod`) with identical container digests. The Global External Application Load Balancer automatically drains `us-central1` serverless NEGs to `us-east1` within 30 seconds of health-check failure.
  - **Secrets (`Secret Manager`):** Provisioned with `auto` multi-regional replication (or explicit `us-central1` + `us-east1` user-managed replication), requiring zero failover action.
  - **AI Dependency (`Vertex AI`):** Worker configuration uses a regional endpoint list (`["us-central1-aiplatform.googleapis.com", "us-east1-aiplatform.googleapis.com"]`) with circuit-breaker failover after 3 consecutive 5xx/timeout errors.
  - **Cache (`Memorystore for Redis Cluster`):** Ephemeral per-region cluster in `us-east1` starts warm and empty; because PostgreSQL is the system of record for idempotency, an empty Redis cache in `us-east1` causes zero duplicate business updates.
  - **Durable Store (`Cloud SQL PostgreSQL`):** Cross-region read replica in `us-east1` is promoted to primary via automated runbook (`gcloud sql instances promote-replica`), completing within 5–8 minutes.
  - **Failback Procedure:** Once `us-central1` stabilizes, create a fallback replica in `us-central1`, wait for `replication_lag_seconds == 0`, pause ingest for a <60s maintenance window (or rely on CRM retry window), promote `us-central1`, and restore normal ALB routing weights.

### 2. Full-Stack OpenTelemetry Instrumentation for Agentic AI Workloads
- Both Python services (`ingest-api` and `enrichment-worker`) are instrumented with the **OpenTelemetry SDK** and export via OTLP (`otel-collector`) to Prometheus / Google Cloud Managed Service for Prometheus and Cloud Trace.
- W3C `traceparent` and `X-Correlation-ID` headers are injected into Pub/Sub message attributes so a single trace spans:
  `CRM HTTP POST -> Cloud Run API -> Pub/Sub Publish -> Pub/Sub Pull -> Redis Lock -> Vertex AI Enrichment -> PSC Downstream Update -> DB Commit`.

### 3. Service-Level Indicators (SLIs) and Objectives (SLOs)
| SLI Metric | Measurement Source (OTel / Prometheus) | Target SLO (28-day rolling) | Error Budget Burn Alert |
| :--- | :--- | :--- | :--- |
| **Synchronous Ack Latency** | `histogram_quantile(0.99, rate(advocate_http_ack_duration_seconds_bucket[5m]))` | `99.0%` of valid requests acknowledged in `< 2.0s` | Page if 1h burn rate > 14.4x |
| **Enrichment Completion Latency** | `histogram_quantile(0.95, rate(advocate_enrichment_e2e_duration_seconds_bucket[5m]))` | `95.0%` of accepted requests reach `COMPLETED` in `< 30.0s` | Page if `p95 > 30s` for 5m |
| **Business Correctness (Deduplication)** | `sum(rate(advocate_duplicate_business_effect_total[5m]))` | `0` duplicate downstream updates (`100%` idempotency) | Immediate P1 page on `> 0` |
| **Pub/Sub Backlog Age** | `pubsub_subscription_oldest_unacked_message_age_seconds` | Oldest unacked message `< 60s` | Page if `> 120s` for 5m |
| **Edge Availability** | `sum(rate(advocate_http_requests_total{status!~"5.."}[5m])) / sum(rate(advocate_http_requests_total[5m]))` | `99.95%` non-5xx responses | Page if 5xx rate `> 0.5%` for 3m |
