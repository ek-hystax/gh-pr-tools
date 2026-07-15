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

ticket_pattern="${JIRA_PREFIX:-[A-Za-z]+}-[0-9]+"

prs=$(gh pr list --repo "$REPO" --search "author:@me is:open -is:draft" \
  --json number,title,author,reviewDecision,reviews,headRefName,url,changedFiles,additions,deletions,updatedAt,createdAt,mergeable,mergeStateStatus,statusCheckRollup)

# Unresolved review-comment counts aren't exposed by `gh pr list`/`pr view --json`
# (no reviewThreads field), so fetch per PR via GraphQL. Built as a
# {"<number>": count} map passed into jq via --argjson.
owner="${REPO%%/*}"
repo_name="${REPO##*/}"
unresolved='{}'
for number in $(jq -r '.[].number' <<<"$prs"); do
  # A failed/rate-limited lookup for one PR must not abort the whole command —
  # fall back to 0 (rendered as "-") and keep going.
  count=$(gh api graphql -f query='
    query($owner:String!,$repo:String!,$number:Int!){
      repository(owner:$owner,name:$repo){
        pullRequest(number:$number){
          reviewThreads(first:100){ nodes { isResolved } }
        }
      }
    }' -f owner="$owner" -f repo="$repo_name" -F number="$number" \
    --jq '[.data.repository.pullRequest.reviewThreads.nodes[]? | select(.isResolved | not)] | length' 2>/dev/null) || count=0
  [[ "$count" =~ ^[0-9]+$ ]] || count=0
  unresolved=$(jq --arg n "$number" --argjson c "$count" '. + {($n): $c}' <<<"$unresolved")
done

jq -rn -L "$dir" \
  --argjson unresolved "$unresolved" \
  --arg jiraBase "${JIRA_BASE_URL:-}" \
  --arg jiraPattern "$ticket_pattern" \
  --argjson long "$long" \
  -f "$dir/mine.jq" <<<"$prs"
