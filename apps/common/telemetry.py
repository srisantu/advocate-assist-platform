"""
OpenTelemetry & Prometheus Telemetry Helper for Advocate Assist Services.
Aligns with interview architecture: captures custom AI/LLM latency, token throughput,
synchronous ack latency (<2s SLO), e2e completion latency (<30s SLO), idempotent skips,
and DLQ transitions alongside W3C traceparent context propagation.
"""
import json
import time
import uuid
from datetime import datetime, timezone
from typing import Dict, Any, Optional


class TelemetryRegistry:
    def __init__(self, service_name: str):
        self.service_name = service_name
        self.counters: Dict[str, int] = {
            "advocate_http_requests_total": 0,
            "advocate_http_accepted_total": 0,
            "advocate_http_rejected_total": 0,
            "advocate_pubsub_published_total": 0,
            "advocate_worker_messages_received_total": 0,
            "advocate_business_updates_applied_total": 0,
            "advocate_idempotent_skipped_total": 0,
            "advocate_duplicate_business_effect_total": 0,
            "advocate_worker_retry_nack_total": 0,
            "advocate_dlq_messages_routed_total": 0,
            "advocate_vertex_ai_tokens_total": 0,
        }
        self.latencies: Dict[str, list] = {
            "advocate_http_ack_duration_seconds": [],
            "advocate_vertex_ai_duration_seconds": [],
            "advocate_enrichment_e2e_duration_seconds": [],
        }

    def inc(self, metric: str, amount: int = 1):
        self.counters[metric] = self.counters.get(metric, 0) + amount

    def observe(self, metric: str, value_seconds: float):
        self.latencies.setdefault(metric, []).append(round(value_seconds, 6))

    def log_event(
        self,
        event: str,
        correlation_id: str,
        interaction_id: str,
        trace_id: Optional[str] = None,
        level: str = "INFO",
        **kwargs: Any,
    ) -> str:
        payload = {
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "severity": level,
            "service": self.service_name,
            "event": event,
            "correlation_id": correlation_id,
            "interaction_id": interaction_id,
            "logging.googleapis.com/trace": trace_id or uuid.uuid4().hex,
            **kwargs,
        }
        line = json.dumps(payload)
        print(line, flush=True)
        return line

    def render_prometheus_metrics(self) -> str:
        lines = [
            "# HELP advocate_http_requests_total Total synchronous CRM HTTP requests received",
            "# TYPE advocate_http_requests_total counter",
            f'advocate_http_requests_total{{service="{self.service_name}"}} {self.counters["advocate_http_requests_total"]}',
            "# HELP advocate_business_updates_applied_total Total unique downstream CRM business updates applied",
            "# TYPE advocate_business_updates_applied_total counter",
            f'advocate_business_updates_applied_total{{service="{self.service_name}"}} {self.counters["advocate_business_updates_applied_total"]}',
            "# HELP advocate_idempotent_skipped_total Duplicate deliveries safely skipped via ACID idempotency ledger",
            "# TYPE advocate_idempotent_skipped_total counter",
            f'advocate_idempotent_skipped_total{{service="{self.service_name}"}} {self.counters["advocate_idempotent_skipped_total"]}',
            "# HELP advocate_duplicate_business_effect_total Duplicate downstream customer updates (SLO MUST BE 0)",
            "# TYPE advocate_duplicate_business_effect_total counter",
            f'advocate_duplicate_business_effect_total{{service="{self.service_name}"}} {self.counters["advocate_duplicate_business_effect_total"]}',
            "# HELP advocate_dlq_messages_routed_total Permanently failing events routed to Dead-Letter Queue after max retries",
            "# TYPE advocate_dlq_messages_routed_total counter",
            f'advocate_dlq_messages_routed_total{{service="{self.service_name}"}} {self.counters["advocate_dlq_messages_routed_total"]}',
            "# HELP advocate_vertex_ai_tokens_total Total LLM tokens processed by Vertex AI enrichment",
            "# TYPE advocate_vertex_ai_tokens_total counter",
            f'advocate_vertex_ai_tokens_total{{service="{self.service_name}"}} {self.counters["advocate_vertex_ai_tokens_total"]}',
        ]
        for name, samples in self.latencies.items():
            count = len(samples)
            total = round(sum(samples), 6)
            max_val = round(max(samples), 6) if samples else 0.0
            lines.append(f"# HELP {name} Latency summary in seconds")
            lines.append(f"# TYPE {name} summary")
            lines.append(f'{name}_count{{service="{self.service_name}"}} {count}')
            lines.append(f'{name}_sum{{service="{self.service_name}"}} {total}')
            lines.append(f'{name}_max{{service="{self.service_name}"}} {max_val}')
        return "\n".join(lines) + "\n"
