# How to use terraform-drift-detector

Step-by-step setup for every mode of the action. The minimal path is steps 1–3;
steps 4–7 add the AWS audit trail and attribution.

## Prerequisites

- Terraform code with **remote state** (S3, Terraform Cloud, etc.) in a GitHub repo.
- GitHub-hosted Ubuntu runners (or self-hosted runners with `bash`, `jq`, `curl`,
  `gh`, and — for AWS features — the `aws` CLI).
- `hashicorp/setup-terraform` **must** set `terraform_wrapper: false`.

## 1. Create a Slack incoming webhook

1. In Slack: **Apps → Incoming Webhooks → Add to Slack** (or create an app with the
   `incoming-webhook` scope).
2. Pick the alert channel for production drift (e.g. `#infra-drift-prod`) and copy the
   webhook URL.
3. Optionally create a second webhook for a quieter non-prod channel.
4. In the caller repo: **Settings → Secrets and variables → Actions**, add
   `SLACK_WEBHOOK_URL` (and optionally `SLACK_WEBHOOK_URL_NONPROD`).

## 2. Add the workflow

Copy [examples/basic.yml](examples/basic.yml) to `.github/workflows/drift.yml` in the
repo containing your Terraform code. Adjust `working-directory`, `environment`, and the
schedule. Add your cloud authentication step before the action.

## 3. Run it once manually

**Actions → Terraform drift → Run workflow.** A clean run ends green. To see the full
pipeline fire, make a harmless out-of-band change (e.g. edit a tag in the cloud console)
and run again: the run goes red, Slack gets a message, and the plan artifact shows the
diff.

## 4. AWS: bootstrap the OIDC role and audit bucket

```bash
cd examples/bootstrap-aws
terraform init
terraform apply \
  -var github_repository=your-org/your-infra-repo \
  -var state_bucket=your-tf-state-bucket \
  -var audit_bucket_name=your-org-drift-audit
```

Outputs give you `role_arn` and `audit_bucket` — add them as the
`DRIFT_DETECTOR_ROLE_ARN` and `AUDIT_S3_BUCKET` secrets. Set
`-var create_oidc_provider=false` if the account already has the GitHub OIDC provider.

The role is deliberately **read-only**: it can plan, look up CloudTrail events, and write
audit records, but it cannot modify infrastructure.

## 5. Enable the full feature set

Use [examples/aws-full.yml](examples/aws-full.yml). The workflow needs:

```yaml
permissions:
  contents: read
  id-token: write   # OIDC
  issues: write     # drift issue
```

| Feature | Input |
|---|---|
| Drift issue per environment | `github-issue: 'true'` |
| Audit record for every run | `audit-s3-bucket: ${{ secrets.AUDIT_S3_BUCKET }}` |
| Who-changed-it attribution | `cloudtrail-attribution: 'true'` |

## 6. Multiple environments

Use [examples/multi-env-matrix.yml](examples/multi-env-matrix.yml): a matrix over
dev/staging/production with per-environment role secrets, backend configs, and var files.
Only the entry with `production: 'true'` alerts the main Slack webhook; the rest route to
`slack-webhook-url-nonprod`. `fail-fast: false` keeps one drifted environment from
cancelling the other checks.

## 7. Reading the results

- **Workflow run** — the step summary shows the drift report; the
  `terraform-drift-<env>-<attempt>` artifact contains `plan.txt`, `plan.json`,
  `summary.json/md`, and `attribution.json`.
- **GitHub Issue** — `Terraform drift: <env>` collects one comment per detection and
  closes automatically when a check comes back clean.
- **S3** — `s3://<bucket>/drift-audit/<env>/` has one JSON record per run; query with
  Athena or `aws s3 cp` for compliance evidence.
- **Outputs** — chain your own steps:

```yaml
- uses: OWNER/terraform-drift-detector@v1
  id: drift
  with: { fail-on-drift: 'false', ... }
- if: steps.drift.outputs.drift-detected == 'true'
  run: echo "Drifted: $(echo '${{ steps.drift.outputs.summary }}' | jq -r '.resources[].address')"
```

## Configuration reference

All inputs and outputs are documented in [README.md](README.md) and `action.yml`.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `'terraform' not found on PATH` | Add `hashicorp/setup-terraform` before the action. |
| Outputs empty or garbled | `terraform_wrapper` is on — set `terraform_wrapper: false`. |
| `Error: Backend initialization required` | Pass backend settings via `init-args: -backend-config=…`. |
| `AccessDenied` on state bucket | The role needs `s3:GetObject`/`s3:ListBucket` on the state bucket (see bootstrap-aws). |
| OIDC `Not authorized to perform sts:AssumeRoleWithWebIdentity` | Trust policy `sub` must match `repo:<org>/<repo>:*`; check `id-token: write` permission. |
| Drift issue not created | Workflow needs `issues: write`; on private repos check the token's scopes. |
| Slack message missing for non-prod | Non-prod routes to `slack-webhook-url-nonprod` when set — check which webhook you configured. |
| `Artifact with name … already exists` | Two action calls share an `environment` label in one run — make them unique. |
| Attribution empty | CloudTrail lookups match physical IDs/names; events older than `cloudtrail-lookback-hours` (default 24h) aren't searched, and data-plane changes may not be in CloudTrail management events. |
| Check is green but you expected drift | `plan` compares against *code + state*: if the change was also made in code, there is no drift. Out-of-band changes appear under "Changed outside Terraform". |
| Scheduled run never starts | GitHub disables schedules on repos with 60+ days of inactivity, and cron is in UTC. |

## A note on remediation

This action never runs `terraform apply`. When drift is detected, review the drift issue
and plan artifact, decide whether the out-of-band change should be kept (update the code)
or reverted (run your normal apply pipeline), and let the next scheduled check close the
issue automatically.
