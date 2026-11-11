"""Helper loader so `apps/enrichment-worker/worker.py` (with hyphenated folder) can be imported cleanly."""
import importlib.util
from pathlib import Path

WORKER_PATH = Path(__file__).resolve().parent / "enrichment-worker" / "worker.py"
spec = importlib.util.spec_from_file_location("enrichment_worker_module", WORKER_PATH)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)


def create_worker(store, redis_coord, telemetry, max_delivery_attempts: int = 5):
    return mod.EnrichmentWorker(
        store=store,
        redis_coord=redis_coord,
        telemetry=telemetry,
        max_delivery_attempts=max_delivery_attempts,
    )
