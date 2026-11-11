"""
Advocate Assist — Local Vertex AI Capability Mock (`apps/ai-mock/main.py`)
Simulates Vertex AI Gemini interaction enrichment without requiring cloud credentials.
"""
import time
from typing import Dict, Any
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel

app = FastAPI(title="Vertex AI Enrichment Mock", version="1.0.0")


class VertexEnrichRequest(BaseModel):
    interaction_id: str
    customer_tier: str
    business_context: Dict[str, Any]


@app.post("/v1/projects/prj-advocate/locations/us-central1/publishers/google/models/gemini-1.5-pro:generateContent")
async def generate_enrichment(req: VertexEnrichRequest):
    if req.business_context.get("simulate_permanent_ai_failure"):
        raise HTTPException(
            status_code=422,
            detail="UNPROCESSABLE_BUSINESS_CONTEXT: Schema rejected by AI policy guardrail",
        )

    time.sleep(0.02)  # Simulate 20ms fast local AI inference
    intent = req.business_context.get("intent", "general_inquiry")
    return {
        "interaction_id": req.interaction_id,
        "enrichment_summary": (
            f"Advocate Assist Brief [{req.customer_tier}]: Customer inquiring about '{intent}'. "
            "Recommended action: verify prior claim resolution and offer proactive fee waiver."
        ),
        "confidence": 0.96,
        "tokens_used": 148,
        "model_version": "gemini-1.5-pro-002-mock",
    }
