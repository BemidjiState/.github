# BemidjiState/.github

This is a special repository used for GitHub organisation features and shared GitHub Actions workflows. See [GitHub docs on customizing your org profile](https://docs.github.com/en/organizations/collaborating-with-groups-in-organizations/customizing-your-organizations-profile) for information on how this repository is used by GitHub.

---

## Table of Contents

1. [Repository Structure](#1-repository-structure)
2. [Shared Workflows — General](#2-shared-workflows--general)
3. [HQ Deployment System](#3-hq-deployment-system)
4. [Adding a New Repository to HQ](#4-adding-a-new-repository-to-hq)
5. [Repository Settings Reference](#5-repository-settings-reference)
6. [Organisation Settings Reference](#6-organisation-settings-reference)
7. [Workflow Versioning](#7-workflow-versioning)
8. [Enterprise Upgrade Path](#8-enterprise-upgrade-path)
9. [Troubleshooting](#9-troubleshooting)
10. [Shared Workflow Reference](#10-shared-workflow-reference)

---

## 1. Repository Structure

```
BemidjiState/.github/
├── .github/
│   └── workflows/
│       ├── branch-protection-warning.yml  # Enforces release → main merge flow
│       ├── version-increment.yml          # Semantic versioning and tagging
│       ├── hq-deploy.yml                  # HQ shared deploy workflow
│       └── hq-rollback.yml                # HQ shared rollback workflow
├── actions/
│   └── hq-sign-payload/
│       └── action.yml                     # HQ HMAC payload signing action
├── profile/
│   └── README.md                          # Organisation profile page
├── repo-templates/
│   ├── deploy-auto.yml                    # Template — automatic push-based deployments
│   ├── deploy-manual.yml                  # Template — manual workflow_dispatch deployments
│   └── rollback.yml                       # Template — manual rollback
├── scripts/
│   └── configure-environments.sh          # Configures GitHub Environment protection rules
└── README.md                              # This file
```

---

## 2. Shared Workflows — General

Reusable workflows stored here are available to all repositories in the organisation. Any repository can call them using:

```yaml
uses: BemidjiState/.github/.github/workflows/{workflow-name}.yml@{ref}
```

### `branch-protection-warning.yml`

Enforces that merges to `main` only come from the `release` branch. Add to any repo that uses the `main` → `release` → feature branch flow. To prevent merges on failure, branch protection must be enabled in GitHub — without it the workflow will fail with a red X but won't block the merge.

**Usage in a repo:**

```yaml
on:
  pull_request:
    branches: [main]

jobs:
  check:
    uses: BemidjiState/.github/.github/workflows/branch-protection-warning.yml@1
```

### `version-increment.yml`

Automatically calculates a new semantic version string based on conventional commit messages. Updates specified files with the new version, commits them, and creates a tag. Supports updating `package.json`, `style.css`, and WordPress plugin PHP files.

**Usage in a repo:**

```yaml
jobs:
  version:
    uses: BemidjiState/.github/.github/workflows/version-increment.yml@1
    with:
      package_json: true
      style_css: true
```

---

## 3. HQ Deployment System

The HQ deployment system automates code deployment across all BSU and NTC server environments. All deployment logic lives in the shared workflows here — individual repositories contain only thin caller workflows that reference them by version. When the deployment process changes, it changes here and all repositories inherit the update automatically.

### How It Works

When a developer pushes to `main` or `release`, or manually triggers a deployment from the Actions tab, the workflow in that repository calls one of the shared workflows here. The shared workflow:

1. Verifies `HQ_HMAC_SECRET` is configured
2. Calls `/hq/check/health/` — confirms the deployment infrastructure is operational
3. Calls `/hq/check/deployment/` — validates that `HQ_ENVIRONMENTS` matches `config.json` exactly and displays current deployment status
4. References the GitHub environment by name — protection rules apply here (`ws-merge-approval` team approval for production/staging, open for dev)
5. Signs the payload and POSTs to `/hq/deploy/` or `/hq/rollback/`
6. For manual deploys: polls for confirmation, triggers automatic rollback if deployment fails on production/staging

**Two repos, one config.** All package configuration lives in `/data/hq/config.json` on the server — untracked, managed manually. The `HQ_ENVIRONMENTS` repository variable must match the location environment names in `config.json` exactly. The check endpoint catches any mismatch on every run.

**Dev environment detection.** The shared workflow detects dev environments by checking whether the environment name contains `-dev` or `-development` anywhere in the name — e.g. `bsu-dev`, `ntc-dev`, `bsu-undergraduate-catalog-dev`. Automatic rollback on failure is skipped for dev environments — developers simply redeploy.

### Repo Templates

Three caller workflow templates live in `repo-templates/`. Copy these into `.github/workflows/` in each repository that uses HQ:

| Template | Purpose |
|---|---|
| `deploy-auto.yml` | Push to `main` → production, push to `release` → staging. One commented-out job block per environment — uncomment and configure the ones that apply. |
| `deploy-manual.yml` | Manual `workflow_dispatch` — branch picker selects branch, hardcoded options list selects environment |
| `rollback.yml` | Manual `workflow_dispatch` rollback — hardcoded options list selects environment, free-text ref input |

---

## 4. Adding a New Repository to HQ

Follow these steps in order when onboarding a new repository to the HQ deployment system.

### Step 1 — On the Server

```bash
# Add the package definition to /data/hq/config.json
# Then initialise the package directory structure
hq init {package}

# Verify the bare mirror cloned correctly
hq branches {package}

# Test a deployment from the CLI before wiring up GitHub
hq deploy {package} {dev-environment} main
```

### Step 2 — Repository Variables

Go to: **Repository → Settings → Secrets and variables → Actions → Variables tab**

| Variable | Value | Description |
|---|---|---|
| `HQ_PACKAGE` | e.g. `sso-o365` | Package name — must match a key in `/data/hq/config.json` |
| `HQ_ENVIRONMENTS` | e.g. `["bsu-dev","bsu-prod","bsu-staging"]` | JSON array of all valid environments for this package |

`HQ_ENVIRONMENTS` must match the `environment` values in the `locations` array in `config.json` exactly, including capitalisation. It is also used by the check endpoint on every deployment run which fails immediately with a precise error if they are out of sync.

`HQ_ENVIRONMENTS` must also match the `options:` list in `deploy-manual.yml` and `rollback.yml`. The check endpoint catches drift between `HQ_ENVIRONMENTS` and `config.json`. Drift between `HQ_ENVIRONMENTS` and the YAML options list does not cause a deployment failure but means the dropdown may show environments that don't exist — update them together.

### Step 3 — Repository Secret

Go to: **Repository → Settings → Secrets and variables → Actions → Secrets tab**

| Secret | Value |
|---|---|
| `HQ_HMAC_SECRET` | Same value as `DEPLOY_HMAC_SECRET` on the server |

This secret signs all webhook payloads sent to the HQ API. It must match `DEPLOY_HMAC_SECRET` in `/data/domains/api.bemidjistate.edu/hq/config/.env` and in the PHP-FPM pool config.

When the GitHub Enterprise licence is active, this moves to an organisation secret and the per-repo secret can be deleted. No workflow changes needed.

### Step 4 — Environment Protection Rules

Run `configure-environments.sh` from `BemidjiState/.github/scripts/` to configure protection rules for all environments in `HQ_ENVIRONMENTS`:

```bash
./scripts/configure-environments.sh {repo}
```

This reads `WS_MERGE_APPROVAL_TEAM` from the organisation variables and configures:
- **Production/staging environments** — requires `ws-merge-approval` team approval, self-review allowed
- **Dev environments** — no approval required, any branch

Alternatively, configure manually for each environment at: **Repository → Settings → Environments → {environment}**

### Step 5 — Workflow Files

Copy the three template files from `repo-templates/` into `.github/workflows/` in the target repository:

```
repo-templates/deploy-auto.yml    →    .github/workflows/deploy-auto.yml
repo-templates/deploy-manual.yml  →    .github/workflows/deploy-manual.yml
repo-templates/rollback.yml       →    .github/workflows/rollback.yml
```

**`deploy-auto.yml`** — contains commented-out job blocks for the standard environments. Uncomment the blocks that apply to this package and set the correct environment name in each. Remove blocks for environments that don't apply.

Example for a package deploying to BSU only:

```yaml
jobs:
  deploy-bsu-prod:
    if: github.ref_name == 'main'
    uses: BemidjiState/.github/.github/workflows/hq-deploy.yml@1
    with:
      package:           ${{ vars.HQ_PACKAGE }}
      environment:       bsu-prod
      ...

  deploy-bsu-staging:
    if: github.ref_name == 'release'
    uses: BemidjiState/.github/.github/workflows/hq-deploy.yml@1
    with:
      package:           ${{ vars.HQ_PACKAGE }}
      environment:       bsu-staging
      ...
```

**`deploy-manual.yml` and `rollback.yml`** — contain a hardcoded `options:` list of environments. GitHub does not support populating `workflow_dispatch` choice inputs dynamically from variables — the list must be static. Update the `options:` list to match the environments for this package.

### Step 6 — Branch Protection

Go to: **Repository → Settings → Branches → Add branch ruleset**

Configure `main`:
- Require a pull request before merging
- Require approvals
- Block direct pushes

Configure `release`:
- Require a pull request before merging

### Step 7 — Verify

```bash
# Test the webhook pipeline directly from the server
/data/scripts/headquarters/hq-test-webhook.sh {package} {dev-environment} main

# Watch the deployment log
tail -f /data/domains/api.bemidjistate.edu/hq/logs/deploy.log
```

---

## 5. Repository Settings Reference

### Variables

Go to: **Repository → Settings → Secrets and variables → Actions → Variables tab**

| Variable | Required | Description |
|---|---|---|
| `HQ_PACKAGE` | Yes | Package name matching a key in `/data/hq/config.json` |
| `HQ_ENVIRONMENTS` | Yes | JSON array of valid environment names for this package |

### Secrets

Go to: **Repository → Settings → Secrets and variables → Actions → Secrets tab**

| Secret | Required | Description |
|---|---|---|
| `HQ_HMAC_SECRET` | Yes | Shared HMAC secret — same value as `DEPLOY_HMAC_SECRET` on the server |

### Environments

Go to: **Repository → Settings → Environments**

One GitHub environment must be configured for each entry in `HQ_ENVIRONMENTS`. Run `configure-environments.sh {repo}` to handle this automatically, or configure manually:

**For each production/staging environment:**
- Required reviewers: `BemidjiState/ws-merge-approval`
- Prevent self-review: **disabled**

**For each dev environment:**
- Required reviewers: none

---

## 6. Organisation Settings Reference

### Variables

Go to: **BemidjiState → Settings → Secrets and variables → Actions → Variables tab**

| Variable | Description |
|---|---|
| `WS_MERGE_APPROVAL_TEAM` | Comma-separated list of GitHub team slugs with production/staging deployment and rollback rights e.g. `BemidjiState/ws-merge-approval`. Anyone not in a listed team has dev-only access by default. |

To add a new team to the approval group:
1. Update `WS_MERGE_APPROVAL_TEAM` to include the new team slug
2. Run `./scripts/configure-environments.sh --all` to propagate across all repos
3. No workflow files need updating

### Teams

Go to: **BemidjiState → Settings → Teams**

| Team | Visibility | Access |
|---|---|---|
| `ws-merge-approval` | Secret | Referenced by `WS_MERGE_APPROVAL_TEAM` — production/staging deploy and rollback |

---

## 7. Workflow Versioning

Shared workflows are versioned using Git tags on this repository. Tags use `{major}.{minor}.{patch}` format — no `v` prefix.

| Tag | Meaning |
|---|---|
| `1` | Floating major version — always points to latest `1.x.x` release |
| `1.0.0` | Specific version — never moves |
| `main` | Active development — used for testing new changes |

Caller workflows in individual repositories pin to the floating major version tag:

```yaml
uses: BemidjiState/.github/.github/workflows/hq-deploy.yml@1
```

Minor improvements and bug fixes are released as `1.1.0`, `1.2.0` etc. The floating `1` tag moves forward automatically. Breaking changes are released as `2.0.0` — repositories migrate at their own pace by changing `@1` to `@2` in their three caller workflow files.

### Releasing a New Version

```bash
# Tag the specific version
git tag 1.1.0
git push origin 1.1.0

# Move the floating major version tag forward
git tag -f 1
git push origin 1 --force
```

---

## 8. Enterprise Upgrade Path

The organisation GitHub Enterprise licence will be active shortly. The following changes apply once it is in place — no workflow files need updating for any of these.

### HQ_HMAC_SECRET → Organisation Secret

Move `HQ_HMAC_SECRET` from per-repo secrets to a single organisation secret:

**BemidjiState → Settings → Secrets and variables → Actions → Organisation secrets → New organisation secret**

| Secret | Value | Access |
|---|---|---|
| `HQ_HMAC_SECRET` | Same as `DEPLOY_HMAC_SECRET` on the server | All repositories |

Delete per-repo `HQ_HMAC_SECRET` secrets one at a time — the org secret takes effect immediately as each is removed. New repos no longer need this step during onboarding.

### Environment Protection Rules → Organisation-Level Policies

With enterprise, environment protection rules can be enforced at the org level rather than per-repo. Once configured, new repos get the correct protection rules automatically the moment their environments are created by the first workflow run. The `configure-environments.sh` script becomes optional rather than required.

Configure at: **BemidjiState → Settings → Environments** (enterprise feature)

### Branch Protection → Organisation Rulesets

With enterprise, branch protection rules can be defined once as org-level rulesets that apply to all repos matching a pattern. The manual branch protection step during onboarding is eliminated.

Configure at: **BemidjiState → Settings → Rules → Rulesets** (enterprise feature)

---

## 9. Troubleshooting

### HQ_HMAC_SECRET not configured

```
Error: HQ_HMAC_SECRET is not configured on this repository.
```

**Fix:** Repository → Settings → Secrets and variables → Actions → New repository secret
Name: `HQ_HMAC_SECRET`
Value: same as `DEPLOY_HMAC_SECRET` on the server

### Health check failed

```
Health check failed. One or more infrastructure checks did not pass.
  worker_running  FAIL  PID file not found
```

SSH to the server and run:

```bash
hq health
supervisorctl status hq-runner
supervisorctl start hq-runner
```

### Environments out of sync

```
HQ_ENVIRONMENTS repository variable does not match config.json for package 'my-package'.
  ntc-dev  [yaml_only]  In HQ_ENVIRONMENTS but NOT in config.json...
```

**Fix options:**
- Remove `ntc-dev` from `HQ_ENVIRONMENTS` (Repository → Settings → Variables), or
- Add a `ntc-dev` location for this package in `config.json` and run `hq init {package}` on the server

Also update the `options:` list in `deploy-manual.yml` and `rollback.yml` to match.

### HMAC verification failed (403)

`HQ_HMAC_SECRET` does not match `DEPLOY_HMAC_SECRET` on the server.

**Fix:** Verify both values are identical:
- Server: `cat /data/domains/api.bemidjistate.edu/hq/config/.env`
- GitHub: Repository → Settings → Secrets → Update `HQ_HMAC_SECRET`

### Deployment confirmation timed out

```
Deployment confirmation timed out after 60 seconds.
```

**Fix:** Check the deploy log on the server:

```bash
tail -50 /data/domains/api.bemidjistate.edu/hq/logs/deploy.log
hq status {package}
```

### Check endpoint unreachable during polling

```
Warning: Could not confirm deployment outcome.
The check endpoint was unreachable during polling (HTTP 502).
```

The deployment may have succeeded — no automatic rollback is triggered.

**Fix:** Verify manually:

```bash
hq status {package}
hq health
tail -20 /data/domains/api.bemidjistate.edu/hq/logs/deploy.log
```

---

## 10. Shared Workflow Reference

### `hq-deploy.yml`

Handles all deployment logic. Called by `deploy-auto.yml` and `deploy-manual.yml`.

**Inputs:**

| Input | Required | Default | Description |
|---|---|---|---|
| `package` | Yes | — | Package name from `HQ_PACKAGE` |
| `environment` | Yes | — | Target environment name |
| `ref` | Yes | — | Branch, tag, or commit SHA |
| `yaml_environments` | Yes | — | JSON array from `HQ_ENVIRONMENTS` |
| `poll_for_result` | No | `false` | Poll for deployment confirmation |

**Secrets:** `hmac_secret` (required)

**Jobs:** `validate` → `deploy` → `rollback-on-failure` (on failure, non-dev environments only)

**Dev environment detection:** environments containing `-dev` or `-development` anywhere in the name are treated as dev. Automatic rollback is skipped for dev environments.

### `hq-rollback.yml`

Handles all rollback logic. Called by `rollback.yml`.

**Inputs:**

| Input | Required | Description |
|---|---|---|
| `package` | Yes | Package name from `HQ_PACKAGE` |
| `environment` | Yes | Environment to roll back |
| `ref` | Yes | Ref to roll back to |
| `yaml_environments` | Yes | JSON array from `HQ_ENVIRONMENTS` |

**Secrets:** `hmac_secret` (required)

**Jobs:** `validate` → `rollback`

### `hq-sign-payload` (Composite Action)

Signs a JSON payload with HMAC-SHA256. Used internally by both shared workflows.

**Inputs:** `payload` (JSON string), `secret` (HMAC secret)
**Outputs:** `signature` (`sha256={hex}` for `X-Hub-Signature-256` header)

### `branch-protection-warning.yml`

Enforces that merges to a primary branch only come from the `release` branch.

**Inputs:**

| Input | Required | Default | Description |
|---|---|---|---|
| `primary_branch` | No | `main` | The branch to protect |

### `version-increment.yml`

Calculates semantic version from conventional commits, updates specified files, and creates a tag.

**Inputs:**

| Input | Required | Default | Description |
|---|---|---|---|
| `package_json` | No | `false` | Update version in `package.json` |
| `package_json_dir` | No | `''` | Directory containing `package.json` |
| `style_css` | No | `false` | Update version in `style.css` |
| `style_css_dir` | No | `''` | Directory containing `style.css` |
| `wp_plugin_file` | No | `false` | Update version in WordPress plugin PHP file |
| `wp_plugin_file_dir` | No | `''` | Directory containing the WordPress plugin file |

**Outputs:** `new_version` — the calculated semantic version string
