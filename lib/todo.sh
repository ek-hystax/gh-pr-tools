#!/usr/bin/env bash
# gh pr-tools todo — open PRs where you're a pending reviewer.
set -euo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$dir/common.sh"
load_config

me=$(gh api user --jq .login)
ticket_pattern="${JIRA_PREFIX:-[A-Za-z]+}-[0-9]+"

gh pr list --repo "$REPO" --search "review-requested:@me is:open -is:draft" \
  --json number,title,author,reviewDecision,reviews,headRefName,url,changedFiles,additions,deletions,updatedAt,createdAt,mergeable,mergeStateStatus,statusCheckRollup \
  | jq -rn \
      --arg me "$me" \
      --arg jiraBase "${JIRA_BASE_URL:-}" \
      --arg jiraPattern "$ticket_pattern" \
      -f "$dir/todo.jq"
