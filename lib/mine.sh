#!/usr/bin/env bash
# gh pr-tools mine — open PRs you authored (or, with --include-assigned, are assigned to).
set -euo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$dir/common.sh"

long=false
short_links=false
short_labels=false
include_drafts=false
include_assigned=false
watch=false
watch_interval=5m
command_args=()
while [ $# -gt 0 ]; do
  case "$1" in
    --long|-l) long=true; command_args+=("$1"); shift ;;
    --short-links|-s) short_links=true; command_args+=("$1"); shift ;;
    --short-labels|-S) short_labels=true; command_args+=("$1"); shift ;;
    --include-drafts|-d) include_drafts=true; command_args+=("$1"); shift ;;
    --include-assigned|-a) include_assigned=true; command_args+=("$1"); shift ;;
    --watch|-w)
      watch=true
      if [ $# -gt 1 ] && [[ "$2" != -* ]]; then watch_interval="$2"; shift 2
      else shift
      fi
      ;;
    --watch=*|-w=*) watch=true; watch_interval="${1#*=}"; shift ;;
    *) echo "gh pr-tools mine: unknown option '$1' (supported: --long, --short-links, --short-labels, --include-drafts, --include-assigned, --watch[=INTERVAL])" >&2; exit 1 ;;
  esac
done

if [ "$watch" = true ]; then
  watch_seconds=$(watch_interval_seconds "$watch_interval") || {
    echo "gh pr-tools mine: invalid watch interval '$watch_interval' (expected e.g. 30s, 5m, or 1h)" >&2
    exit 1
  }
  watch_label="gh pr-tools mine"
  [ "${#command_args[@]}" -eq 0 ] || watch_label+=" ${command_args[*]}"
  refresh_command "$watch_seconds" "$watch_interval" "$watch_label" "$0" "${command_args[@]}"
fi

load_config

ticket_pattern="${JIRA_PREFIX:-[A-Za-z]+}-[0-9]+"

# Fields beyond the default columns (size, merge status) cost real time, even
# though gh resolves the whole --json set in a single GraphQL request per page.
# The cost is inside that one request: selections like mergeable and
# mergeStateStatus are computed per PR on GitHub's side, so asking for them
# multiplies the work the server does before it answers at all. Only ask for
# them under --long, where they're actually shown. createdAt is always fetched
# (a plain field on the PR, so effectively free) since it drives sorting.
# statusCheckRollup is the one expensive field we always pay for: the CI column
# is part of the default view here, not a --long extra.
fields="number,title,author,reviews,headRefName,headRefOid,url,updatedAt,createdAt,statusCheckRollup"
if [ "$long" = true ]; then
  fields="$fields,changedFiles,additions,deletions,mergeable,mergeStateStatus"
fi

# Drafts are left out unless --include-drafts asks for them. isDraft is a
# plain field on the PR, but it's only fetched then too: without the flag the
# search already guarantees every row is non-draft, and mine.jq reads a
# missing isDraft as false.
draft_filter="-is:draft"
if [ "$include_drafts" = true ]; then
  draft_filter=""
  fields="$fields,isDraft"
fi

# --include-assigned adds PRs someone else opened and assigned to you. The
# assignee list is fetched with them: the thread lookup reads it to count
# your replies as the owner's on those PRs (see fetch_pr_review_state).
if [ "$include_assigned" = true ]; then
  fields="$fields,assignees"
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# sort:created-asc asks gh/GitHub's search API to return oldest-first, matching
# mine.jq's sort_by(.createdAt) so the stalest PRs surface first.
#
# The searches filter on the server-side @me qualifier only, so they need
# neither the username nor the team lookup below — run them in the background
# and let them overlap with both. `wait` surfaces each exit status, so a
# failed search still aborts under set -e.
#
# --include-assigned is a second search rather than an OR in one query, and
# the two are merged by PR number: a PR you opened and assigned to yourself
# comes back from both.
search_pids=()
gh pr list --repo "$REPO" --search "author:@me is:open $draft_filter sort:created-asc" --json "$fields" > "$tmp/search-authored" &
search_pids+=($!)
if [ "$include_assigned" = true ]; then
  gh pr list --repo "$REPO" --search "assignee:@me is:open $draft_filter sort:created-asc" --json "$fields" > "$tmp/search-assigned" &
  search_pids+=($!)
fi

me="${GH_USERNAME:-$(gh api user --jq .login)}"

# Union of the current user's team memberships, for splitting APPROVALS into
# total vs. teammate counts — see my_team_logins in common.sh.
my_logins=$(my_team_logins "$me")

for pid in "${search_pids[@]}"; do wait "$pid"; done
prs=$(cat "$tmp"/search-* | jq -s 'add | unique_by(.number)')

# Open review-thread stats aren't exposed by `gh pr list`/`pr view --json`
# (no reviewThreads field), so they come from GraphQL, alongside the Jira
# statuses — see fetch_threads_and_jira_statuses in common.sh, which sets
# $watch_users, $threads and $jira_statuses. A bit slower than todo/prd if
# you have a lot of open PRs, but negligible for a normal workload. mine's
# JIRA column reads the branch name only, so the keys are extracted the same
# way.
fetch_threads_and_jira_statuses "$prs" "$me" jiraKeyFromBranch "$tmp"

jq -rn -L "$dir" \
  --argjson threads "$threads" \
  --argjson watchUsers "$watch_users" \
  --argjson jiraStatuses "$jira_statuses" \
  --argjson teamLogins "$my_logins" \
  --argjson approvalThreshold "${APPROVAL_THRESHOLD:-1}" \
  --arg jiraBase "${JIRA_BASE_URL:-}" \
  --arg jiraPattern "$ticket_pattern" \
  --argjson long "$long" \
  --argjson shortLinks "$short_links" \
  --argjson shortLabels "$short_labels" \
  --argjson includeAssigned "$include_assigned" \
  --arg me "$me" \
  -f "$dir/mine.jq" <<<"$prs"
