#!/usr/bin/env bash
# gh pr-tools init — create or update a named profile for this machine.
set -euo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$dir/common.sh"

mkdir -p "$profiles_dir"

default_repo=$(cwd_repo 2>/dev/null || true)

default_name="default"
if [ -n "$default_repo" ]; then
  default_name=$(suggest_profile_name "${default_repo##*/}")
fi

read -rp "Profile name [$default_name]: " name
name="${name:-$default_name}"
validate_profile_name "$name"

read -rp "GitHub repo (owner/name)${default_repo:+ [$default_repo]}: " repo
repo="${repo:-$default_repo}"
[ -n "$repo" ] || { echo "gh pr-tools: repo is required" >&2; exit 1; }

assert_repo_unique "$name" "$repo"

default_org="${repo%%/*}"
read -rp "GitHub org for team-review lookups [$default_org]: " org
org="${org:-$default_org}"

default_username=$(gh api user --jq .login 2>/dev/null || true)
read -rp "Your GitHub username${default_username:+ [$default_username]}: " username
username="${username:-$default_username}"
[ -n "$username" ] || { echo "gh pr-tools: GitHub username is required" >&2; exit 1; }

read -rp "Jira ticket prefix, e.g. KF (blank = match any PROJECT-123 style ticket): " prefix
read -rp "Jira base browse URL, e.g. https://yourorg.atlassian.net/browse (blank = no Jira links): " jira_base

path=$(profile_path "$name")
{
  printf 'REPO=%q\n' "$repo"
  printf 'ORG=%q\n' "$org"
  printf 'GH_USERNAME=%q\n' "$username"
  printf 'JIRA_PREFIX=%q\n' "$prefix"
  printf 'JIRA_BASE_URL=%q\n' "$jira_base"
} > "$path"

echo "Wrote $path"
echo "Next: gh pr-tools tg add <github-login> <telegram-handle>   (optional, per-person)"
