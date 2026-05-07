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
8. [Troubleshooting](#8-troubleshooting)
9. [Shared Workflow Reference](#9-shared-workflow-reference)

---

## 1. Repository Structure

```
BemidjiState/.github/
├── .github/
│   └── workflows/
│       ├── branch-protection-warning.yml  # Enforces release → main merge flow
│       ├── version-increment.yml          # Semantic versioning and tagging
│       ├── hq-deploy-git.yml              # HQ shared deploy workflow — git delivery
│       ├── hq-deploy-zip.yml              # HQ shared deploy workflow — zip delivery
│       └── hq-rollback.yml                # HQ shared rollback workflow
├── profile/
│   └── README.md                          # Organisation profile page
├── repo-templates/
│   ├── deploy-git-auto.yml                # Template — git delivery, automatic push-based deployment
│   ├── deploy-git-manual.yml              # Template — git delivery, manual workflow_dispatch deployment
│   ├── deploy-zip-auto.yml                # Template — zip delivery, automatic release-based deployment
│   ├── deploy-zip-manual.yml              # Template — zip delivery, manual workflow_dispatch deployment
│   ├── deploy-zip-feature.yml             # Template — zip delivery, feature branch build and deploy to dev
│   └── rollback.yml                       # Template — manual rollback, works for both delivery types
├── scripts/
│   └── configure-environments.sh          # Configures GitHub Environment protection rules
└── README.md                              # This file
```

---

## 2. Shared Workflows — General

Reusable workflows stored here are available to all repositories in the organisation. Any repository can call them using:

```yaml
uses: BemidjiState/.github/.github/workflows/{workflow-name}.yml@{version}
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

The HQ deployment system automates code deployment across all BSU and NTC server environments. All deployment logic lives in the shared workflows here — individual repositories contain only thin caller workflows that reference them by version tag. When the deployment process changes, it changes here and all repositories inherit the update on their next version bump.

### Delivery Types

HQ supports two delivery methods. The correct shared workflow depends on which delivery type the package uses — this is configured in `/data/hq/config.json` on the server.

| Delivery | Config | Description | Shared workflow |
|---|---|---|---|
| Git | `delivery: "git"` (default) | HQ clones a bare mirror and deploys via `git archive`. Used for packages without a build step. | `hq-deploy-git.yml` |
| Zip | `delivery: "zip"` | HQ downloads a compiled zip from a GitHub Release asset. Used for packages with a build step. | `hq-deploy-zip.yml` |

### How It Works

A repo-level caller workflow in each repository defines when deployments trigger — on push, on release publish, or manually via `workflow_dispatch`. The caller workflow passes the package name, target environment, and ref to one of the shared workflows here. The shared workflow then:

1. Verifies `HQ_PACKAGE` and `HQ_ENVIRONMENTS` repository variables are configured
2. Calls `/hq/check/health/` — confirms the deployment infrastructure is operational
3. Calls `/hq/check/deployment/` — validates that `HQ_ENVIRONMENTS` matches `config.json` exactly and displays current deployment status
4. References the GitHub environment by name — protection rules apply here (`ws-merge-approval` team approval for non-dev environments, open for dev)
5. Signs the payload and POSTs to `/hq/deploy/` or `/hq/rollback/`
6. For manual deploys: polls for confirmation, triggers automatic rollback if deployment fails on non-dev environments

**Two repos, one config.** All package configuration lives in `/data/hq/config.json` on the server — untracked, managed manually. The `HQ_ENVIRONMENTS` repository variable must match the location environment names in `config.json` exactly. The check endpoint catches any mismatch on every run.

**Dev environment detection.** Dev environments are identified by `-dev` or `-development` anywhere in the environment name. Automatic rollback on failure is skipped for dev environments — developers simply redeploy.

### Repo Templates

Six caller workflow templates live in `repo-templates/`. Copy the relevant templates into `.github/workflows/` in the target repository and configure them for the package. The templates are starting points — all environment options lists and job blocks are commented out. The developer uncomments and configures only what applies to their package.

Choose templates based on the package delivery type — see [Delivery Types](#delivery-types) above.

**Git delivery packages:**

| Template | Copy to repo as | Purpose |
|---|---|---|
| `deploy-git-auto.yml` | `deploy-auto.yml` | Automatic push-based deployment. Configure which branches trigger which environments. |
| `deploy-git-manual.yml` | `deploy-manual.yml` | Manual dispatch — branch picker selects branch, options list selects environment. |
| `rollback.yml` | `rollback.yml` | Manual rollback — options list selects environment, free-text ref input. |

**Zip delivery packages:**

| Template | Copy to repo as | Purpose |
|---|---|---|
| `deploy-zip-auto.yml` | `deploy-zip-auto.yml` | Automatic release-based deployment. Configure which release types (prerelease/stable) trigger which environments. |
| `deploy-zip-manual.yml` | `deploy-zip-manual.yml` | Manual dispatch — operator types a release tag, options list selects environment. |
| `deploy-zip-feature.yml` | `deploy-zip-feature.yml` | Manual dispatch — builds from a feature branch, uploads artifact, deploys to dev only. Requires updating the build steps for the package. |
| `rollback.yml` | `rollback.yml` | Manual rollback — same template as git delivery, works for both. |

---

## 4. Adding a New Repository to HQ

Follow these steps in order when onboarding a new repository to the HQ deployment system.

### Step 1 — On the Server

```bash
# Add the package definition to /data/hq/config.json
# Then initialise the package directory structure
hq init {package}

# Verify the bare mirror cloned correctly (git delivery only)
hq branches {package}

# Test a deployment from the CLI before wiring up GitHub
hq deploy {package} {dev-environment} main
```

### Step 2 — Repository Variables

Go to: **Repository → Settings → Secrets and variables → Actions → Variables tab**

| Variable | Value | Description |
|---|---|---|
| `HQ_PACKAGE` | e.g. `my-package` | Package name — must match a key in `/data/hq/config.json` |
| `HQ_ENVIRONMENTS` | e.g. `["env-dev","env-prod","env-staging"]` | JSON array of all valid environments for this package |

`HQ_ENVIRONMENTS` must match the `environment` values in the `locations` array in `config.json` exactly, including capitalisation. The check endpoint validates this on every deployment run and fails immediately with a precise error if they are out of sync.

`HQ_ENVIRONMENTS` must also match the `options:` list in the manual deploy and rollback workflows. The check endpoint catches drift between `HQ_ENVIRONMENTS` and `config.json`. Drift between `HQ_ENVIRONMENTS` and the YAML options list does not cause a deployment failure but means the dropdown may show environments that do not exist — update them together.

### Step 3 — Environment Protection Rules

Run `configure-environments.sh` from `BemidjiState/.github/scripts/` to configure protection rules for all environments in `HQ_ENVIRONMENTS`:

```bash
./scripts/configure-environments.sh {repo}
```

This reads `WS_MERGE_APPROVAL_TEAM` from the organisation variables and configures:
- **Production/staging environments** — requires `ws-merge-approval` team approval, self-review allowed
- **Dev environments** — no approval required, any branch

Alternatively, configure manually for each environment at: **Repository → Settings → Environments → {environment}**

### Step 4 — Workflow Files

Copy the relevant template files from `repo-templates/` into `.github/workflows/` in the target repository. See the [Repo Templates](#repo-templates) table above for which templates apply to git vs zip delivery packages.

All environment `options:` lists in the templates are commented out. Uncomment only the environments that apply to this package and ensure they match `HQ_ENVIRONMENTS` and `config.json` exactly.

For `deploy-zip-auto.yml` and `deploy-git-auto.yml`, job blocks for each environment are also commented out. Uncomment the blocks that apply and remove the rest.

### Step 5 — Branch Protection

Go to: **Repository → Settings → Branches → Add branch ruleset**

Configure `main`:
- Require a pull request before merging
- Require approvals
- Block direct pushes

Configure `release`:
- Require a pull request before merging

### Step 6 — Verify

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

The HMAC secret is configured at the organisation level and is automatically available to all repositories. No per-repository secret configuration is needed.

Go to: **BemidjiState → Settings → Secrets and variables → Actions → Organisation secrets**

| Secret | Description |
|---|---|
| `ORG__HQ_HMAC` | Shared HMAC secret — same value as `DEPLOY_HMAC_SECRET` on the server |

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

### Secrets

Go to: **BemidjiState → Settings → Secrets and variables → Actions → Organisation secrets**

| Secret | Description |
|---|---|
| `ORG__HQ_HMAC` | HMAC secret for HQ webhook payload signing — same value as `DEPLOY_HMAC_SECRET` on the server. Available to all repositories automatically. |

### Teams

Go to: **BemidjiState → Settings → Teams**

| Team | Visibility | Access |
|---|---|---|
| `ws-merge-approval` | Secret | Referenced by `WS_MERGE_APPROVAL_TEAM` — production/staging deploy and rollback |

---

## 7. Workflow Versioning

Shared workflows are versioned using Git tags on this repository. Tags use `{major}.{minor}.{patch}` format — no `v` prefix. Caller workflows in individual repositories pin to a specific version tag:

```yaml
uses: BemidjiState/.github/.github/workflows/hq-deploy-git.yml@1.0.11
```

All shared workflows in a given release share the same tag — `hq-deploy-git.yml`, `hq-deploy-zip.yml`, and `hq-rollback.yml` are all tagged together on each release.

### Releasing a New Version

```bash
# Tag the new version
git tag 1.0.12
git push origin 1.0.12
```

Then update the version reference in each caller repo's workflow files from the old tag to the new one. Repos continue to use the old tag until their workflows are updated — there is no automatic inheritance.

### Current Version

The current shared workflow version is `1.0.11`. All repo-level caller workflows should reference `@1.0.11`.

---

## 8. Troubleshooting

### HQ_PACKAGE or HQ_ENVIRONMENTS not configured

```
Error: HQ_PACKAGE is not configured on this repository.
Error: HQ_ENVIRONMENTS is not configured on this repository.
```

**Fix:** Repository → Settings → Secrets and variables → Actions → Variables tab → New repository variable

| Variable | Value |
|---|---|
| `HQ_PACKAGE` | Package name matching a key in `/data/hq/config.json` e.g. `my-package` |
| `HQ_ENVIRONMENTS` | JSON array of environment names e.g. `["env-dev","env-staging","env-prod"]` |

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
  env-dev  [yaml_only]  In HQ_ENVIRONMENTS but NOT in config.json...
```

**Fix options:**
- Remove `env-dev` from `HQ_ENVIRONMENTS` (Repository → Settings → Variables), or
- Add an `env-dev` location for this package in `config.json` and run `hq init {package}` on the server

Also update the `options:` list in the manual deploy and rollback workflow files to match.

### HMAC verification failed (403)

```
HMAC verification failed (HTTP 403).
```

`ORG__HQ_HMAC` does not match `DEPLOY_HMAC_SECRET` on the server.

**Fix:** Verify both values are identical:
- Server: `cat /data/domains/api.bemidjistate.edu/hq/config/.env`
- GitHub: BemidjiState → Settings → Secrets and variables → Actions → Organisation secrets → `ORG__HQ_HMAC`

### Deployment confirmation timed out

```
Warning: Deployment confirmation timed out after 60 seconds.
The deployment job was accepted by the server. Outcome is unknown.
```

The deployment was queued successfully but the poll could not confirm completion within the timeout window. The deployment may have succeeded.

**Fix:** Check the deploy log on the server:

```bash
hq status {package}
tail -50 /data/domains/api.bemidjistate.edu/hq/logs/deploy.log
```

No automatic rollback is triggered on a timeout — only on a confirmed failure.

### Check endpoint unreachable during polling

```
Warning: Could not confirm deployment outcome — check endpoint unreachable (HTTP 502).
The deployment job was accepted by the server. Outcome is unknown.
```

The deployment may have succeeded — no automatic rollback is triggered.

**Fix:** Verify manually:

```bash
hq status {package}
hq health
tail -20 /data/domains/api.bemidjistate.edu/hq/logs/deploy.log
```

### Zip asset not found for release tag

```
Error: No zip asset found in release '2.4.1-rc'.
```

The release exists but has no `.zip` asset attached, or the asset has a content type other than `application/zip`.

**Fix:** Verify the release at `https://github.com/BemidjiState/{repo}/releases/tag/{tag}` has a zip file attached. The build workflow for this package must complete successfully before a deployment can be triggered.

---

## 9. Shared Workflow Reference

### `hq-deploy-git.yml`

Handles all deployment logic for git-delivery packages. Called by `deploy-auto.yml` and `deploy-manual.yml`.

**Inputs:**

| Input | Required | Default | Description |
|---|---|---|---|
| `package` | Yes | — | Package name from `HQ_PACKAGE` |
| `environment` | Yes | — | Target environment name |
| `ref` | Yes | — | Branch, tag, or commit SHA |
| `yaml_environments` | Yes | — | JSON array from `HQ_ENVIRONMENTS` |
| `poll_for_result` | No | `false` | Poll for deployment confirmation after queuing |

**Secrets:** `hmac_secret` — pass `${{ secrets.ORG__HQ_HMAC }}`

**Jobs:** `validate` → `deploy` → `rollback-on-failure` (on confirmed failure, non-dev environments only)

**Poll timeout:** 60 seconds, 10 second interval. Timeout exits as a warning — no rollback triggered. Rollback only fires on a confirmed deploy webhook failure.

---

### `hq-deploy-zip.yml`

Handles all deployment logic for zip-delivery packages. Called by `deploy-zip-auto.yml`, `deploy-zip-manual.yml`, and `deploy-zip-feature.yml`.

**Inputs:**

| Input | Required | Default | Description |
|---|---|---|---|
| `package` | Yes | — | Package name from `HQ_PACKAGE` |
| `environment` | Yes | — | Target environment name |
| `ref` | Yes | — | Release tag to deploy e.g. `2.4.1-rc` or `2.4.1` |
| `yaml_environments` | Yes | — | JSON array from `HQ_ENVIRONMENTS` |
| `asset_id` | No | `''` | GitHub Release asset ID. If omitted, resolved from `ref` via the GitHub API. |
| `poll_for_result` | No | `false` | Poll for deployment confirmation after queuing |

**Outputs:** `previous_ref`, `previous_sha` — the ref and SHA active before this deployment. Used by callers for coordinated rollback across multiple environments.

**Secrets:** `hmac_secret` — pass `${{ secrets.ORG__HQ_HMAC }}`

**Jobs:** `validate` → `deploy` → `rollback-on-failure` (on confirmed failure, non-dev environments only)

**Poll timeout:** 90 seconds, 10 second interval. Timeout exits as a warning — no rollback triggered. Rollback only fires on a confirmed deploy webhook failure.

---

### `hq-rollback.yml`

Handles all rollback logic. Called by `rollback.yml`. Works for both git-delivery and zip-delivery packages.

**Inputs:**

| Input | Required | Description |
|---|---|---|
| `package` | Yes | Package name from `HQ_PACKAGE` |
| `environment` | Yes | Environment to roll back |
| `ref` | Yes | Ref to roll back to — branch, tag, or commit SHA |
| `yaml_environments` | Yes | JSON array from `HQ_ENVIRONMENTS` |

**Secrets:** `hmac_secret` — pass `${{ secrets.ORG__HQ_HMAC }}`

**Jobs:** `validate` → `rollback`

---

### `branch-protection-warning.yml`

Enforces that merges to a primary branch only come from the `release` branch.

**Inputs:**

| Input | Required | Default | Description |
|---|---|---|---|
| `primary_branch` | No | `main` | The branch to protect |

---

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