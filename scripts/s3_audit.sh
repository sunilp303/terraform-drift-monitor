#!/usr/bin/env bash
# Durable audit trail: write a JSON record for EVERY run (drift or not),
# so the trail proves checks actually happened, not just that drift occurred.
set -euo pipefail

if ! command -v aws >/dev/null 2>&1; then
  echo "::error::aws CLI is required when audit-s3-bucket is set."
  exit 1
fi

ts=$(date -u +%Y%m%dT%H%M%SZ)
key="drift-audit/${ENVIRONMENT}/${ts}-run${GITHUB_RUN_ID:-0}.json"

attribution="[]"
if [ -s "$OUT_DIR/attribution.json" ]; then
  attribution=$(cat "$OUT_DIR/attribution.json")
fi

jq -n \
  --slurpfile summary "$OUT_DIR/summary.json" \
  --argjson attribution "$attribution" \
  --arg ts "$ts" \
  --arg repo "${GITHUB_REPOSITORY:-}" \
  --arg sha "${GITHUB_SHA:-}" \
  --arg run_id "${GITHUB_RUN_ID:-}" \
  --arg run_url "${RUN_URL:-}" '
  {timestamp: $ts, repository: $repo, commit: $sha, run_id: $run_id,
   run_url: $run_url, summary: $summary[0], attribution: $attribution}
' > "$OUT_DIR/audit-record.json"

if ! aws s3 cp "$OUT_DIR/audit-record.json" "s3://${AUDIT_S3_BUCKET}/${key}" --only-show-errors; then
  echo "::error::Failed to write audit record to s3://${AUDIT_S3_BUCKET}/${key} (missing s3:PutObject?)."
  exit 1
fi
echo "Audit record written: s3://${AUDIT_S3_BUCKET}/${key}"
