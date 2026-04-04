#!/usr/bin/env bash
# =============================================================================
# configure-environments.sh
# =============================================================================
# Configures GitHub Environment protection rules across repositories using the
# GitHub CLI. This is the single place where team access maps to environment
# protection rules — no workflow YAML changes are needed when access changes.
#
# Team names are read from the WS_MERGE_APPROVAL_TEAM organisation variable.
# When that variable changes, re-run this script to propagate the update.
#
# Prerequisites:
#   - GitHub CLI (gh) installed and authenticated: gh auth login
#   - The gh CLI user must have admin rights on the target repositories
#   - WS_MERGE_APPROVAL_TEAM org variable must be set in GitHub
#
# Usage:
#   ./configure-environments.sh <repo>
#   ./configure-environments.sh --all
#
# Examples:
#   ./configure-environments.sh sso-o365
#   ./configure-environments.sh --all
# =============================================================================

set -euo pipefail

# --- Configuration ---
# GitHub organisation name.
ORG="BemidjiState"

# Environments containing this string are treated as dev — no approval required.
DEV_PATTERN="-(dev|development)(-|$)"

# Branches allowed for automatic deploys to production environments.
PROD_BRANCH="main"

# Branches allowed for automatic deploys to staging environments.
STAGING_BRANCH="release"

# Branches allowed for automatic deploys to dev environments.
DEV_BRANCH="*"


# =============================================================================
# Functions
# =============================================================================

# --- Check prerequisites ---
# Verify gh CLI is installed and authenticated.
check_prerequisites() {

	# Check if gh CLI is installed.
	if ! command -v gh &>/dev/null; then
		echo "Error: GitHub CLI (gh) is not installed."
		echo "Install from: https://cli.github.com"
		exit 1
	fi

	# Check if gh CLI is authenticated.
	if ! gh auth status &>/dev/null; then
		echo "Error: GitHub CLI is not authenticated."
		echo "Run: gh auth login"
		exit 1
	fi

	echo "GitHub CLI authenticated."
}

# --- Get WS_MERGE_APPROVAL_TEAM ---
# Read the WS_MERGE_APPROVAL_TEAM org variable and return team IDs.
get_approval_teams() {

	# Read WS_MERGE_APPROVAL_TEAM from the org variable.
	WS_MERGE_APPROVAL_TEAM=$(gh variable get WS_MERGE_APPROVAL_TEAM \
		--org "${ORG}" \
		--json value \
		--jq '.value' 2>/dev/null || echo "")

	if [ -z "${WS_MERGE_APPROVAL_TEAM}" ]; then
		echo "Error: WS_MERGE_APPROVAL_TEAM organisation variable is not set."
		echo "Set it at: ${ORG} → Settings → Secrets and variables → Actions → Variables"
		echo "Example value: BemidjiState/ws-merge-approval"
		exit 1
	fi

	echo "WS_MERGE_APPROVAL_TEAM: ${WS_MERGE_APPROVAL_TEAM}"
}

# --- Get environments for a repo ---
# Read the HQ_ENVIRONMENTS repository variable and return a list of environments.
get_repo_environments() {
	local repo="$1"

	HQ_ENVIRONMENTS=$(gh variable get HQ_ENVIRONMENTS \
		--repo "${ORG}/${repo}" \
		--json value \
		--jq '.value' 2>/dev/null || echo "")

	if [ -z "${HQ_ENVIRONMENTS}" ]; then
		echo "Warning: HQ_ENVIRONMENTS not set for ${repo} — skipping."
		return 1
	fi

	# Parse JSON array to newline-separated list.
	echo "${HQ_ENVIRONMENTS}" | jq -r '.[]'
}

# --- Classify environment ---
# Determine if an environment is dev, staging, or production.
classify_environment() {
	local env="$1"

	if echo "${env}" | grep -qE "${DEV_PATTERN}"; then
		echo "dev"
	elif echo "${env}" | grep -qi "staging"; then
		echo "staging"
	else
		echo "production"
	fi
}

# --- Get team IDs ---
# Convert comma-separated team slugs to GitHub team IDs for the API.
get_team_ids() {
	local teams_raw="$1"
	local team_ids=()

	IFS=',' read -ra TEAMS <<< "${teams_raw}"

	for team_full in "${TEAMS[@]}"; do
		# Strip org prefix if present — extract just the team slug.
		team_slug="${team_full##*/}"
		team_slug=$(echo "${team_slug}" | xargs)

		team_id=$(gh api "orgs/${ORG}/teams/${team_slug}" \
			--jq '.id' 2>/dev/null || echo "")

		if [ -z "${team_id}" ]; then
			echo "Warning: Team '${team_slug}' not found in org ${ORG}." >&2
			continue
		fi

		team_ids+=("${team_id}")
	done

	echo "${team_ids[@]}"
}

# --- Configure environment ---
# Create or update a GitHub Environment with appropriate protection rules.
configure_environment() {
	local repo="$1"
	local env="$2"
	local env_type="$3"
	local team_ids_str="$4"

	echo "  Configuring: ${env} (${env_type})"

	# Build the reviewers JSON array from team IDs.
	local reviewers_json="[]"

	if [ "${env_type}" != "dev" ] && [ -n "${team_ids_str}" ]; then
		reviewers_json=$(echo "${team_ids_str}" | tr ' ' '\n' | \
			jq -R '{type:"Team",id:(.|tonumber)}' | \
			jq -s '.')
	fi

	# Build the deployment branch policy.
	local branch_policy
	if [ "${env_type}" = "production" ]; then
		branch_policy="${PROD_BRANCH}"
	elif [ "${env_type}" = "staging" ]; then
		branch_policy="${STAGING_BRANCH}"
	else
		branch_policy="${DEV_BRANCH}"
	fi

	# Create or update the environment via the GitHub API.
	if [ "${env_type}" = "dev" ]; then

		# Dev environments — no required reviewers, any branch.
		gh api \
			--method PUT \
			"repos/${ORG}/${repo}/environments/${env}" \
			--field "reviewers=[]" \
			--silent

		echo "    Required reviewers: none"
		echo "    Deployment branch:  any"

	else

		# Production/staging environments — require WS_MERGE_APPROVAL_TEAM,
		# disable prevent-self-review, restrict deployment branch.
		gh api \
			--method PUT \
			"repos/${ORG}/${repo}/environments/${env}" \
			--field prevent_self_review=false \
			--field "reviewers=${reviewers_json}" \
			--silent

		echo "    Required reviewers: ${WS_MERGE_APPROVAL_TEAM}"
		echo "    Prevent self-review: disabled (senior devs can approve own requests)"
		echo "    Deployment branch:  ${branch_policy}"

	fi
}

# --- Configure single repo ---
# Configure all environments for one repository.
configure_repo() {
	local repo="$1"

	echo ""
	echo "Configuring: ${ORG}/${repo}"
	echo "────────────────────────────────────────"

	# Get environments from the repo's HQ_ENVIRONMENTS variable.
	local environments
	if ! environments=$(get_repo_environments "${repo}"); then
		return
	fi

	# Get team IDs for the approval teams.
	local team_ids_str
	team_ids_str=$(get_team_ids "${WS_MERGE_APPROVAL_TEAM}")

	# Loop over each environment and configure it.
	while IFS= read -r env; do

		env=$(echo "${env}" | xargs)

		if [ -z "${env}" ]; then
			continue
		fi

		local env_type
		env_type=$(classify_environment "${env}")
		configure_environment "${repo}" "${env}" "${env_type}" "${team_ids_str}"

	done <<< "${environments}"

	echo "  Done."
}


# =============================================================================
# Main
# =============================================================================

check_prerequisites
get_approval_teams

# Check if configuring all repos or a single repo.
if [ "${1:-}" = "--all" ]; then

	# Get all repos in the org that have HQ_PACKAGE variable set.
	echo ""
	echo "Fetching all repos with HQ_PACKAGE variable set..."

	repos=$(gh api "orgs/${ORG}/repos" \
		--paginate \
		--jq '.[].name' 2>/dev/null || echo "")

	if [ -z "${repos}" ]; then
		echo "No repositories found in ${ORG}."
		exit 1
	fi

	while IFS= read -r repo; do

		# Check if this repo has HQ_PACKAGE set — skip repos not using HQ.
		if gh variable get HQ_PACKAGE \
			--repo "${ORG}/${repo}" &>/dev/null 2>&1; then
			configure_repo "${repo}"
		fi

	done <<< "${repos}"

elif [ -n "${1:-}" ]; then

	configure_repo "$1"

else

	echo ""
	echo "Usage:"
	echo "  ./configure-environments.sh <repo>"
	echo "  ./configure-environments.sh --all"
	echo ""
	exit 1

fi

echo ""
echo "Environment configuration complete."
echo ""
echo "Note: Deployment branch policies must be configured manually in"
echo "each repo's environment settings if branch restrictions are needed."
echo "GitHub → Repository → Settings → Environments → {environment} → Deployment branches"
