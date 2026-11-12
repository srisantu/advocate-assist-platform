#!/bin/sh
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

pause_step() {
  printf "\n--------------------------------------------------------------------------------\n"
  printf "Press [ENTER] to run the next live defense demonstration step..."
  read -r _
}

clear 2>/dev/null || true
echo "================================================================================"
echo "  ADVOCATE ASSIST — 45-MINUTE LIVE TECHNICAL DEFENSE INTERACTIVE DEMO"
echo "================================================================================"
echo "Step 1 of 4: Verify Commit History & Repository Structure"
git log --oneline -n 7
pause_step

echo "================================================================================"
echo "Step 2 of 4: Verify Terraform Guardrails & Credential-Free Mocked Tests"
echo "================================================================================"
python3 scripts/verify_terraform.py
cat docs/evidence/terraform-test-output.txt
pause_step

echo "================================================================================"
echo "Step 3 of 4: Execute Live Fault-Injection & Resilience Suite (Scenarios 1-5)"
echo "================================================================================"
python3 scripts/run_local_demo.py
pause_step

echo "================================================================================"
echo "Step 4 of 4: Inspect SQLite/PostgreSQL ACID Ledger Rows directly"
echo "================================================================================"
python3 - <<'PY'
import sqlite3
conn = sqlite3.connect("/tmp/advocate_assist_local_demo.db")
conn.row_factory = sqlite3.Row
print("\n--- interactions table (System of Record) ---")
for r in conn.execute("SELECT interaction_id, correlation_id, status, business_effect_count, delivery_attempts FROM interactions"):
    print(dict(r))
print("\n--- downstream_crm_ledger table (Unique Idempotency Key Ledger) ---")
for r in conn.execute("SELECT idempotency_key, interaction_id, correlation_id FROM downstream_crm_ledger"):
    print(dict(r))
PY
echo "\n[COMPLETE] Interactive Technical Defense Demo Finished Successfully."
