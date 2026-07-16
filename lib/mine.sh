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

# Fields beyond the default columns (size, merge status, age) cost real time:
# each one gh pr list --json doesn't get from the search response directly
# requires an extra per-PR lookup under the hood. Only ask for them under
# --long, where they're actually shown.
fields="number,title,author,reviewDecision,reviews,headRefName,url,updatedAt,statusCheckRollup"
if [ "$long" = true ]; then
  fields="$fields,changedFiles,additions,deletions,createdAt,mergeable,mergeStateStatus"
fi

prs=$(gh pr list --repo "$REPO" --search "author:@me is:open -is:draft" --json "$fields")

# Unresolved review-comment counts aren't exposed by `gh pr list`/`pr view --json`
# (no reviewThreads field), so fetch per PR via GraphQL — see fetch_unresolved_comments
# in common.sh. A bit slower than todo/prd if you have a lot of open PRs, but
# negligible for a normal workload.
unresolved=$(fetch_unresolved_comments "$prs" "$me")

jq -rn -L "$dir" \
  --argjson unresolved "$unresolved" \
  --arg jiraBase "${JIRA_BASE_URL:-}" \
  --arg jiraPattern "$ticket_pattern" \
  --argjson long "$long" \
  -f "$dir/mine.jq" <<<"$prs"
