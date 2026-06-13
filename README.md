# Terraform Drift Detector - Testing for Other Providers

A reusable GitHub Action that detects when your real infrastructure has diverged from
Terraform state/code — on a schedule, with Slack alerts for production drift, a GitHub
Issue drift history per environment, and an optional durable audit trail in S3 with
CloudTrail attribution of who made the out-of-band change.

The detector is **cloud-agnostic** (it runs `terraform plan -detailed-exitcode`, the only
authoritative drift check); the S3 audit record and CloudTrail attribution are AWS opt-ins.
It is **detection-only**: the action runs `plan`, never `apply`.

Built for **Platform Engineering, DevOps, SRE, and Cloud Governance** teams, it surfaces
unauthorized, manual, or out-of-band infrastructure changes before they become operational,
security, or compliance problems — and tells you *who* made them.

## Features

- 🔍 **Automated drift detection** on a schedule (`terraform plan -detailed-exitcode`)
- 🚨 **Slack notifications** for production drift events, with prod/non-prod routing
- 📋 **GitHub Issue drift history** — one auto-managed issue per environment
- 🏛️ **Optional S3 audit trail** for long-term, compliance-grade retention
- 👤 **Optional CloudTrail attribution** — identify the user, role, or service responsible
- ☁️ **Cloud-agnostic core** — AWS, Azure, GCP, any Terraform provider
- 🔒 **Detection-only by design** — never runs `terraform apply` or touches state
- 📊 **Historical visibility** into recurring drift patterns
- 🏢 Suitable for **compliance, governance, and operational reviews**

## Quick start

```yaml
# .github/workflows/drift.yml in the repo with your Terraform code
name: Terraform drift
on:
  schedule:
    - cron: '0 */6 * * *'
  workflow_dispatch:

permissions:
  contents: read

jobs:
  drift:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: hashicorp/setup-terraform@v3
        with:
          terraform_wrapper: false   # required
      # Authenticate to your cloud here (e.g. aws-actions/configure-aws-credentials)
      - uses: OWNER/terraform-drift-detector@v1
        with:
          working-directory: infra
          environment: production
          production: 'true'
          slack-webhook-url: ${{ secrets.SLACK_WEBHOOK_URL }}
```

See [examples/](examples/) for the full AWS setup (OIDC, audit trail, attribution) and a
multi-environment matrix, and [HOW-TO-USE.md](HOW-TO-USE.md) for step-by-step setup.

## How it works

```
 your workflow (schedule/dispatch)        terraform-drift-detector@v1
┌──────────────────────────────┐     ┌─────────────────────────────────────────┐
│ checkout                     │     │ terraform init + plan -detailed-exitcode │
│ setup-terraform (no wrapper) │     │   exit 0 = clean / 2 = DRIFT / 1 = error │
│ cloud auth (your OIDC role)  │────▶│ summarize plan JSON                      │
│ uses: …/drift-detector@v1    │     │ opt-in: CloudTrail attribution (AWS)     │
└──────────────────────────────┘     │ opt-in: GitHub Issue open/append/close   │
                                     │ opt-in: Slack alert (prod routing)       │
                                     │ opt-in: S3 audit record (every run, AWS) │
                                     │ plan artifact + step summary             │
                                     │ fail-on-drift gate                       │
                                     └─────────────────────────────────────────┘
```

The action interprets the `plan` exit code as the authoritative drift signal:

| Exit code | Meaning | Action taken |
|---|---|---|
| `0` | No drift — infrastructure matches code + state | Records a clean run; closes any open drift issue |
| `2` | **Drift detected** | Slack alert, GitHub Issue, audit record, attribution |
| `1` | Terraform execution error | **Also alerted** — a silently broken check is worse than drift |

When drift is detected, the action can: send Slack notifications, create or update a GitHub
Issue for tracking, store an audit record in Amazon S3, and query AWS CloudTrail to identify
the user, role, or service responsible for the out-of-band change.

## Inputs

| Input | Default | Description |
|---|---|---|
| `working-directory` | `.` | Path to the Terraform root module |
| `workspace` | — | Terraform workspace to select |
| `var-files` | — | Newline-separated `-var-file` paths |
| `init-args` | — | Extra `terraform init` args (e.g. `-backend-config=…`) |
| `plan-args` | — | Extra `terraform plan` args (space-separated) |
| `environment` | `default` | Label used in issues, Slack, and audit records |
| `production` | `false` | Alert-level Slack routing for this environment |
| `slack-webhook-url` | — | Slack incoming webhook; enables notifications |
| `slack-webhook-url-nonprod` | — | Optional quieter webhook for non-prod |
| `github-issue` | `false` | Auto-managed drift issue per environment |
| `github-token` | `${{ github.token }}` | Token for issue management (`issues: write`) |
| `upload-plan-artifact` | `true` | Upload plan output + summaries as artifact |
| `audit-s3-bucket` | — | AWS: bucket receiving a JSON audit record per run |
| `cloudtrail-attribution` | `false` | AWS: who-changed-it lookup for drifted resources |
| `cloudtrail-lookback-hours` | `24` | Attribution search window |
| `fail-on-drift` | `true` | Fail the step on drift so scheduled runs go red |

## Outputs

| Output | Description |
|---|---|
| `drift-detected` | `true` / `false` |
| `exit-code` | Raw plan exit code: `0` clean, `1` error, `2` drift |
| `summary` | JSON: add/change/destroy counts, changed resources, out-of-band changes |
| `plan-output` | Path to the captured human-readable plan |
| `issue-url` | Drift issue URL (when `github-issue: true` and drift found) |

## Notifications and trail

- **Slack** — fires on drift or check error. `production: 'true'` environments route to
  `slack-webhook-url`; others use `slack-webhook-url-nonprod` when set. Messages include
  change counts, drifted resource addresses, CloudTrail actors (if enabled), and links to
  the run and drift issue.
- **GitHub Issue** — one issue per environment, labeled `terraform-drift`: opened on first
  drift, a comment per recurrence, auto-closed when a run comes back clean. The issue
  timeline is the drift history.
- **S3 audit record** (AWS) — a JSON record for *every* run (drift or not), written to
  `s3://<bucket>/drift-audit/<environment>/<timestamp>-run<id>.json`, so the trail proves
  checks happened. Provision the bucket with [examples/bootstrap-aws](examples/bootstrap-aws).
- **CloudTrail attribution** (AWS) — on drift, recent write events for the drifted
  resources (actor, API call, time, source IP) are included in Slack and the audit record.

## Required permissions

**Workflow permissions:** `contents: read`; add `issues: write` for `github-issue`,
`id-token: write` for AWS OIDC.

**AWS role (assumed by the caller workflow, not this action):** `ReadOnlyAccess` plus
read on the Terraform state bucket, `cloudtrail:LookupEvents` for attribution, and
`s3:PutObject` on the audit bucket. [examples/bootstrap-aws](examples/bootstrap-aws)
provisions exactly this — the role can plan, but never apply.

## Security notes

- The action **never handles cloud credentials** — authenticate in your workflow first
  (OIDC recommended; no static keys).
- Plan output **can contain sensitive values**. Set `upload-plan-artifact: 'false'` or
  restrict artifact/log access if that matters for your state.
- The detector runs with `-lock=false` so it never blocks a real apply.

## Design principles

The action is intentionally **detection-only**. It never modifies infrastructure, updates
Terraform state, or performs automatic remediation. Its job is to provide **visibility,
accountability, and governance** while keeping Terraform as the single source of truth.
When drift is found, the GitHub Issue and Slack alert drive a *human-reviewed* decision:
fold the change into code, or revert it through your normal apply pipeline.

## Ideal use cases

- Terraform governance programs
- Production infrastructure monitoring
- Compliance and audit requirements
- Multi-account AWS environments
- Platform engineering and DevSecOps workflows
- Infrastructure change attribution and forensics

> Keep Terraform as the source of truth. Detect drift early, track changes over time, and
> understand *who changed what* before it impacts production.

## Project structure

```
terraform-drift-detector/
├── action.yml                  # composite action (entry point)
├── scripts/                    # bash + jq, no runtime dependencies
│   ├── detect.sh               # init/plan/exit-code capture
│   ├── summarize.sh            # plan JSON → summary JSON + markdown
│   ├── github_issue.sh         # drift issue lifecycle (gh CLI)
│   ├── slack_notify.sh         # block-kit message → webhook
│   ├── s3_audit.sh             # per-run audit record → S3
│   └── cloudtrail_lookup.sh    # drifted resources → recent write events
├── examples/                   # copy-paste workflows + AWS bootstrap TF
├── test/fixtures/              # local-backend configs for credential-free CI
└── .github/workflows/          # CI (shellcheck + self-test), release tagging
```

## Development

```
make lint       # shellcheck all scripts
make validate   # terraform validate fixtures + examples
make test       # lint + validate (full self-test runs in CI)
```

## License

[MIT](LICENSE)
