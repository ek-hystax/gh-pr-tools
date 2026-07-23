#!/usr/bin/env bash
# gh pr-tools prd <pr-number | TICKET-123 | jira-link | branch-name>
# PR summary + reviewers who still need to approve, with Telegram links.
set -euo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$dir/common.sh"
load_config

arg="${1:?usage: gh pr-tools prd <pr-number | TICKET-123 | jira-link | branch-name>}"
me="${GH_USERNAME:-$(gh api user --jq .login)}"
ticket_pattern="${JIRA_PREFIX:-[A-Za-z]+}-[0-9]+"

pr=$(resolve_pr "$arg")

json=$(gh pr view "$pr" --repo "$REPO" \
  --json number,title,url,author,updatedAt,headRefName,headRefOid,baseRefName,reviewRequests,reviews)

# Requested teams -> {"ui": ["v-hx", ...], "backend": [...]}
# reviewRequests serializes team slugs as "org/slug"; the API path needs the bare slug.
members='{}'
for slug in $(jq -r '[.reviewRequests[]? | .slug // empty | split("/") | last] | unique | .[]' <<<"$json"); do
  m=$(team_members "$slug")
  members=$(jq --arg t "$slug" --argjson m "$m" '. + {($t): $m}' <<<"$members")
done

# Union of the current user's team memberships, to mark "Approved by:"
# entries that are teammates — see my_team_logins in common.sh. Skipped when
# there's nothing to tag yet, to avoid the lookup's API calls on every PR.
if jq -e '(.reviews // []) | length > 0' <<<"$json" >/dev/null; then
  my_logins=$(my_team_logins "$me")
else
  my_logins='[]'
fi

jq -r -L "$dir" \
  --argjson teamMembers "$members" \
  --argjson teamLogins "$my_logins" \
  --argjson approvalThreshold "${APPROVAL_THRESHOLD:-1}" \
  --argjson tgmap "$(tgmap_json)" \
  --arg jiraBase "${JIRA_BASE_URL:-}" \
  --arg jiraPattern "$ticket_pattern" \
  -f "$dir/prd.jq" <<<"$json"
