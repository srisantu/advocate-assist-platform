#!/bin/sh
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

if [ "${1:-}" = "--docker" ]; then
  echo "==> Starting Advocate Assist Full Stack via Docker Compose..."
  docker compose up --build --abort-on-container-exit demo-runner
  docker compose down -v
else
  echo "==> Running Advocate Assist Repeatable Local Demonstration (Zero Cloud Credentials Required)..."
  python3 scripts/verify_terraform.py
  python3 scripts/run_local_demo.py
fi
