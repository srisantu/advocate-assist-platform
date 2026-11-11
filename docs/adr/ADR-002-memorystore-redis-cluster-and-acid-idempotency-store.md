# ADR-002: Memorystore for Redis Cluster Coordination Paired with ACID PostgreSQL Correctness Store

- **Status:** Accepted
- **Date:** 2026-11-11
- **Owner:** Platform Engineering (Advocate Assist)

## Context
Pub/Sub guarantees **at-least-once** delivery. Duplicate messages, network retries, or a worker crash after applying the downstream CRM update—but before sending the Pub/Sub `ACK`—will cause redelivery of the same `interaction_id`.
Furthermore, the requirements state:
- *"A regional Redis-compatible service may be used for ephemeral cache or coordination, but the product cannot tolerate lost events or duplicate business updates."*
- *"Redelivery, worker restart, or retry must not apply the same business effect more than once."*

## Decision
We implement a **Two-Tier Coordination and Transactional Idempotency Pattern**:

1. **Tier 1 — Fast Distributed Lock & Status Cache (`google_redis_cluster` / Memorystore for Redis Cluster):**
   - In GCP, we provision **Memorystore for Redis Cluster** (`google_redis_cluster`) rather than standard-tier standalone Redis. Memorystore for Redis Cluster distributes shards across multiple availability zones with pre-provisioned replicas per shard (`replica_count = 1` in `prod`), delivering a **99.99% availability SLA**, sub-second per-shard failover, and proxy-less topology discovery.
   - When a worker receives an event for `interaction_id`, it attempts to acquire a short-lived coordination lock (`SET lock:{interaction_id} {worker_id} NX EX 30`) to prevent concurrent duplicate deliveries from racing in parallel.
   - However, because Redis is an ephemeral cache and subject to theoretical eviction or regional cache rebuilds, **Redis is never trusted as the sole source of truth for business correctness**.

2. **Tier 2 — Durable ACID System of Record (Cloud SQL for PostgreSQL with `UNIQUE(interaction_id)`):**
   - Every interaction lifecycle transition (`ACCEPTED` -> `PROCESSING` -> `COMPLETED` / `FAILED_PERMANENT`) and downstream business effect ledger entry (`business_updates` table with `interaction_id PRIMARY KEY`) is persisted in an ACID relational store (**Cloud SQL for PostgreSQL Enterprise Plus** with `availability_type = "REGIONAL"` and cross-region replica in `prod`).
   - Before invoking the downstream CRM update or committing state, the worker executes a transactional check (`SELECT status, business_effect_applied FROM interactions WHERE interaction_id = $1 FOR UPDATE`).
   - The downstream idempotency key (`Idempotency-Key: {interaction_id}`) is passed to the private downstream service, and the record of completion is written in the **same ACID transaction** (`business_effect_count = 1`, `status = 'COMPLETED'`).
   - **Crash Window Recovery (Before Pub/Sub ACK):** If the worker terminates immediately after committing the database update (`simulate_crash_before_ack = true`) before acknowledging Pub/Sub, Pub/Sub redelivers the message after the ack deadline expires. On redelivery, the worker queries PostgreSQL, sees `status = 'COMPLETED'` and `business_effect_applied = true`, logs an `IDEMPOTENT_REPLAY_SKIP` event, increments the OpenTelemetry `advocate.idempotent.skipped_total` counter, and immediately `ACK`s the Pub/Sub message without re-executing the business update.

## Consequences
- **Positive:** Guarantees **exactly-once business effect** even if Redis is completely flushed, if Pub/Sub delivers an event 10 times, or if the worker container crashes mid-flight.
- **Tradeoffs:** Adds ~3–5ms of transactional database write latency per message, well within the 30-second asynchronous completion SLO.
