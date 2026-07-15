#!/usr/bin/env bash
# gh pr-tools todo — open PRs where you're a pending reviewer.
set -euo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$dir/common.sh"
load_config

long=false
while [ $# -gt 0 ]; do
  case "$1" in
    --long|-l) long=true; shift ;;
    *) echo "gh pr-tools todo: unknown option '$1' (supported: --long)" >&2; exit 1 ;;
  esac
done

me="${GH_USERNAME:-$(gh api user --jq .login)}"
ticket_pattern="${JIRA_PREFIX:-[A-Za-z]+}-[0-9]+"
fields="number,title,author,reviewDecision,reviews,reviewRequests,headRefName,url,changedFiles,additions,deletions,updatedAt,createdAt,mergeable,mergeStateStatus,statusCheckRollup"

# involves:@me covers author/assignee/mentions/commenter/review-requested in
# one search — broader than plain "review-requested" (which drops you as
# soon as you submit any review, even a comment-only one). todo.jq's
# stillNeedsMe filters back down to PRs where you're an actual reviewer.
gh pr list --repo "$REPO" --search "involves:@me is:open -is:draft -author:@me" \
  --json "$fields" \
  | jq -rn -L "$dir" \
      --arg me "$me" \
      --arg jiraBase "${JIRA_BASE_URL:-}" \
      --arg jiraPattern "$ticket_pattern" \
      --argjson long "$long" \
      -f "$dir/todo.jq"
