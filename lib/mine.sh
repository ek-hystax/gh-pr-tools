#!/usr/bin/env bash
# gh pr-tools mine — open PRs you authored.
set -euo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$dir/common.sh"
load_config

long=false
while [ $# -gt 0 ]; do
  case "$1" in
    --long|-l) long=true; shift ;;
    *) echo "gh pr-tools mine: unknown option '$1' (supported: --long)" >&2; exit 1 ;;
  esac
done

me="${GH_USERNAME:-$(gh api user --jq .login)}"
ticket_pattern="${JIRA_PREFIX:-[A-Za-z]+}-[0-9]+"

# Fields beyond the default columns (size, merge status) cost real time: each
# one gh pr list --json doesn't get from the search response directly requires
# an extra per-PR lookup under the hood. Only ask for them under --long, where
# they're actually shown. createdAt is always fetched (cheap, part of the base
# search response) since it drives sorting.
fields="number,title,author,reviewDecision,reviews,headRefName,url,updatedAt,createdAt,statusCheckRollup"
if [ "$long" = true ]; then
  fields="$fields,changedFiles,additions,deletions,mergeable,mergeStateStatus"
fi

# sort:created-asc asks gh/GitHub's search API to return oldest-first, matching
# mine.jq's sort_by(.createdAt) so the stalest PRs surface first.
prs=$(gh pr list --repo "$REPO" --search "author:@me is:open -is:draft sort:created-asc" --json "$fields")

# Open review-thread stats aren't exposed by `gh pr list`/`pr view --json`
# (no reviewThreads field), so fetch per PR via GraphQL — see fetch_review_threads
# in common.sh. A bit slower than todo/prd if you have a lot of open PRs, but
# negligible for a normal workload.
threads=$(fetch_review_threads "$prs" "$me")

jq -rn -L "$dir" \
  --argjson threads "$threads" \
  --arg jiraBase "${JIRA_BASE_URL:-}" \
  --arg jiraPattern "$ticket_pattern" \
  --argjson long "$long" \
  -f "$dir/mine.jq" <<<"$prs"
