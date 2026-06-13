#!/usr/bin/env bash
# Core detection: terraform init + plan -detailed-exitcode.
# This script never fails its own step: it records the plan exit code
# (0 = clean, 1 = error, 2 = drift) as step outputs so the alerting steps
# always run, and the action's final "Enforce result" step decides failure.
set -u

env_slug=$(printf '%s' "${ENVIRONMENT:-default}" | tr -c '[:alnum:]._-' '-')
OUT_DIR="${RUNNER_TEMP:-/tmp}/drift-detector/${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}-${env_slug}"
mkdir -p "$OUT_DIR"
echo "out-dir=$OUT_DIR" >> "$GITHUB_OUTPUT"

finish() {
  local ec="$1"
  {
    echo "exit-code=$ec"
    if [ "$ec" = "2" ]; then echo "drift-detected=true"; else echo "drift-detected=false"; fi
    echo "plan-output=$OUT_DIR/plan.txt"
    echo "plan-json=$OUT_DIR/plan.json"
  } >> "$GITHUB_OUTPUT"
  exit 0
}

for tool in terraform jq; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "::error::'$tool' not found on PATH. Add hashicorp/setup-terraform (with terraform_wrapper: false) to your workflow before this action." \
      | tee "$OUT_DIR/plan.txt"
    finish 1
  fi
done

init_args=()
if [ -n "${INIT_ARGS:-}" ]; then
  read -r -a init_args <<< "$INIT_ARGS"
fi
if ! terraform init -input=false -no-color ${init_args[@]+"${init_args[@]}"} > "$OUT_DIR/init.log" 2>&1; then
  cat "$OUT_DIR/init.log"
  cp "$OUT_DIR/init.log" "$OUT_DIR/plan.txt"
  echo "::error::terraform init failed for environment '${ENVIRONMENT:-default}'."
  finish 1
fi

if [ -n "${WORKSPACE:-}" ]; then
  if ! terraform workspace select -no-color "$WORKSPACE" >> "$OUT_DIR/init.log" 2>&1; then
    cat "$OUT_DIR/init.log"
    cp "$OUT_DIR/init.log" "$OUT_DIR/plan.txt"
    echo "::error::Failed to select terraform workspace '$WORKSPACE'."
    finish 1
  fi
fi

# -lock=false: a scheduled, read-only check must never block a real apply.
plan_args=(-detailed-exitcode -input=false -lock=false -no-color -out="$OUT_DIR/tfplan.bin")
if [ -n "${VAR_FILES:-}" ]; then
  while IFS= read -r var_file; do
    [ -n "$var_file" ] && plan_args+=("-var-file=$var_file")
  done <<< "$VAR_FILES"
fi
if [ -n "${PLAN_ARGS:-}" ]; then
  read -r -a plan_extra <<< "$PLAN_ARGS"
  plan_args+=(${plan_extra[@]+"${plan_extra[@]}"})
fi

terraform plan "${plan_args[@]}" > "$OUT_DIR/plan.txt" 2>&1
ec=$?
cat "$OUT_DIR/plan.txt"

case "$ec" in
  0) echo "No drift in environment '${ENVIRONMENT:-default}'." ;;
  2) echo "::warning::Terraform drift detected in environment '${ENVIRONMENT:-default}'." ;;
  *)
    ec=1
    echo "::error::terraform plan failed for environment '${ENVIRONMENT:-default}' — the drift check itself is broken."
    ;;
esac

if [ "$ec" != "1" ]; then
  terraform show -json "$OUT_DIR/tfplan.bin" > "$OUT_DIR/plan.json" 2>/dev/null || true
fi

finish "$ec"
