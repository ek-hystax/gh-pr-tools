#!/usr/bin/env bash
# gh pr-tools prd <pr-number | TICKET-123 | jira-link | branch-name>
# PR summary + reviewers who still need to approve, with Telegram links.
set -euo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$dir/common.sh"
load_config

arg="${1:?usage: gh pr-tools prd <pr-number | TICKET-123 | jira-link | branch-name>}"
ticket_pattern="${JIRA_PREFIX:-[A-Za-z]+}-[0-9]+"

pick_one() { # stdin: JSON array of {number, title}; $1: what we searched for
  local matches count
  matches=$(cat)
  count=$(jq 'length' <<<"$matches")
  if [ "$count" -eq 0 ]; then
    echo "gh pr-tools: no open PR found for $1" >&2
    exit 1
  elif [ "$count" -gt 1 ]; then
    echo "gh pr-tools: multiple open PRs match $1:" >&2
    jq -r '.[] | "  #\(.number)  \(.title)"' <<<"$matches" >&2
    exit 1
  fi
  jq -r '.[0].number' <<<"$matches"
}

resolve_pr() {
  local arg="$1" ticket
  # Jira link -> the ticket is always the last path segment
  if [[ "$arg" =~ ^https?:// ]]; then
    arg="${arg%%\?*}"
    arg="${arg%/}"
    arg="${arg##*/}"
    if ! [[ "$arg" =~ ^${ticket_pattern}$ ]]; then
      echo "gh pr-tools: could not extract a ticket from link $1" >&2
      exit 1
    fi
  fi
  if [[ "$arg" =~ ^[0-9]+$ ]]; then
    echo "$arg"
  elif [[ "$arg" =~ ^${ticket_pattern}$ ]]; then
    ticket=$(tr '[:lower:]' '[:upper:]' <<<"$arg")
    gh pr list --repo "$REPO" --search "$ticket in:title" --json number,title \
      | jq --arg t "$ticket" '[.[] | select(.title | test("\\b" + $t + "\\b"; "i"))]' \
      | pick_one "ticket $ticket"
  else
    gh pr list --repo "$REPO" --head "$arg" --json number,title \
      | pick_one "branch $arg"
  fi
}

team_members() { # $1: team slug -> JSON array of logins
  gh api "orgs/$ORG/teams/$1/members" --paginate --jq '[.[].login]'
}

pr=$(resolve_pr "$arg")

json=$(gh pr view "$pr" --repo "$REPO" \
  --json number,title,url,author,updatedAt,headRefName,baseRefName,reviewDecision,reviewRequests,reviews)

# Requested teams -> {"ui": ["v-hx", ...], "backend": [...]}
# reviewRequests serializes team slugs as "org/slug"; the API path needs the bare slug.
members='{}'
for slug in $(jq -r '[.reviewRequests[]? | .slug // empty | split("/") | last] | unique | .[]' <<<"$json"); do
  m=$(team_members "$slug")
  members=$(jq --arg t "$slug" --argjson m "$m" '. + {($t): $m}' <<<"$members")
done

jq -r \
  --argjson teamMembers "$members" \
  --argjson tgmap "$(tgmap_json)" \
  --arg jiraBase "${JIRA_BASE_URL:-}" \
  --arg jiraPattern "$ticket_pattern" \
  -f "$dir/prd.jq" <<<"$json"
