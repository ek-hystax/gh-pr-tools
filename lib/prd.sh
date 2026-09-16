#!/usr/bin/env bash
# gh pr-tools prd <pr-number | TICKET-123 | jira-link | branch-name>
# PR summary + reviewers who still need to approve, with Telegram links.
set -euo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$dir/common.sh"

watch=false
watch_interval=5m
arg=""
while [ $# -gt 0 ]; do
  case "$1" in
    --watch|-w) watch=true; shift ;;
    --watch=*|-w=*) watch=true; watch_interval="${1#*=}"; shift ;;
    -*)
      echo "gh pr-tools prd: unknown option '$1' (supported: --watch[=INTERVAL])" >&2
      exit 1
      ;;
    *)
      [ -z "$arg" ] || {
        echo "usage: gh pr-tools prd [--watch[=INTERVAL]] <pr-number | TICKET-123 | jira-link | branch-name>" >&2
        exit 1
      }
      arg="$1"
      shift
      ;;
  esac
done

[ -n "$arg" ] || {
  echo "usage: gh pr-tools prd [--watch[=INTERVAL]] <pr-number | TICKET-123 | jira-link | branch-name>" >&2
  exit 1
}

if [ "$watch" = true ]; then
  watch_seconds=$(watch_interval_seconds "$watch_interval") || {
    echo "gh pr-tools prd: invalid watch interval '$watch_interval' (expected e.g. 30s, 5m, or 1h)" >&2
    exit 1
  }
  refresh_command "$watch_seconds" "$watch_interval" "gh pr-tools prd $arg" "$0" "$arg"
fi

load_config

me="${GH_USERNAME:-$(gh api user --jq .login)}"
ticket_pattern="${JIRA_PREFIX:-[A-Za-z]+}-[0-9]+"

pr=$(resolve_pr "$arg")

json=$(gh pr view "$pr" --repo "$REPO" \
  --json number,title,url,author,updatedAt,headRefName,headRefOid,baseRefName,reviewRequests,reviews)

# Requested teams -> {"ui": ["v-hx", ...], "backend": [...]}
# reviewRequests serializes team slugs as "org/slug"; the lookup needs the
# bare slug. All requested teams are fetched in one aliased call — see
# teams_members_map.
members=$(teams_members_map "$(jq -r '[.reviewRequests[]? | .slug // empty | split("/") | last] | unique | .[]' <<<"$json")")

# Union of the current user's team memberships, to mark "Approved by:"
# entries that are teammates — see my_team_logins in common.sh. Skipped when
# there's nothing to tag yet, to avoid the lookup's API calls on every PR.
if jq -e '(.reviews // []) | length > 0' <<<"$json" >/dev/null; then
  my_logins=$(my_team_logins "$me")
else
  my_logins='[]'
fi

# One PR, so one key at most — fetched inline rather than backgrounded like
# todo/mine, where the request overlaps a whole fan-out of other lookups.
jira_statuses=$(fetch_jira_statuses "$(jq -L "$dir" -c --arg jiraPattern "$ticket_pattern" \
  'include "common"; [jiraKeyFromBranchOrTitle($jiraPattern) | select(. != null)]' <<<"$json")")

jq -r -L "$dir" \
  --argjson jiraStatuses "$jira_statuses" \
  --argjson teamMembers "$members" \
  --argjson teamLogins "$my_logins" \
  --argjson approvalThreshold "${APPROVAL_THRESHOLD:-1}" \
  --argjson tgmap "$(tgmap_json)" \
  --arg jiraBase "${JIRA_BASE_URL:-}" \
  --arg jiraPattern "$ticket_pattern" \
  -f "$dir/prd.jq" <<<"$json"
