#!/usr/bin/env bash
# One auto-managed drift issue per environment: opened on first drift,
# one comment per recurrence, closed when a run comes back clean.
# The issue timeline is the human-readable drift history.
set -euo pipefail

if ! command -v gh >/dev/null 2>&1; then
  echo "::error::'gh' CLI is required for github-issue: true (preinstalled on GitHub-hosted runners)."
  exit 1
fi

# A plan error tells us nothing about drift state; leave the issue untouched.
if [ "$EXIT_CODE" = "1" ]; then
  echo "Plan errored; leaving drift issue state unchanged."
  exit 0
fi

title="Terraform drift: ${ENVIRONMENT}"
label="terraform-drift"

existing=$(gh issue list --repo "$GITHUB_REPOSITORY" --state open --label "$label" \
  --json number,title 2>/dev/null \
  | jq -r --arg t "$title" '[.[] | select(.title == $t)][0].number // empty' || true)

if [ "$DRIFT_DETECTED" = "true" ]; then
  if [ -n "$existing" ]; then
    gh issue comment "$existing" --repo "$GITHUB_REPOSITORY" --body-file "$OUT_DIR/summary.md" >/dev/null
    url=$(gh issue view "$existing" --repo "$GITHUB_REPOSITORY" --json url --jq .url)
    echo "Drift recurrence recorded on issue #$existing."
  else
    gh label create "$label" --repo "$GITHUB_REPOSITORY" --color D93F0B \
      --description "Terraform drift detected by terraform-drift-detector" --force >/dev/null 2>&1 || true
    if ! url=$(gh issue create --repo "$GITHUB_REPOSITORY" --title "$title" \
        --label "$label" --body-file "$OUT_DIR/summary.md" 2>/dev/null); then
      # Label may be unavailable (insufficient permissions) — create without it.
      url=$(gh issue create --repo "$GITHUB_REPOSITORY" --title "$title" --body-file "$OUT_DIR/summary.md")
    fi
    echo "Drift issue opened: $url"
  fi
  echo "issue-url=$url" >> "$GITHUB_OUTPUT"
else
  if [ -n "$existing" ]; then
    gh issue comment "$existing" --repo "$GITHUB_REPOSITORY" \
      --body "✅ Drift resolved — the latest check came back clean. (${RUN_URL:-})" >/dev/null
    gh issue close "$existing" --repo "$GITHUB_REPOSITORY" >/dev/null
    echo "Drift resolved; issue #$existing closed."
  else
    echo "No drift and no open drift issue — nothing to do."
  fi
fi
