#!/usr/bin/env bash
# Shared config/tg-map loading for all gh-pr-tools subcommands.

config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/gh-pr-tools"
profiles_dir="$config_dir/profiles"
tgmap_file="$config_dir/tg-map.json"

# Optional override set by the entry point from --profile / -p.
GH_PR_TOOLS_PROFILE="${GH_PR_TOOLS_PROFILE:-}"

validate_profile_name() {
  local name="$1"
  if [[ ! "$name" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]]; then
    echo "gh pr-tools: invalid profile name '$name' (use letters, digits, _, -)" >&2
    exit 1
  fi
}

# Turn a repo short-name into a valid profile name, or "default".
suggest_profile_name() {
  local cleaned
  cleaned=$(printf '%s' "$1" | tr -c 'A-Za-z0-9_-' '-' | sed -E 's/^-+//; s/-+$//; s/-+/-/g')
  if [[ "$cleaned" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]]; then
    printf '%s\n' "$cleaned"
  else
    printf 'default\n'
  fi
}

profile_path() {
  echo "$profiles_dir/$1.sh"
}

profile_exists() {
  [ -f "$(profile_path "$1")" ]
}

require_profile_exists() {
  validate_profile_name "$1"
  profile_exists "$1" || {
    echo "gh pr-tools: unknown profile '$1' — run: gh pr-tools profile list" >&2
    exit 1
  }
}

list_profile_names() {
  [ -d "$profiles_dir" ] || return 0
  local f
  for f in "$profiles_dir"/*.sh; do
    [ -e "$f" ] || continue
    basename "$f" .sh
  done | sort
}

# Read REPO= from a profile file without sourcing (safe for listing/matching).
profile_repo() {
  local path line val
  path=$(profile_path "$1")
  [ -f "$path" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      REPO=*)
        val="${line#REPO=}"
        if [[ "$val" == \"*\" || "$val" == \'*\' ]]; then
          val="${val:1:${#val}-2}"
        fi
        printf '%s\n' "$val"
        return 0
        ;;
    esac
  done < "$path"
  return 1
}

in_git_worktree() {
  git rev-parse --is-inside-work-tree >/dev/null 2>&1
}

gh_repo_view() {
  gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null
}

cwd_repo() {
  in_git_worktree || return 1
  gh_repo_view || return 1
}

# Find profile names whose REPO matches $1. Prints one name per line.
profiles_matching_repo() {
  local want="$1" name repo
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    repo=$(profile_repo "$name" || true)
    [ "$repo" = "$want" ] && printf '%s\n' "$name"
  done < <(list_profile_names)
}

# Resolve which profile to use. Prints the name. Exits 1 on failure.
# Honors GH_PR_TOOLS_PROFILE (set by entry point from --profile / -p).
#
# Resolution:
#   1. --profile / -p
#   2. Must be inside a git checkout — otherwise a hard error.
#   3. Profile whose REPO matches this checkout's repo (exactly one).
#      - gh can't resolve a repo for this checkout, or no profile matches →
#        error suggesting init.
#      - more than one profile matches → ambiguity error naming them.
resolve_profile() {
  local cwd matches

  if [ -n "${GH_PR_TOOLS_PROFILE:-}" ]; then
    require_profile_exists "$GH_PR_TOOLS_PROFILE"
    printf '%s\n' "$GH_PR_TOOLS_PROFILE"
    return 0
  fi

  if [ -z "$(list_profile_names)" ]; then
    echo "gh pr-tools: not configured yet — run: gh pr-tools init" >&2
    exit 1
  fi

  if ! in_git_worktree; then
    echo "gh pr-tools: No Git repository was found in the current directory. Please initialize a Git repository first, then run: gh pr-tools init" >&2
    exit 1
  fi

  cwd=$(gh_repo_view || true)
  if [ -z "$cwd" ]; then
    echo "gh pr-tools: No settings were found for this Git repository. Please run: gh pr-tools init" >&2
    exit 1
  fi

  matches=$(profiles_matching_repo "$cwd" || true)
  case "$matches" in
    "")
      echo "gh pr-tools: No settings were found for this Git repository. Please run: gh pr-tools init" >&2
      exit 1
      ;;
    *$'\n'*)
      local names_oneline
      names_oneline=$(printf '%s' "$matches" | tr '\n' ' ' | sed -E 's/ +$//')
      echo "gh pr-tools: multiple profiles match repo '$cwd' ($names_oneline) — pass --profile NAME to disambiguate" >&2
      exit 1
      ;;
    *)
      printf '%s\n' "$matches"
      return 0
      ;;
  esac
}

# Reject creating/updating a profile to a REPO already owned by another profile.
assert_repo_unique() {
  local name="$1" repo="$2" other other_repo
  while IFS= read -r other; do
    [ -n "$other" ] || continue
    [ "$other" = "$name" ] && continue
    other_repo=$(profile_repo "$other" || true)
    if [ "$other_repo" = "$repo" ]; then
      echo "gh pr-tools: repo '$repo' is already used by profile '$other'" >&2
      exit 1
    fi
  done < <(list_profile_names)
}

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

# Resolve a PR argument (bare number / TICKET-123 / Jira link / branch name)
# to a PR number. Callers must have set $REPO (via load_config) and
# $ticket_pattern before calling.
resolve_pr() {
  local arg="$1" ticket
  # Jira link -> the ticket is always the last path segment
  if [[ "$arg" =~ ^https?:// ]]; then
    arg="${arg%%\?*}"
    arg="${arg%%#*}"
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

load_config() {
  local name path
  name=$(resolve_profile)
  path=$(profile_path "$name")
  # shellcheck source=/dev/null
  source "$path"
  : "${REPO:?REPO missing in $path — re-run: gh pr-tools init}"
  : "${ORG:?ORG missing in $path — re-run: gh pr-tools init}"
  APPROVAL_THRESHOLD="${APPROVAL_THRESHOLD:-1}"
  # A hand-edited or pre-existing profile could set this to 0 or something
  # non-numeric; init.sh only validates its own prompt, not the file directly.
  [[ "$APPROVAL_THRESHOLD" =~ ^[0-9]+$ ]] && [ "$APPROVAL_THRESHOLD" -ge 1 ] || APPROVAL_THRESHOLD=1
}

team_members() { # $1: team slug -> JSON array of logins
  gh api "orgs/$ORG/teams/$1/members" --paginate \
    | jq -s '[.[].[] | .login]'
}

my_team_slugs() { # $1: me -> newline-separated team slugs (may be empty)
  gh api graphql \
    -f query='query($org:String!,$me:String!){organization(login:$org){teams(first:100,userLogins:[$me]){nodes{slug}}}}' \
    -f org="$ORG" -f me="$1" --jq '.data.organization.teams.nodes[].slug' 2>/dev/null || true
}

# Union of member logins across a newline-separated list of team slugs.
# A failed/rate-limited lookup degrades to "[]" rather than aborting the
# caller — same fallback policy as fetch_review_threads.
team_logins_for_slugs() { # $1: newline-separated slugs -> JSON array of logins, deduped
  local result='[]' slug members
  while IFS= read -r slug; do
    [ -n "$slug" ] || continue
    members=$(team_members "$slug" 2>/dev/null || echo '[]')
    result=$(jq -n --argjson a "$result" --argjson b "$members" '($a + $b) | unique')
  done <<<"$1"
  echo "$result"
}

# Union of member logins across every team the current user belongs to.
my_team_logins() { # $1: me -> JSON array of logins, deduped
  team_logins_for_slugs "$(my_team_slugs "$1")"
}

tgmap_json() {
  if [ -f "$tgmap_file" ]; then cat "$tgmap_file"; else echo '{}'; fi
}

# Open (non-resolved) review-thread stats aren't exposed by `gh pr list`/`pr
# view --json` (no reviewThreads field), so fetch via GraphQL. Threads are
# split by who left the *opening* comment (a static fact about the thread,
# not an activity trace of every reply): $2 ("mine") vs anyone else
# ("theirs"). Each bucket also tracks how many threads are "answered" — the
# *last* comment's author is the PR's owner, meaning the owner has since
# replied (e.g. "Fixed") even though the thread is still open.
#
# All PRs are fetched in a single GraphQL call (one aliased pullRequest field
# per PR) rather than one round trip per PR — with a dozen+ open PRs, N
# sequential round trips is the dominant cost of the whole command.
#
# Args: $1 = JSON array of PRs (needs .number and .author.login), $2 = login
# to attribute as "mine".
# Prints a JSON map: {"<number>": {"mine": {"total": N, "answered": X},
#                                  "theirs": {"total": M, "answered": Y}}}.
fetch_review_threads() {
  local prs="$1" me="$2" owner repo_name numbers number query result
  owner="${REPO%%/*}"
  repo_name="${REPO##*/}"
  numbers=$(jq -r '.[].number' <<<"$prs")
  [ -n "$numbers" ] || { echo '{}'; return; }

  query="query(\$owner:String!,\$repo:String!){repository(owner:\$owner,name:\$repo){"
  while IFS= read -r number; do
    query+="pr${number}:pullRequest(number:${number}){reviewThreads(first:100){nodes{isResolved comments(first:1){nodes{author{login}}} lastComments: comments(last:1){nodes{author{login}}}}}} "
  done <<<"$numbers"
  query+="}}"

  # A failed/rate-limited lookup must not abort the whole command — fall back
  # to an empty map (every PR renders "-") and keep going.
  result=$(gh api graphql -f query="$query" -f owner="$owner" -f repo="$repo_name" 2>/dev/null \
    | jq --arg me "$me" --argjson prs "$prs" '
        (reduce $prs[] as $pr ({}; .[$pr.number | tostring] = $pr.author.login)) as $owners
        | .data.repository
        | to_entries
        | map(select(.value != null) | (.key | ltrimstr("pr")) as $num | {
            key: $num,
            value: (
              ($owners[$num] // "") as $owner
              | [.value.reviewThreads.nodes[]? | select(.isResolved | not)] as $threads
              | ($threads | map(select(.comments.nodes[0].author.login == $me))) as $mine
              | ($threads | map(select(.comments.nodes[0].author.login != $me))) as $theirs
              | { mine:   { total: ($mine | length),
                            answered: ([$mine[]   | select(.lastComments.nodes[0].author.login == $owner)] | length) },
                  theirs: { total: ($theirs | length),
                            answered: ([$theirs[] | select(.lastComments.nodes[0].author.login == $owner)] | length) } }
            )
          })
        | from_entries
      ') || result='{}'
  echo "$result" | jq -e . >/dev/null 2>&1 || result='{}'
  echo "$result"
}
