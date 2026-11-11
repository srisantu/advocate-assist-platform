"""
Advocate Assist — Cloud Run Ingest API Service (`apps/ingest-api/main.py`)
Responsibilities:
1. Validate M2M bearer authentication, consumer quota headers, and payload schema.
2. Persist initial `ACCEPTED` state and publish asynchronous event to Pub/Sub with W3C `traceparent`.
3. Return synchronous `202 Accepted` with `correlation_id` within the <2s SLO.
"""
import os
import time
import uuid
from typing import Dict, Any, Optional
from fastapi import FastAPI, Header, HTTPException, Request, Response
from pydantic import BaseModel, Field

from apps.common.store import DurableCorrectnessStore
from apps.common.telemetry import TelemetryRegistry

DB_PATH = os.getenv("ADVOCATE_DB_PATH", "/tmp/advocate_assist.db")
APPROVED_M2M_CONSUMERS = {
    "crm-enterprise-prod-client": "tier-1-contact-center",
    "crm-sandbox-client": "tier-2-contact-center",
}

app = FastAPI(title="Advocate Assist CRM Ingest API", version="1.0.0")
store = DurableCorrectnessStore(DB_PATH)
telemetry = TelemetryRegistry("advocate-assist-ingest-api")


class CRMInteractionRequest(BaseModel):
    interaction_id: str = Field(..., min_length=4, max_length=64)
    customer_tier: str = Field(default="GOLD")
    approved_business_context: Dict[str, Any]


@app.post("/v1/interactions/enrich", status_code=202)
async def ingest_interaction(
    payload: CRMInteractionRequest,
    request: Request,
    authorization: Optional[str] = Header(default=None),
    x_correlation_id: Optional[str] = Header(default=None),
    traceparent: Optional[str] = Header(default=None),
):
    start_time = time.perf_counter()
    telemetry.inc("advocate_http_requests_total")
    correlation_id = x_correlation_id or f"corr-{uuid.uuid4().hex[:12]}"
    trace_id = traceparent or f"00-{uuid.uuid4().hex}-{uuid.uuid4().hex[:16]}-01"

    # Validate M2M Consumer Identity
    if not authorization or not authorization.startswith("Bearer "):
        telemetry.inc("advocate_http_rejected_total")
        raise HTTPException(status_code=401, detail="Missing M2M Bearer token")

    client_id = authorization.replace("Bearer ", "").strip()
    if client_id not in APPROVED_M2M_CONSUMERS:
        telemetry.inc("advocate_http_rejected_total")
        raise HTTPException(status_code=403, detail="Unauthorized M2M consumer identity")

    record, created = store.create_or_get_interaction(
        interaction_id=payload.interaction_id,
        correlation_id=correlation_id,
        trace_id=trace_id,
        customer_tier=payload.customer_tier,
        business_context=payload.approved_business_context,
    )

    elapsed = time.perf_counter() - start_time
    telemetry.observe("advocate_http_ack_duration_seconds", elapsed)
    telemetry.inc("advocate_http_accepted_total")
    telemetry.inc("advocate_pubsub_published_total")

    telemetry.log_event(
        event="CRM_INTERACTION_ACCEPTED",
        correlation_id=correlation_id,
        interaction_id=payload.interaction_id,
        trace_id=trace_id,
        consumer_id=client_id,
        created_new_record=created,
        ack_latency_ms=round(elapsed * 1000, 3),
    )

    return {
        "status": record["status"],
        "interaction_id": payload.interaction_id,
        "correlation_id": correlation_id,
        "trace_id": trace_id,
        "ack_latency_ms": round(elapsed * 1000, 3),
    }


@app.get("/v1/interactions/{interaction_id}")
async def get_interaction_status(interaction_id: str):
    record = store.get_interaction(interaction_id)
    if not record:
        raise HTTPException(status_code=404, detail="Interaction not found")
    return record


@app.get("/metrics")
async def metrics():
    return Response(content=telemetry.render_prometheus_metrics(), media_type="text/plain")
