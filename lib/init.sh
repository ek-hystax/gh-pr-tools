#!/usr/bin/env bash
# gh pr-tools init — one-time (or re-runnable) setup for this machine.
set -euo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$dir/common.sh"

mkdir -p "$config_dir"

default_repo=""
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  default_repo=$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)
fi

read -rp "GitHub repo (owner/name)${default_repo:+ [$default_repo]}: " repo
repo="${repo:-$default_repo}"
[ -n "$repo" ] || { echo "gh pr-tools: repo is required" >&2; exit 1; }

default_org="${repo%%/*}"
read -rp "GitHub org for team-review lookups [$default_org]: " org
org="${org:-$default_org}"

read -rp "Jira ticket prefix, e.g. KF (blank = match any PROJECT-123 style ticket): " prefix
read -rp "Jira base browse URL, e.g. https://yourorg.atlassian.net/browse (blank = no Jira links): " jira_base

cat > "$config_file" <<EOF
REPO="$repo"
ORG="$org"
JIRA_PREFIX="$prefix"
JIRA_BASE_URL="$jira_base"
EOF

echo "Wrote $config_file"
echo "Next: gh pr-tools tg add <github-login> <telegram-handle>   (optional, per-person)"
