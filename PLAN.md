# Terraform Drift Detector — Reusable GitHub Action — Implementation Plan

## Goal

A **published GitHub Action** (`<org>/terraform-drift-detector@v1`, GitHub Marketplace)
that any repo can drop into a scheduled workflow to detect when real infrastructure has
diverged from Terraform state/code, with:

- **Slack notifications** — alert channel for production drift, quiet routing for non-prod
- **Audit trail** — full plan output + per-run audit records + GitHub Issue drift history
- **Attribution** (AWS opt-in) — who made the out-of-band change, via CloudTrail

## Why this approach

Terraform drift can only be reliably detected by Terraform itself: `terraform plan
-detailed-exitcode` compares state ⇄ real infrastructure ⇄ code and returns exit code `2`
when drift exists. That makes the core detector **cloud-agnostic** — AWS, Azure, GCP, any
provider. AWS-native tools don't fit as the primary detector:

| Tool | Verdict |
|---|---|
| `terraform plan -detailed-exitcode` | ✅ **Primary detector** — authoritative, provider-agnostic |
| CloudFormation drift detection | ❌ Only works for CFN stacks, not Terraform |
| AWS Config | ❌ Change *signals* only; can't diff against TF state |
| driftctl | ❌ In maintenance mode (Snyk); not for new builds |
| CloudTrail | ✅ **Attribution** (opt-in, AWS callers) |
| S3 (versioned) / workflow artifacts / GitHub Issues | ✅ **Audit trail** |

## Design principles for a public action

1. **Composite action, `action.yml` at repo root** — required for Marketplace listing;
   consumable as a single step in any caller workflow.
2. **Auth is the caller's job.** The action never holds or assumes credentials. Callers
   run `aws-actions/configure-aws-credentials` (OIDC recommended), `azure/login`,
   `google-github-actions/auth`, etc., *before* the action step. Keeps the action
   cloud-agnostic and out of the credential-handling business.
3. **Zero runtime dependencies.** Bash + `jq` + `gh` only (preinstalled on GitHub-hosted
   runners). Terraform itself is expected from `hashicorp/setup-terraform` in the caller
   workflow (the action fails fast with a clear message if `terraform` is missing).
4. **Detection only, never mutation.** The action runs `plan`, never `apply`. Document
   that callers should grant read-only cloud permissions (+ state/lock access).
5. **Everything beyond core detection is opt-in via inputs** — Slack, GitHub Issue,
   S3 audit record, CloudTrail attribution all default off/optional.

## Architecture

```
 caller repo                          terraform-drift-detector (this repo)
┌──────────────────────────────┐     ┌─────────────────────────────────────────┐
│ .github/workflows/drift.yml  │     │ action.yml (composite)                   │
│  on: schedule + dispatch     │     │                                          │
│  matrix: [dev, staging, prod]│     │ 1. preflight: terraform present? jq? gh? │
│                              │     │ 2. terraform init (caller's backend)     │
│  - setup-terraform           │     │ 3. terraform plan -detailed-exitcode     │
│  - configure-aws-credentials │     │    -input=false -lock=false -out=tfplan  │
│    (caller's OIDC role)      │     │ 4. exit 0 = clean / 2 = DRIFT / 1 = error│
│  - uses: <org>/terraform-    │────▶│ 5. terraform show -json → drift summary  │
│      drift-detector@v1       │     │ 6. opt-in steps:                         │
│    with:                     │     │    • upload plan artifact                │
│      environment: prod       │     │    • GitHub Issue open/append/close      │
│      slack-webhook-url: ***  │     │    • Slack message (block kit)           │
│      github-issue: true      │     │    • S3 audit JSON  (AWS only)           │
│      audit-s3-bucket: …      │     │    • CloudTrail attribution (AWS only)   │
│      cloudtrail-attribution: │     │ 7. outputs: drift-detected, summary, …   │
│        true                  │     │ 8. fail-on-drift? exit 1 : exit 0        │
└──────────────────────────────┘     └─────────────────────────────────────────┘
```

## Action interface

### Inputs

| Input | Required | Default | Purpose |
|---|---|---|---|
| `working-directory` | no | `.` | Terraform root module path |
| `workspace` | no | — | `terraform workspace select` before plan |
| `var-files` | no | — | newline-separated `-var-file` list |
| `init-args` / `plan-args` | no | — | extra args (e.g. `-backend-config=…`) |
| `environment` | no | `default` | label used in issues/Slack/audit records |
| `production` | no | `false` | marks env as prod → alert-level Slack routing |
| `slack-webhook-url` | no | — | enables Slack notification on drift/error |
| `slack-webhook-url-nonprod` | no | — | optional quiet channel for non-prod |
| `github-issue` | no | `false` | one auto-managed Issue per environment |
| `github-token` | no | `${{ github.token }}` | for Issue management |
| `upload-plan-artifact` | no | `true` | plan output as workflow artifact |
| `audit-s3-bucket` | no | — | AWS opt-in: per-run JSON audit record |
| `cloudtrail-attribution` | no | `false` | AWS opt-in: who-changed-it lookup |
| `fail-on-drift` | no | `true` | step fails on drift (red run = visibility) |

### Outputs

| Output | Meaning |
|---|---|
| `drift-detected` | `true` / `false` |
| `exit-code` | raw plan exit code (`0`/`1`/`2`) |
| `summary` | JSON: add/change/destroy counts + drifted resource addresses |
| `plan-output` | path to the captured human-readable plan |

### Behavior details

- **Exit code 1 (plan error) is alerted too** — a broken drift check is itself an
  incident; it must not fail silently for months.
- `-lock=false` so scheduled checks never block a real apply; `concurrency` guidance
  documented for callers.
- **Slack message:** env badge, add/change/destroy counts, drifted resource addresses
  (truncated list), link to run + artifact + issue, CloudTrail actors if enabled.
- **GitHub Issue lifecycle:** labeled `terraform-drift` + env; opened on first drift,
  one comment per recurrence, auto-closed when a run comes back clean. The issue
  timeline is the human-readable drift history.
- **S3 audit record** (`drift-audit/<env>/<timestamp>-<run_id>.json`): run id, repo,
  git SHA, env, exit code, diff summary, attribution. Written for *every* run, not just
  drift, so the trail proves checks happened. Bucket provisioning is the caller's
  responsibility (sample TF in `examples/`).
- **CloudTrail attribution:** extract drifted resource ids from `terraform show -json
  tfplan` → `aws cloudtrail lookup-events` (write events, last 24h) → match by resource
  name → include actor/time/API call in Slack + audit record. Requires caller's role to
  allow `cloudtrail:LookupEvents`.

## Repository structure

```
terraform-drift-detector/
├── action.yml                      # composite action — Marketplace entry point
├── scripts/                        # bash + jq, no runtime deps
│   ├── detect.sh                   # init/plan/exit-code capture
│   ├── summarize.sh                # plan JSON → summary JSON + markdown
│   ├── github_issue.sh             # issue open/append/close (gh CLI)
│   ├── slack_notify.sh             # block-kit payload → webhook
│   ├── s3_audit.sh                 # audit record → S3 (aws CLI)
│   └── cloudtrail_lookup.sh        # drifted resources → recent write events
├── examples/
│   ├── basic.yml                   # minimal scheduled workflow (copy-paste)
│   ├── aws-full.yml                # OIDC + Slack + issue + S3 audit + CloudTrail
│   ├── multi-env-matrix.yml        # dev/staging/prod matrix with prod routing
│   └── bootstrap-aws/              # sample TF: OIDC role, audit bucket (caller-side)
├── test/
│   └── fixtures/                   # local-backend TF configs that simulate
│                                   # clean / drifted / erroring plans (no cloud creds)
├── .github/workflows/
│   ├── ci.yml                      # shellcheck + action self-test against fixtures
│   └── release.yml                 # semver tag → release → move v1 major tag
├── README.md  HOW-TO-USE.md  LICENSE  Makefile  .gitignore  .env.example
```

## Testing strategy (no cloud account needed in CI)

Fixtures use the `local` backend + `terraform_data`/`null_resource` so CI can exercise
every path without credentials:

- **clean:** state matches config → expect `drift-detected=false`, exit 0
- **drifted:** state seeded to mismatch config → expect `drift-detected=true`, summary
  lists the resource, issue/Slack steps fire (Slack mocked with a local HTTP sink)
- **error:** invalid config → expect alert path for exit code 1

AWS-specific scripts (`s3_audit.sh`, `cloudtrail_lookup.sh`) get a smoke test against
LocalStack in CI, plus a documented manual verification against a real account.

## Implementation phases

```
1. action.yml + detect.sh + summarize.sh         → verify: CI fixture matrix passes
   (core: init/plan/exit-code/outputs)              (clean/drifted/error)
2. Plan artifact upload + fail-on-drift           → verify: artifact downloadable,
                                                    red run on drift when enabled
3. GitHub Issue lifecycle                         → verify: fixture drift opens issue,
                                                    clean run closes it
4. Slack notification + prod routing              → verify: mocked webhook receives
                                                    block-kit payload; prod vs non-prod
                                                    routing correct
5. S3 audit + CloudTrail attribution (AWS opt-in) → verify: LocalStack smoke test;
                                                    manual run against real account
                                                    shows actor in Slack message
6. examples/ + bootstrap-aws sample TF            → verify: copy-paste basic.yml works
                                                    in a fresh test repo
7. Docs, branding, release.yml, Marketplace       → verify: v1.0.0 published; `uses:
   listing (semver + moving v1 tag)                 <org>/terraform-drift-detector@v1`
                                                    resolves from an external repo
```

## Out of scope (documented in README)

- **Auto-remediation** — the action never runs `apply`. The Issue + Slack alert should
  drive a human-reviewed re-apply in the caller's own pipeline.
- **Credential handling** — always the caller's workflow, never action inputs. Static
  cloud keys as action inputs would be a security anti-pattern.
- Terragrunt/multi-root orchestration — callers handle via matrix; may revisit post-v1.

## Decisions to confirm

1. **Org/repo name for publishing** — Marketplace name must be unique
   (`terraform-drift-detector` may be taken; check before branding).
2. **License** — MIT or Apache-2.0 (Apache-2.0 is conventional for HashiCorp-ecosystem
   tooling).
3. **Slack delivery** — incoming webhook only (simplest for external users) vs. also
   supporting a bot token + `chat.postMessage` (threads, richer routing). Recommend
   webhook-only for v1.
4. **`fail-on-drift` default** — `true` makes drift visible as red scheduled runs;
   some users prefer green-but-notified. Recommend default `true`.
