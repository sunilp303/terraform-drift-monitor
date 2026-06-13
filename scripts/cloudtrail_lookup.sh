#!/usr/bin/env bash
# Best-effort attribution: find recent CloudTrail write events touching the
# drifted resources, so alerts say WHO changed it, not just what changed.
# Failures here degrade gracefully — attribution is never worth failing a run.
set -u

out="$OUT_DIR/attribution.json"
echo "[]" > "$out"

if ! command -v aws >/dev/null 2>&1; then
  echo "::warning::aws CLI not found; skipping CloudTrail attribution."
  exit 0
fi
if [ ! -s "$OUT_DIR/plan.json" ]; then
  echo "::warning::No plan JSON available; skipping CloudTrail attribution."
  exit 0
fi

# Candidate identifiers: physical ids, names, and Name tags of changed resources.
ids=()
while IFS= read -r id; do
  [ -n "$id" ] && ids+=("$id")
done < <(jq -r '
  [ (.resource_drift[]?, (.resource_changes[]? | select(.change.actions != ["no-op"])))
    | .change.before
    | select(. != null)
    | (.id?, .name?, .tags?.Name?)
    | select(. != null and . != "")
    | tostring
  ] | unique | .[0:10] | .[]' "$OUT_DIR/plan.json")

if [ "${#ids[@]}" -eq 0 ]; then
  echo "No resource identifiers found in the plan; skipping CloudTrail attribution."
  exit 0
fi

start_time=$(date -u -d "${LOOKBACK_HOURS:-24} hours ago" +%Y-%m-%dT%H:%M:%SZ)
events="[]"
for id in "${ids[@]}"; do
  if ! resp=$(aws cloudtrail lookup-events \
      --lookup-attributes "AttributeKey=ResourceName,AttributeValue=$id" \
      --start-time "$start_time" --max-results 20 --output json 2>/dev/null); then
    echo "::warning::CloudTrail lookup failed for '$id' (missing cloudtrail:LookupEvents permission?)."
    continue
  fi
  # LookupEvents accepts only one attribute per call, so read-only events are
  # filtered client-side from the raw event payload.
  matched=$(jq --arg id "$id" '
    [.Events[]?
      | (.CloudTrailEvent | fromjson) as $raw
      | select($raw.readOnly != true)
      | {resource: $id,
         event: .EventName,
         actor: (.Username // $raw.userIdentity.arn // "unknown"),
         time: (.EventTime | tostring),
         source_ip: ($raw.sourceIPAddress // "unknown")}
    ]' <<< "$resp" 2>/dev/null) || continue
  events=$(jq -n --argjson a "$events" --argjson b "$matched" '$a + $b')
done

jq 'unique_by([.resource, .event, .time]) | sort_by(.time) | reverse | .[0:25]' <<< "$events" > "$out"
echo "CloudTrail attribution: $(jq length "$out") write event(s) found for drifted resources."
