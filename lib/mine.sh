#!/usr/bin/env bash
# gh pr-tools mine — open PRs you authored.
set -euo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$dir/common.sh"

long=false
short_links=false
short_labels=false
watch=false
watch_interval=5m
command_args=()
while [ $# -gt 0 ]; do
  case "$1" in
    --long|-l) long=true; command_args+=("$1"); shift ;;
    --short-links|-s) short_links=true; command_args+=("$1"); shift ;;
    --short-labels|-S) short_labels=true; command_args+=("$1"); shift ;;
    --watch|-w)
      watch=true
      if [ $# -gt 1 ] && [[ "$2" != -* ]]; then watch_interval="$2"; shift 2
      else shift
      fi
      ;;
    --watch=*|-w=*) watch=true; watch_interval="${1#*=}"; shift ;;
    *) echo "gh pr-tools mine: unknown option '$1' (supported: --long, --short-links, --short-labels, --watch[=INTERVAL])" >&2; exit 1 ;;
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

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# sort:created-asc asks gh/GitHub's search API to return oldest-first, matching
# mine.jq's sort_by(.createdAt) so the stalest PRs surface first.
#
# The search filters on the server-side @me qualifier only, so it needs
# neither the username nor the team lookup below — run it in the background
# and let it overlap with both. `wait` surfaces its exit status, so a failed
# search still aborts under set -e.
gh pr list --repo "$REPO" --search "author:@me is:open -is:draft sort:created-asc" --json "$fields" > "$tmp/prs" &
search_pid=$!

me="${GH_USERNAME:-$(gh api user --jq .login)}"

# Union of the current user's team memberships, for splitting APPROVALS into
# total vs. teammate counts — see my_team_logins in common.sh.
my_logins=$(my_team_logins "$me")

wait "$search_pid"
prs=$(cat "$tmp/prs")

# Open review-thread stats aren't exposed by `gh pr list`/`pr view --json`
# (no reviewThreads field), so fetch via GraphQL — see fetch_pr_review_state
# in common.sh. mine has no VIEWED column, so ask for the threads half only:
# the viewed-file selection would be fetched and discarded, and since the
# lookup degrades all-or-nothing, an error in it would blank THREADS too.
# A bit slower than todo/prd if you have a lot of open PRs, but negligible
# for a normal workload.
# Ticket keys come out of the PR list here rather than inside mine.jq, since
# the whole point is to ask Jira about all of them in one request before the
# render pass runs. Same extraction the JIRA column uses, so the two agree.
keys=$(jq -L "$dir" -c --arg jiraPattern "$ticket_pattern" \
  'include "common"; [.[] | jiraKeyFromBranch($jiraPattern) | select(. != null)] | unique' <<<"$prs")

# Independent of the thread lookup, so the two round trips overlap.
fetch_jira_statuses "$keys" > "$tmp/jira" &
jira_pid=$!

watch_users=$(thread_watch_users)
threads=$(fetch_pr_review_state "$prs" "$me" threads "$watch_users" | jq '.threads')
wait "$jira_pid"
jira_statuses=$(cat "$tmp/jira")

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
  -f "$dir/mine.jq" <<<"$prs"
