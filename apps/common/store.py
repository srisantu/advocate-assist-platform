"""
Durable ACID Correctness Store + Ephemeral Redis Coordination Lock Layer.
Provides an SQLite/PostgreSQL ACID transactional ledger ensuring that:
- Duplicate Pub/Sub message delivery never applies a business update more than once.
- Worker termination after the database commit (but before Pub/Sub ACK) recovers cleanly on redelivery.
- Redis cache eviction or restart never compromises business correctness.
"""
import json
import sqlite3
import time
from pathlib import Path
from typing import Dict, Any, Optional, Tuple


class DurableCorrectnessStore:
    def __init__(self, db_path: str):
        self.db_path = db_path
        Path(db_path).parent.mkdir(parents=True, exist_ok=True)
        self._init_schema()

    def _connect(self) -> sqlite3.Connection:
        conn = sqlite3.connect(self.db_path, timeout=10.0, isolation_level="IMMEDIATE")
        conn.row_factory = sqlite3.Row
        conn.execute("PRAGMA journal_mode=WAL;")
        conn.execute("PRAGMA synchronous=FULL;")
        return conn

    def _init_schema(self):
        with self._connect() as conn:
            conn.execute(
                """
                CREATE TABLE IF NOT EXISTS interactions (
                    interaction_id TEXT PRIMARY KEY,
                    correlation_id TEXT NOT NULL,
                    trace_id TEXT NOT NULL,
                    customer_tier TEXT NOT NULL,
                    business_context TEXT NOT NULL,
                    status TEXT NOT NULL,
                    enrichment_summary TEXT,
                    ai_confidence REAL,
                    business_effect_count INTEGER NOT NULL DEFAULT 0,
                    delivery_attempts INTEGER NOT NULL DEFAULT 0,
                    last_error TEXT,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL
                )
                """
            )
            conn.execute(
                """
                CREATE TABLE IF NOT EXISTS downstream_crm_ledger (
                    idempotency_key TEXT PRIMARY KEY,
                    interaction_id TEXT NOT NULL UNIQUE,
                    correlation_id TEXT NOT NULL,
                    enrichment_payload TEXT NOT NULL,
                    applied_at REAL NOT NULL
                )
                """
            )

    def create_or_get_interaction(
        self,
        interaction_id: str,
        correlation_id: str,
        trace_id: str,
        customer_tier: str,
        business_context: Dict[str, Any],
    ) -> Tuple[Dict[str, Any], bool]:
        """
        Inserts a newly accepted interaction request or returns the existing record
        if the external CRM retries the same HTTP POST.
        Returns (record_dict, created_new).
        """
        now = time.time()
        with self._connect() as conn:
            row = conn.execute(
                "SELECT * FROM interactions WHERE interaction_id = ?",
                (interaction_id,),
            ).fetchone()
            if row:
                return dict(row), False

            conn.execute(
                """
                INSERT INTO interactions (
                    interaction_id, correlation_id, trace_id, customer_tier,
                    business_context, status, business_effect_count,
                    delivery_attempts, created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, 'ACCEPTED', 0, 0, ?, ?)
                """,
                (
                    interaction_id,
                    correlation_id,
                    trace_id,
                    customer_tier,
                    json.dumps(business_context),
                    now,
                    now,
                ),
            )
            row = conn.execute(
                "SELECT * FROM interactions WHERE interaction_id = ?",
                (interaction_id,),
            ).fetchone()
            return dict(row), True

    def get_interaction(self, interaction_id: str) -> Optional[Dict[str, Any]]:
        with self._connect() as conn:
            row = conn.execute(
                "SELECT * FROM interactions WHERE interaction_id = ?",
                (interaction_id,),
            ).fetchone()
            return dict(row) if row else None

    def record_attempt(self, interaction_id: str, attempt: int, error_msg: Optional[str] = None):
        now = time.time()
        with self._connect() as conn:
            conn.execute(
                """
                UPDATE interactions
                SET delivery_attempts = ?, last_error = COALESCE(?, last_error), updated_at = ?
                WHERE interaction_id = ?
                """,
                (attempt, error_msg, now, interaction_id),
            )

    def mark_dead_lettered(self, interaction_id: str, attempt: int, error_msg: str):
        now = time.time()
        with self._connect() as conn:
            conn.execute(
                """
                UPDATE interactions
                SET status = 'DEAD_LETTERED', delivery_attempts = ?, last_error = ?, updated_at = ?
                WHERE interaction_id = ?
                """,
                (attempt, error_msg, now, interaction_id),
            )

    def apply_enrichment_idempotently(
        self,
        interaction_id: str,
        correlation_id: str,
        enrichment_summary: str,
        ai_confidence: float,
        attempt: int,
    ) -> Tuple[bool, Dict[str, Any]]:
        """
        Atomically checks whether the business effect for `interaction_id` has already
        been committed. If already committed, returns (False, existing_row) without
        mutating `downstream_crm_ledger` or incrementing `business_effect_count`.
        If not yet committed, inserts into `downstream_crm_ledger` and updates
        `interactions.status = 'COMPLETED'` and `business_effect_count = business_effect_count + 1`
        in a single ACID transaction.
        """
        now = time.time()
        with self._connect() as conn:
            row = conn.execute(
                "SELECT * FROM interactions WHERE interaction_id = ?",
                (interaction_id,),
            ).fetchone()
            if not row:
                raise ValueError(f"Unknown interaction_id: {interaction_id}")

            existing_ledger = conn.execute(
                "SELECT * FROM downstream_crm_ledger WHERE interaction_id = ?",
                (interaction_id,),
            ).fetchone()

            if row["status"] == "COMPLETED" or existing_ledger is not None:
                # Update delivery_attempts for observability without re-applying business effect!
                conn.execute(
                    "UPDATE interactions SET delivery_attempts = ?, updated_at = ? WHERE interaction_id = ?",
                    (attempt, now, interaction_id),
                )
                updated = conn.execute(
                    "SELECT * FROM interactions WHERE interaction_id = ?",
                    (interaction_id,),
                ).fetchone()
                return False, dict(updated)

            # First and only time applying downstream business update
            conn.execute(
                """
                INSERT INTO downstream_crm_ledger (
                    idempotency_key, interaction_id, correlation_id, enrichment_payload, applied_at
                ) VALUES (?, ?, ?, ?, ?)
                """,
                (
                    f"idem-{interaction_id}",
                    interaction_id,
                    correlation_id,
                    enrichment_summary,
                    now,
                ),
            )
            conn.execute(
                """
                UPDATE interactions
                SET status = 'COMPLETED',
                    enrichment_summary = ?,
                    ai_confidence = ?,
                    business_effect_count = business_effect_count + 1,
                    delivery_attempts = ?,
                    updated_at = ?
                WHERE interaction_id = ?
                """,
                (
                    enrichment_summary,
                    ai_confidence,
                    attempt,
                    now,
                    interaction_id,
                ),
            )
            updated = conn.execute(
                "SELECT * FROM interactions WHERE interaction_id = ?",
                (interaction_id,),
            ).fetchone()
            return True, dict(updated)


class EphemeralRedisCoordinator:
    """
    Represents Memorystore for Redis Cluster in-flight distributed lock and fast status cache.
    Because Redis is ephemeral, flushing or losing all keys here must NEVER cause duplicate
    business effects (proven in Scenario 2 & Scenario 3).
    """
    def __init__(self):
        self._locks: Dict[str, float] = {}
        self._cache: Dict[str, str] = {}

    def acquire_lock(self, key: str, ttl_seconds: float = 15.0) -> bool:
        now = time.time()
        expiry = self._locks.get(key)
        if expiry is not None and expiry > now:
            return False
        self._locks[key] = now + ttl_seconds
        return True

    def release_lock(self, key: str):
        self._locks.pop(key, None)

    def flush_all_ephemeral_state(self):
        """Simulates a regional Redis cache flush/eviction event."""
        self._locks.clear()
        self._cache.clear()
