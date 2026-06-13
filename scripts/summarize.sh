#!/usr/bin/env bash
# Build machine-readable (summary.json) and human-readable (summary.md)
# drift summaries from the plan JSON produced by detect.sh.
set -euo pipefail

cd "$OUT_DIR" || exit 1

if [ "$EXIT_CODE" = "1" ] || [ ! -s plan.json ]; then
  error_excerpt=$(tail -c 2000 plan.txt 2>/dev/null || true)
  jq -n --arg env "$ENVIRONMENT" --arg err "${error_excerpt:-no plan output captured}" '
    {environment: $env, exit_code: 1, drift_detected: false, error: $err,
     add: 0, change: 0, destroy: 0, resources: [], out_of_band: []}' > summary.json
else
  jq --arg env "$ENVIRONMENT" --argjson ec "$EXIT_CODE" '
    ([.resource_changes[]? | select(.change.actions != ["no-op"])]) as $changes |
    {
      environment: $env,
      exit_code: $ec,
      drift_detected: ($ec == 2),
      add:     ([$changes[] | select(.change.actions | index("create"))] | length),
      change:  ([$changes[] | select(.change.actions | index("update"))] | length),
      destroy: ([$changes[] | select(.change.actions | index("delete"))] | length),
      resources:   [$changes[] | {address: .address, actions: .change.actions}],
      out_of_band: [.resource_drift[]? | {address: .address, actions: .change.actions}]
    }' plan.json > summary.json
fi

jq -r --arg run_url "${RUN_URL:-}" '
  (["### Terraform drift report — `\(.environment)`", ""]
  + (if .exit_code == 1 then
      ["❌ **Drift check failed** — terraform errored; the check itself is broken.", "", "```"]
      + [(.error // "no output")] + ["```"]
    elif .drift_detected then
      ["🚨 **Drift detected** — \(.add) to add, \(.change) to change, \(.destroy) to destroy.", "",
       "**Changed resources:**"]
      + [.resources[] | "- `\(.address)` (\(.actions | join(", ")))"]
      + (if (.out_of_band | length) > 0 then
          ["", "**Changed outside Terraform (out-of-band):**"]
          + [.out_of_band[] | "- `\(.address)` (\(.actions | join(", ")))"]
        else [] end)
    else
      ["✅ No drift detected."]
    end)
  + (if $run_url != "" then ["", "_Workflow run: \($run_url)_"] else [] end))
  | join("\n")
' summary.json > summary.md

{
  echo "summary<<TF_DRIFT_SUMMARY_EOF"
  jq -c . summary.json
  echo "TF_DRIFT_SUMMARY_EOF"
} >> "$GITHUB_OUTPUT"

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  cat summary.md >> "$GITHUB_STEP_SUMMARY"
fi
