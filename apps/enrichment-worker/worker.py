"""
Advocate Assist — Asynchronous Enrichment Worker (`apps/enrichment-worker/worker.py`)
Processes Pub/Sub interaction messages with:
1. Ephemeral Redis Cluster coordination lock (`SET NX EX`).
2. Durable PostgreSQL/SQLite ACID idempotency check (`UNIQUE(interaction_id)`).
3. Vertex AI capability invocation (or local mock).
4. Crash-injection support (`simulate_crash_before_ack`) to prove safe redelivery after worker termination.
5. Bounded retry (max 5 attempts) and automatic Dead-Letter Queue (DLQ) routing.
"""
import json
import os
import sys
import time
from typing import Dict, Any, Optional

from apps.common.store import DurableCorrectnessStore, EphemeralRedisCoordinator
from apps.common.telemetry import TelemetryRegistry


class EnrichmentWorker:
    def __init__(
        self,
        store: DurableCorrectnessStore,
        redis_coord: EphemeralRedisCoordinator,
        telemetry: TelemetryRegistry,
        max_delivery_attempts: int = 5,
    ):
        self.store = store
        self.redis = redis_coord
        self.telemetry = telemetry
        self.max_delivery_attempts = max_delivery_attempts

    def invoke_vertex_ai_mock(self, interaction_id: str, customer_tier: str, context: Dict[str, Any]) -> Dict[str, Any]:
        start = time.perf_counter()
        if context.get("simulate_permanent_ai_failure"):
            raise RuntimeError("PERMANENT_AI_ERROR: Invalid business context schema for Vertex AI")

        time.sleep(0.015)
        latency = time.perf_counter() - start
        self.telemetry.observe("advocate_vertex_ai_duration_seconds", latency)
        self.telemetry.inc("advocate_vertex_ai_tokens_total", 148)

        intent = context.get("intent", "claim_status_check")
        return {
            "summary": (
                f"Advocate Assist AI Enrichment [{customer_tier}]: Verified context for '{intent}'. "
                "Next best action: provide expedited resolution summary to advocate."
            ),
            "confidence": 0.97,
            "tokens_used": 148,
            "latency_ms": round(latency * 1000, 2),
        }

    def process_message(
        self,
        message: Dict[str, Any],
        attempt: int = 1,
        allow_process_exit_on_crash: bool = False,
    ) -> str:
        """
        Processes a single Pub/Sub delivery attempt.
        Returns one of: 'ACK', 'ACK_IDEMPOTENT_SKIP', 'NACK_RETRY', 'CRASHED_BEFORE_ACK'.
        """
        self.telemetry.inc("advocate_worker_messages_received_total")
        interaction_id = message["interaction_id"]
        correlation_id = message["correlation_id"]
        trace_id = message.get("trace_id", "trace-local")

        lock_key = f"lock:{interaction_id}"
        if not self.redis.acquire_lock(lock_key, ttl_seconds=10.0):
            self.telemetry.log_event(
                "WORKER_LOCK_CONTENTION_NACK",
                correlation_id=correlation_id,
                interaction_id=interaction_id,
                trace_id=trace_id,
                attempt=attempt,
            )
            return "NACK_RETRY"

        try:
            record = self.store.get_interaction(interaction_id)
            if not record:
                raise RuntimeError(f"Interaction {interaction_id} missing from state store")

            # Fast pre-check before calling expensive Vertex AI model:
            # If a previous worker already committed the business update (or crashed right before ACK),
            # skip calling Vertex AI and skip re-applying the downstream CRM update!
            if record["status"] == "COMPLETED" and record["business_effect_count"] >= 1:
                self.store.record_attempt(interaction_id, attempt)
                self.telemetry.inc("advocate_idempotent_skipped_total")
                self.telemetry.log_event(
                    "IDEMPOTENT_REPLAY_SKIP",
                    correlation_id=correlation_id,
                    interaction_id=interaction_id,
                    trace_id=trace_id,
                    attempt=attempt,
                    business_effect_count=record["business_effect_count"],
                    reason="Already committed in durable store; skipping duplicate downstream effect",
                )
                return "ACK_IDEMPOTENT_SKIP"

            context = json.loads(record["business_context"])

            # Invoke Vertex AI capability
            ai_result = self.invoke_vertex_ai_mock(
                interaction_id=interaction_id,
                customer_tier=record["customer_tier"],
                context=context,
            )

            # Atomically apply downstream CRM update + mark COMPLETED in durable store
            applied_new, updated_record = self.store.apply_enrichment_idempotently(
                interaction_id=interaction_id,
                correlation_id=correlation_id,
                enrichment_summary=ai_result["summary"],
                ai_confidence=ai_result["confidence"],
                attempt=attempt,
            )

            if applied_new:
                self.telemetry.inc("advocate_business_updates_applied_total")
                e2e_sec = max(0.001, time.time() - updated_record["created_at"])
                self.telemetry.observe("advocate_enrichment_e2e_duration_seconds", e2e_sec)
                self.telemetry.log_event(
                    "BUSINESS_EFFECT_COMMITTED",
                    correlation_id=correlation_id,
                    interaction_id=interaction_id,
                    trace_id=trace_id,
                    attempt=attempt,
                    business_effect_count=updated_record["business_effect_count"],
                    e2e_latency_ms=round(e2e_sec * 1000, 2),
                )
            else:
                self.telemetry.inc("advocate_idempotent_skipped_total")

            # Fault injection: Terminate worker AFTER business update commit but BEFORE Pub/Sub ACK
            if message.get("simulate_crash_before_ack") and attempt == 1:
                self.telemetry.log_event(
                    "WORKER_CRASH_BEFORE_ACK_INJECTED",
                    correlation_id=correlation_id,
                    interaction_id=interaction_id,
                    trace_id=trace_id,
                    level="ERROR",
                    attempt=attempt,
                    note="Worker committed DB update and is terminating before sending Pub/Sub ACK",
                )
                if allow_process_exit_on_crash:
                    os._exit(137)
                return "CRASHED_BEFORE_ACK"

            self.telemetry.log_event(
                "PUBSUB_MESSAGE_ACKNOWLEDGED",
                correlation_id=correlation_id,
                interaction_id=interaction_id,
                trace_id=trace_id,
                attempt=attempt,
            )
            return "ACK"

        except Exception as exc:
            self.store.record_attempt(interaction_id, attempt, str(exc))
            self.telemetry.inc("advocate_worker_retry_nack_total")
            self.telemetry.log_event(
                "WORKER_PROCESSING_FAILURE_NACK",
                correlation_id=correlation_id,
                interaction_id=interaction_id,
                trace_id=trace_id,
                level="WARNING",
                attempt=attempt,
                max_attempts=self.max_delivery_attempts,
                error=str(exc),
            )
            return "NACK_RETRY"
        finally:
            self.redis.release_lock(lock_key)
