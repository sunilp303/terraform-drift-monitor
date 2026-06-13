#!/usr/bin/env bash
# Post a Slack block-kit message on drift (exit 2) or check error (exit 1).
# Routing: production -> slack-webhook-url; non-production -> the quieter
# slack-webhook-url-nonprod when configured, otherwise the main webhook.
set -euo pipefail

if [ "$EXIT_CODE" = "0" ]; then
  exit 0
fi

webhook="${SLACK_WEBHOOK_URL:-}"
if [ "${PRODUCTION:-false}" != "true" ] && [ -n "${SLACK_WEBHOOK_URL_NONPROD:-}" ]; then
  webhook="$SLACK_WEBHOOK_URL_NONPROD"
fi
if [ -z "$webhook" ]; then
  echo "::warning::No Slack webhook applicable for this environment; skipping notification."
  exit 0
fi

summary="$OUT_DIR/summary.json"

if [ "$EXIT_CODE" = "1" ]; then
  header="❌ Terraform drift check FAILED — ${ENVIRONMENT}"
  counts_line="*The drift check itself errored (terraform exit 1) — treat as an incident.*"
  body=$(jq -r '"```" + ((.error // "no output") | .[0:1200]) + "```"' "$summary")
elif [ "${PRODUCTION:-false}" = "true" ]; then
  header="🚨 Terraform drift — ${ENVIRONMENT} (PRODUCTION)"
else
  header="⚠️ Terraform drift — ${ENVIRONMENT}"
fi

if [ "$EXIT_CODE" = "2" ]; then
  counts_line=$(jq -r '"*Plan:* \(.add) to add, \(.change) to change, \(.destroy) to destroy"' "$summary")
  body=$(jq -r '
    ([.resources[].address] | .[0:10] | map("• `\(.)`") | join("\n")) as $list |
    ((.resources | length) - 10) as $more |
    (if $list == "" then "_(no resource list available)_" else $list end)
    + (if $more > 0 then "\n_…and \($more) more — see the plan artifact_" else "" end)
  ' "$summary")
fi

attribution_text=""
if [ -s "$OUT_DIR/attribution.json" ]; then
  attribution_text=$(jq -r '
    .[0:5] | map("• *\(.actor)* — \(.event) on `\(.resource)` at \(.time)") | join("\n")
  ' "$OUT_DIR/attribution.json" 2>/dev/null || true)
fi

links="<${RUN_URL:-}|Workflow run>"
if [ -n "${ISSUE_URL:-}" ]; then
  links="${links}  •  <${ISSUE_URL}|Drift issue>"
fi

payload=$(jq -n \
  --arg header "$header" \
  --arg counts "$counts_line" \
  --arg body "$body" \
  --arg attr "$attribution_text" \
  --arg links "$links" '
  {
    blocks: ([
      {type: "header", text: {type: "plain_text", text: $header, emoji: true}},
      {type: "section", text: {type: "mrkdwn", text: $counts}},
      {type: "section", text: {type: "mrkdwn", text: $body}},
      (if $attr != "" then
        {type: "section", text: {type: "mrkdwn", text: ("*Recent write events (CloudTrail):*\n" + $attr)}}
      else empty end),
      {type: "context", elements: [{type: "mrkdwn", text: $links}]}
    ])
  }')

if ! curl -fsS -X POST -H 'Content-Type: application/json' --data "$payload" "$webhook" >/dev/null; then
  echo "::error::Slack notification failed — check the webhook URL secret."
  exit 1
fi
echo "Slack notification sent for environment '${ENVIRONMENT}'."
