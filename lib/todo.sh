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

# Every fetch below is a network round trip, so independent ones run as
# background jobs writing into $tmp. `wait <pid>` surfaces each job's exit
# status, so a failed search still aborts under set -e.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# sort:created-asc asks gh/GitHub's search API to return oldest-first, so the
# final display order (see todo.jq's sort_by(.createdAt)) matches what the API
# already gave us for any single search — merging multiple team searches still
# needs that final sort_by to stay correct across the combined set.
#
# This primary search filters on server-side @me qualifiers only, so it needs
# neither the username nor the team lookup below — launch it first and let it
# overlap with both.
gh pr list --repo "$REPO" --search "involves:@me is:open -is:draft -author:@me sort:created-asc" --json "$fields" > "$tmp/search-involves" &
search_pids=($!)

me="${GH_USERNAME:-$(gh api user --jq .login)}"

# involves:@me / review-requested only match *direct* requests — a PR where
# only a team you belong to was requested (not you by name) is invisible to it.
# GitHub's team-review-requested:<org>/<team> qualifier catches those, so we run
# one extra search per team you're on and merge the results. Needs read:org
# (same scope as team expansion); if that fails we fall back to involves:@me
# alone, matching the pre-team behavior.
# One GraphQL call returns every team you're on together with its member
# logins — the slugs drive the extra team-review-requested searches below,
# and the members feed the APPROVALS teammate split further down.
my_teams_json=$(my_teams_with_members "$me")

i=0
while IFS= read -r team; do
  [ -n "$team" ] || continue
  gh pr list --repo "$REPO" --search "team-review-requested:$ORG/$team is:open -is:draft -author:@me sort:created-asc" --json "$fields" > "$tmp/search-team$i" &
  search_pids+=($!)
  i=$((i + 1))
done <<<"$(jq -r '.slugs[]' <<<"$my_teams_json")"

for pid in "${search_pids[@]}"; do wait "$pid"; done
prs=$(cat "$tmp"/search-* | jq -s 'add | unique_by(.number)')

# Open review-thread and viewed-file stats aren't exposed by `gh pr list`/
# `pr view --json`, so fetch via GraphQL — one batched call for both, see
# fetch_pr_review_state in common.sh. A bit slower than prd if you have a lot
# of PRs to triage, but negligible for a normal workload.
#
# Both this and the requested-team member lookup below only need $prs, so
# they run concurrently.
fetch_pr_review_state "$prs" "$me" > "$tmp/review-state" &
review_pid=$!

# Resolve each requested team to its member logins so todo.jq can tell whether
# $me is covered by a team request (same map prd.jq uses). reviewRequests
# serializes team slugs as "org/slug"; the lookup needs the bare slug. All
# requested teams are fetched in one aliased call — see teams_members_map.
teams_members_map "$(jq -r '[.[].reviewRequests[]? | .slug // empty | split("/") | last] | unique | .[]' <<<"$prs")" > "$tmp/members" &
members_pid=$!

wait "$review_pid"
threads=$(jq '.threads' "$tmp/review-state")
viewed=$(jq '.viewed' "$tmp/review-state")
wait "$members_pid"
members=$(cat "$tmp/members")

# Union of the current user's team memberships, for splitting APPROVALS into
# total vs. teammate counts. Reuses $my_teams_json (already fetched above)
# instead of calling my_team_logins, which would re-run the teams query.
my_logins=$(jq '[.members[][]] | unique' <<<"$my_teams_json")

jq -rn -L "$dir" \
  --arg me "$me" \
  --argjson threads "$threads" \
  --argjson viewed "$viewed" \
  --argjson teamMembers "$members" \
  --argjson teamLogins "$my_logins" \
  --argjson approvalThreshold "${APPROVAL_THRESHOLD:-1}" \
  --arg jiraBase "${JIRA_BASE_URL:-}" \
  --arg jiraPattern "$ticket_pattern" \
  --argjson long "$long" \
  -f "$dir/todo.jq" <<<"$prs"
