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

# Fields beyond the default columns (decision, size, CI, merge status, age,
# Jira) cost real time: each one gh pr list --json doesn't get from the search
# response directly requires an extra per-PR lookup under the hood. Only ask
# for them under --long, where they're actually shown.
fields="number,title,author,reviews,reviewRequests,url,updatedAt"
if [ "$long" = true ]; then
  fields="$fields,reviewDecision,headRefName,changedFiles,additions,deletions,createdAt,mergeable,mergeStateStatus,statusCheckRollup"
fi

# involves:@me covers author/assignee/mentions/commenter/review-requested in
# one search — broader than plain "review-requested" (which drops you as
# soon as you submit any review, even a comment-only one). todo.jq's
# stillNeedsMe filters back down to PRs where you're an actual reviewer.
prs=$(gh pr list --repo "$REPO" --search "involves:@me is:open -is:draft -author:@me" \
  --json "$fields")

# Unresolved review-comment counts aren't exposed by `gh pr list`/`pr view --json`
# (no reviewThreads field), so fetch per PR via GraphQL — see fetch_unresolved_comments
# in common.sh. A bit slower than prd if you have a lot of PRs to triage, but
# negligible for a normal workload.
unresolved=$(fetch_unresolved_comments "$prs" "$me")

jq -rn -L "$dir" \
  --arg me "$me" \
  --argjson unresolved "$unresolved" \
  --arg jiraBase "${JIRA_BASE_URL:-}" \
  --arg jiraPattern "$ticket_pattern" \
  --argjson long "$long" \
  -f "$dir/todo.jq" <<<"$prs"
