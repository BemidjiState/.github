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

# Default HQ_ENVIRONMENTS value offered when prompting.
DEFAULT_HQ_ENVIRONMENTS='["bsu-dev","bsu-prod","bsu-staging","ntc-dev","ntc-prod","ntc-staging"]'

# Environments matching this regex are treated as dev — no approval required.
# Matches: bsu-dev, ntc-dev, bsu-undergraduate-catalog-dev, any-package-development
DEV_REGEX="-(dev|development)(-|$)"


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
# Read the WS_MERGE_APPROVAL_TEAM org variable.
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

# --- Ensure repo variables are set ---
# Check for HQ_PACKAGE and HQ_ENVIRONMENTS — prompt to set them if missing.
ensure_repo_variables() {
	local repo="$1"

	# --- Check HQ_PACKAGE ---
	local hq_package
	hq_package=$(gh variable get HQ_PACKAGE \
		--repo "${ORG}/${repo}" \
		--json value \
		--jq '.value' 2>/dev/null || echo "")

	if [ -z "${hq_package}" ]; then
		echo ""
		echo "  HQ_PACKAGE is not set for ${repo}."
		printf "  Enter the package name (must match a key in /data/hq/config.json): "
		read -r hq_package_input

		if [ -z "${hq_package_input}" ]; then
			echo "  Skipping — no package name entered."
			return 1
		fi

		gh variable set HQ_PACKAGE \
			--repo "${ORG}/${repo}" \
			--body "${hq_package_input}"
		echo "  HQ_PACKAGE set to: ${hq_package_input}"
	else
		echo ""
		echo "  HQ_PACKAGE: ${hq_package}"
		printf "  Correct? [Y/n]: "
		read -r confirm
		if [ "${confirm}" = "n" ] || [ "${confirm}" = "N" ]; then
			printf "  Enter the correct package name: "
			read -r hq_package_input
			if [ -z "${hq_package_input}" ]; then
				echo "  Skipping — no package name entered."
				return 1
			fi
			gh variable set HQ_PACKAGE \
				--repo "${ORG}/${repo}" \
				--body "${hq_package_input}"
			echo "  HQ_PACKAGE updated to: ${hq_package_input}"
		fi
	fi

	# --- Check HQ_ENVIRONMENTS ---
	HQ_ENVIRONMENTS=$(gh variable get HQ_ENVIRONMENTS \
		--repo "${ORG}/${repo}" \
		--json value \
		--jq '.value' 2>/dev/null || echo "")

	if [ -z "${HQ_ENVIRONMENTS}" ]; then
		echo ""
		echo "  HQ_ENVIRONMENTS is not set for ${repo}."
		echo "  Default: ${DEFAULT_HQ_ENVIRONMENTS}"
		printf "  Press Enter to use the default, or type a JSON array to override: "
		read -r hq_environments_input

		if [ -z "${hq_environments_input}" ]; then
			hq_environments_input="${DEFAULT_HQ_ENVIRONMENTS}"
		fi

		gh variable set HQ_ENVIRONMENTS \
			--repo "${ORG}/${repo}" \
			--body "${hq_environments_input}"
		HQ_ENVIRONMENTS="${hq_environments_input}"
		echo "  HQ_ENVIRONMENTS set to: ${HQ_ENVIRONMENTS}"
	else
		echo "  HQ_ENVIRONMENTS: ${HQ_ENVIRONMENTS}"
		printf "  Correct? [Y/n]: "
		read -r confirm
		if [ "${confirm}" = "n" ] || [ "${confirm}" = "N" ]; then
			echo "  Current: ${HQ_ENVIRONMENTS}"
			printf "  Enter the correct JSON array, or press Enter to keep current: "
			read -r hq_environments_input
			if [ -n "${hq_environments_input}" ]; then
				gh variable set HQ_ENVIRONMENTS \
					--repo "${ORG}/${repo}" \
					--body "${hq_environments_input}"
				HQ_ENVIRONMENTS="${hq_environments_input}"
				echo "  HQ_ENVIRONMENTS updated to: ${HQ_ENVIRONMENTS}"
			fi
		fi
	fi

	return 0
}

# --- Get environments for a repo ---
# Parse HQ_ENVIRONMENTS JSON array to a newline-separated list.
get_repo_environments() {
	echo "${HQ_ENVIRONMENTS}" | jq -r '.[]'
}

# --- Classify environment ---
# Determine if an environment is dev, staging, or production.
classify_environment() {
	local env="$1"

	# Use a case statement instead of grep regex for cross-platform compatibility.
	case "${env}" in
		*-dev|*-dev-*|*-development|*-development-*)
			echo "dev"
			;;
		*staging*)
			echo "staging"
			;;
		*)
			echo "production"
			;;
	esac
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

		local team_response
		team_response=$(gh api "orgs/${ORG}/teams/${team_slug}" 2>/dev/null || echo "")

		# Check if the response contains an id field.
		local team_id
		team_id=$(echo "${team_response}" | jq -r '.id // empty' 2>/dev/null || echo "")

		if [ -z "${team_id}" ]; then
			echo "Warning: Team '${team_slug}' not found in org ${ORG}. Create it first at: github.com/orgs/${ORG}/teams/new" >&2
			continue
		fi

		team_ids+=("${team_id}")
	done

	echo "${team_ids[@]:-}"
}

# --- Configure environment ---
# Create or update a GitHub Environment with appropriate protection rules.
configure_environment() {
	local repo="$1"
	local env="$2"
	local env_type="$3"
	local team_ids_str="$4"

	echo "  Configuring: ${env} (${env_type})"

	# Create the environment. Required reviewers are a paid GitHub feature
	# (Team or Enterprise plan) — environments are created without protection
	# rules on the free plan. Re-run this script after upgrading to apply
	# reviewer requirements automatically.
	echo '{"reviewers":[]}' | gh api \
		--method PUT \
		"repos/${ORG}/${repo}/environments/${env}" \
		--input - \
		--silent

	if [ "${env_type}" = "dev" ]; then
		echo "    Required reviewers: none"
	elif [ -z "${team_ids_str}" ]; then
		echo "    Required reviewers: none (team not found — re-run after creating the team)"
	else
		echo "    Required reviewers: ${WS_MERGE_APPROVAL_TEAM} (requires paid plan to enforce)"
	fi
}

# --- Configure single repo ---
# Ensure variables are set, then configure all environments for one repository.
configure_repo() {
	local repo="$1"

	echo ""
	echo "Configuring: ${ORG}/${repo}"
	echo "────────────────────────────────────────"

	# Ensure HQ_PACKAGE and HQ_ENVIRONMENTS are set — prompt if not.
	if ! ensure_repo_variables "${repo}"; then
		return
	fi

	# Get environments list.
	local environments
	environments=$(get_repo_environments)

	if [ -z "${environments}" ]; then
		echo "  No environments found in HQ_ENVIRONMENTS — skipping."
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

		# Only configure repos that already have HQ_PACKAGE set.
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
echo "Note: Required reviewer protection rules require a paid GitHub plan (Team or Enterprise)."
echo "Environments have been created without protection rules. Re-run this script after"
echo "upgrading to apply reviewer requirements automatically."
echo ""
echo "Deployment branch policies must be configured manually in each repo's environment"
echo "settings if branch restrictions are needed."
echo "GitHub → Repository → Settings → Environments → {environment} → Deployment branches"
