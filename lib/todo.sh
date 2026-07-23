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

# Fields beyond the default columns (size, CI, merge status, Jira) cost real
# time: each one gh pr list --json doesn't get from the search response
# directly requires an extra per-PR lookup under the hood. Only ask for them
# under --long, where they're actually shown. createdAt is always fetched
# (cheap, part of the base search response) since it drives sorting.
fields="number,title,author,reviews,reviewRequests,url,updatedAt,createdAt,headRefOid"
if [ "$long" = true ]; then
  fields="$fields,headRefName,changedFiles,additions,deletions,mergeable,mergeStateStatus,statusCheckRollup"
fi

# involves:@me / review-requested only match *direct* requests — a PR where
# only a team you belong to was requested (not you by name) is invisible to it.
# GitHub's team-review-requested:<org>/<team> qualifier catches those, so we run
# one extra search per team you're on and merge the results. Needs read:org
# (same scope as team expansion); if that fails we fall back to involves:@me
# alone, matching the pre-team behavior.
my_teams=$(my_team_slugs "$me")

# sort:created-asc asks gh/GitHub's search API to return oldest-first, so the
# final display order (see todo.jq's sort_by(.createdAt)) matches what the API
# already gave us for any single search — merging multiple team searches still
# needs that final sort_by to stay correct across the combined set.
searches=("involves:@me is:open -is:draft -author:@me sort:created-asc")
while IFS= read -r team; do
  [ -n "$team" ] || continue
  searches+=("team-review-requested:$ORG/$team is:open -is:draft -author:@me sort:created-asc")
done <<<"$my_teams"

prs='[]'
for search in "${searches[@]}"; do
  batch=$(gh pr list --repo "$REPO" --search "$search" --json "$fields")
  prs=$(printf '%s\n%s' "$prs" "$batch" | jq -s 'add | unique_by(.number)')
done

# Open review-thread stats aren't exposed by `gh pr list`/`pr view --json`
# (no reviewThreads field), so fetch per PR via GraphQL — see fetch_review_threads
# in common.sh. A bit slower than prd if you have a lot of PRs to triage, but
# negligible for a normal workload.
threads=$(fetch_review_threads "$prs" "$me")

# Resolve each requested team to its member logins so todo.jq can tell whether
# $me is covered by a team request (same map prd.jq uses). reviewRequests
# serializes team slugs as "org/slug"; the API path needs the bare slug.
members='{}'
for slug in $(jq -r '[.[].reviewRequests[]? | .slug // empty | split("/") | last] | unique | .[]' <<<"$prs"); do
  m=$(team_members "$slug")
  members=$(jq --arg t "$slug" --argjson m "$m" '. + {($t): $m}' <<<"$members")
done

# Union of the current user's team memberships, for splitting APPROVALS into
# total vs. teammate counts. Reuses $my_teams (already fetched above) instead
# of calling my_team_logins, which would re-run my_team_slugs a second time.
my_logins=$(team_logins_for_slugs "$my_teams")

jq -rn -L "$dir" \
  --arg me "$me" \
  --argjson threads "$threads" \
  --argjson teamMembers "$members" \
  --argjson teamLogins "$my_logins" \
  --argjson approvalThreshold "${APPROVAL_THRESHOLD:-1}" \
  --arg jiraBase "${JIRA_BASE_URL:-}" \
  --arg jiraPattern "$ticket_pattern" \
  --argjson long "$long" \
  -f "$dir/todo.jq" <<<"$prs"
