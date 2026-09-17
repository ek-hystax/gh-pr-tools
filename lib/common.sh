#!/usr/bin/env bash
# Shared config/tg-map loading for all gh-pr-tools subcommands.

config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/gh-pr-tools"
profiles_dir="$config_dir/profiles"
tgmap_file="$config_dir/tg-map.json"

# Optional override set by the entry point from --profile / -p.
GH_PR_TOOLS_PROFILE="${GH_PR_TOOLS_PROFILE:-}"

# Re-run a command without an intermediary terminal renderer, so ANSI styling
# and OSC 8 hyperlinks reach the terminal intact. The next frame is fetched
# before the current one is cleared, avoiding a blank screen during API calls.
# Convert a positive integer interval with an optional s/m/h suffix to seconds.
watch_interval_seconds() {
  local value="$1" amount unit multiplier
  [[ "$value" =~ ^([1-9][0-9]*)([smh]?)$ ]] || return 1
  amount="${BASH_REMATCH[1]}"
  unit="${BASH_REMATCH[2]}"
  case "$unit" in
    ""|s) multiplier=1 ;;
    m) multiplier=60 ;;
    h) multiplier=3600 ;;
  esac
  printf '%s\n' "$((amount * multiplier))"
}

# $1 = interval seconds, $2 = display interval, $3 = display label,
# remaining args = command.
refresh_command() {
  local interval_seconds="$1" interval_display="$2" label="$3" output updated_at
  shift 3

  while true; do
    output=$("$@")
    updated_at=$(date '+%Y-%m-%d %H:%M:%S')
    printf '\033[2J\033[H'
    printf 'Every %s: %s (Ctrl-C to stop)\n' "$interval_display" "$label"
    printf 'Last updated: %s\n\n' "$updated_at"
    printf '%s\n' "$output"
    sleep "$interval_seconds"
  done
}

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
  local name path env_cache="${GH_PR_TOOLS_TEAM_CACHE:-}" env_token="${JIRA_API_TOKEN:-}"
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
  # Sourcing the profile overwrites anything the environment had set, so an
  # environment JIRA_API_TOKEN is captured before the source and restored
  # here — same precedence rule (and same reason) as GH_PR_TOOLS_TEAM_CACHE.
  [ -n "$env_token" ] && JIRA_API_TOKEN="$env_token"
  # Unlike the two overrides above, the environment name differs from the
  # profile key, so sourcing the profile cannot clobber it and there is
  # nothing to capture beforehand — reading it after the source is enough.
  # Bare - rather than :- so that an explicitly empty environment value wins:
  # unlike a cache TTL or a token, "" is a meaningful setting here (watch
  # nobody), and it is the obvious way to switch the columns off for one run.
  THREAD_WATCH_USERS="${GH_PR_TOOLS_THREAD_WATCH_USERS-${THREAD_WATCH_USERS-}}"
  normalize_jira_config
  # Resolved here rather than when this file is sourced, so a profile can set
  # GH_PR_TOOLS_TEAM_CACHE like every other setting; an environment value
  # still wins, since that's the documented per-invocation override.
  team_cache_ttl="${env_cache:-${GH_PR_TOOLS_TEAM_CACHE:-$team_cache_default}}"
  if ! valid_gh_duration "$team_cache_ttl"; then
    echo "gh pr-tools: ignoring invalid GH_PR_TOOLS_TEAM_CACHE '$team_cache_ttl'" \
         "(expected a duration like 30m, 1h30m, or 0) — using $team_cache_default" >&2
    team_cache_ttl="$team_cache_default"
  fi
}

# Team rosters change rarely, so every team lookup below is served from gh's
# local response cache (gh api --cache) for up to this long — warm runs skip
# those round trips and their API quota. The trade-off: a roster change can
# take up to the TTL to show up in the APPROVALS/team columns. Override with
# GH_PR_TOOLS_TEAM_CACHE, in the environment or in a profile (any gh
# duration; 0 bypasses the cache).
# PR data (searches, reviews, threads) is never cached — it must stay live.
team_cache_default=1h
# Fallback for the few code paths that use a team lookup without load_config;
# load_config overwrites this with the validated profile/environment value.
team_cache_ttl="$team_cache_default"

# gh's --cache takes a Go duration: one or more <number><unit> pairs, or a
# bare 0. gh rejects anything else *before* making the request, which the
# lookups below either report as a hard failure (teams_members_map) or
# silently degrade into "you're on no teams" (my_teams_with_members) — so
# catch a bad value once, up front, instead of letting it look like an empty
# roster.
valid_gh_duration() {
  [ "$1" = "0" ] && return 0
  [[ "$1" =~ ^([0-9]+(\.[0-9]+)?(ns|us|ms|s|m|h))+$ ]]
}

team_members() { # $1: team slug -> JSON array of logins
  gh api "orgs/$ORG/teams/$1/members" --paginate --cache "$team_cache_ttl" \
    | jq -s '[.[].[] | .login]'
}

# Every team the current user belongs to, together with its member logins,
# in a single GraphQL call — replacing a slug lookup plus one REST members
# call per team. A team with >100 members is completed via paginated REST
# (team_members), keeping the common case at one round trip without silently
# truncating big teams. A failed/rate-limited lookup degrades to "no teams"
# rather than aborting the caller — same fallback policy as
# fetch_pr_review_state.
#
# Args: $1 = me.
# Prints: {slugs: ["<slug>", ...], members: {"<slug>": ["login", ...]}}
my_teams_with_members() {
  local me="$1" empty='{"slugs":[],"members":{}}' result slug m
  result=$(gh api graphql --cache "$team_cache_ttl" \
    -f query='query($org:String!,$me:String!){organization(login:$org){teams(first:100,userLogins:[$me]){nodes{slug members(first:100){pageInfo{hasNextPage} nodes{login}}}}}}' \
    -f org="$ORG" -f me="$me" 2>/dev/null \
    | jq '{slugs: [.data.organization.teams.nodes[].slug],
           members: ([.data.organization.teams.nodes[]
                      | {key: .slug,
                         value: {logins: [.members.nodes[].login],
                                 more: .members.pageInfo.hasNextPage}}]
                     | from_entries)}') || { echo "$empty"; return; }
  echo "$result" | jq -e . >/dev/null 2>&1 || { echo "$empty"; return; }
  for slug in $(jq -r '.members | to_entries[] | select(.value.more) | .key' <<<"$result"); do
    m=$(team_members "$slug" 2>/dev/null || echo '[]')
    result=$(jq --arg s "$slug" --argjson m "$m" '.members[$s] = {logins: $m, more: false}' <<<"$result")
  done
  jq '.members |= map_values(.logins)' <<<"$result"
}

# Member logins for a set of team slugs, batched into one aliased GraphQL
# call rather than one REST round trip per team. Like my_teams_with_members,
# a team with >100 members is completed via paginated REST. Unknown slugs
# resolve to null server-side and are dropped from the map. Unlike the
# degrade-to-empty lookups above, a failed call aborts the caller (set -e) —
# same behavior as the per-slug team_members loops this replaces.
#
# Args: $1 = newline-separated team slugs.
# Prints a JSON map: {"<slug>": ["login", ...]}.
teams_members_map() {
  local slugs="$1" slug m i=0 fields="" query result
  while IFS= read -r slug; do
    [ -n "$slug" ] || continue
    # Slugs are interpolated into the query text; anything outside GitHub's
    # slug alphabet can't be a real team, so skip it rather than quote it.
    [[ "$slug" =~ ^[A-Za-z0-9_.-]+$ ]] || continue
    fields+="t${i}:team(slug:\"${slug}\"){slug members(first:100){pageInfo{hasNextPage} nodes{login}}} "
    i=$((i+1))
  done <<<"$slugs"
  [ "$i" -gt 0 ] || { echo '{}'; return; }
  query="query(\$org:String!){organization(login:\$org){${fields}}}"
  result=$(gh api graphql --cache "$team_cache_ttl" -f query="$query" -f org="$ORG" \
    | jq '[.data.organization | to_entries[] | .value | select(. != null)
           | {key: .slug,
              value: {logins: [.members.nodes[].login],
                      more: .members.pageInfo.hasNextPage}}]
          | from_entries')
  for slug in $(jq -r 'to_entries[] | select(.value.more) | .key' <<<"$result"); do
    m=$(team_members "$slug")
    result=$(jq --arg s "$slug" --argjson m "$m" '.[$s] = {logins: $m, more: false}' <<<"$result")
  done
  jq 'map_values(.logins)' <<<"$result"
}

# Union of member logins across every team the current user belongs to.
my_team_logins() { # $1: me -> JSON array of logins, deduped
  my_teams_with_members "$1" | jq '[.members[][]] | unique'
}

tgmap_json() {
  if [ -f "$tgmap_file" ]; then cat "$tgmap_file"; else echo '{}'; fi
}

# Closed PRs (merged or not) in $REPO, together with whether each one's head
# branch ref still exists — in one paginated GraphQL query rather than a
# REST list call followed by a separate existence check. `headRefName` (a
# plain API string) survives branch deletion forever, but GraphQL's `headRef`
# (the actual Ref object) resolves to null once the branch is gone — that's
# the only way to detect it.
#
# GraphQL's `search` field has the same ~1000-result ceiling as `gh pr list
# --search` (there's no "branch still exists" search qualifier to filter
# narrower than that), so this still stops at $1 PRs scanned — it just gets
# there in one query shape instead of two. Paged 100 at a time (GraphQL
# search's own per-page max). An unscoped $2 (no author clause) searches the
# whole repo, not just one person, so it hits that ceiling far sooner.
#
# A failed lookup here is NOT swallowed to an empty/default value: this
# function's whole job is telling leftover branches apart from cleaned-up
# ones, so silently defaulting to "gone" would under-report (every PR would
# read as already cleaned up) rather than fail loudly — worse than erroring
# out.
#
# Args: $1 = max PRs to scan, $2 = author search clause (e.g. "author:@me",
# "author:octocat", or "" to include every author).
# Prints a JSON object {prs: [...], truncated: bool}. `truncated` is true
# only when the scan actually stopped short of the full result set (the last
# page fetched still had hasNextPage:true) — the caller can't reliably infer
# this just by comparing the returned count against $1 or GitHub's 1000-result
# ceiling, since a true result count that happens to equal that number would
# look identical to a real cutoff.
fetch_closed_prs_with_branch_status() {
  local max="$1" author_clause="${2:-}" cursor="null" has_next="true" all='[]' page_size fetched=0 response nodes got q

  q="is:pr is:closed repo:${REPO} sort:updated-desc"
  [ -n "$author_clause" ] && q="$author_clause $q"

  while [ "$has_next" = "true" ] && [ "$fetched" -lt "$max" ]; do
    page_size=$(( max - fetched < 100 ? max - fetched : 100 ))
    response=$(gh api graphql -f query='
      query($q: String!, $n: Int!, $cursor: String) {
        search(query: $q, type: ISSUE, first: $n, after: $cursor) {
          pageInfo { hasNextPage endCursor }
          nodes {
            ... on PullRequest {
              number title url closedAt mergedAt headRefName
              author { login }
              headRef { id }
            }
          }
        }
      }' -f q="$q" -F n="$page_size" -F cursor="$cursor")

    # A deleted GitHub account leaves .author null on old PRs — "ghost"
    # matches GitHub's own UI label for that case.
    nodes=$(jq '[.data.search.nodes[]
                 | {number, title, url, closedAt, mergedAt, headRefName,
                    author: (.author.login // "ghost"),
                    branchExists: (.headRef != null)}]' <<<"$response")
    got=$(jq 'length' <<<"$nodes")
    all=$(jq -n --argjson a "$all" --argjson b "$nodes" '$a + $b')
    fetched=$((fetched + got))
    [ "$got" -gt 0 ] || break
    has_next=$(jq -r '.data.search.pageInfo.hasNextPage' <<<"$response")
    cursor=$(jq -r '.data.search.pageInfo.endCursor // "null"' <<<"$response")
  done

  jq -n --argjson prs "$all" --argjson truncated "$([ "$has_next" = "true" ] && echo true || echo false)" \
    '{prs: $prs, truncated: $truncated}'
}

# THREAD_WATCH_USERS is a comma-separated list of GitHub logins whose review
# threads get a column of their own in todo/mine. Prints a JSON array of
# {display, key} objects: `display` is the login exactly as configured (minus
# any "[bot]" suffix) and is what the column header shows; `key` is its
# lowercased form, which thread authors are matched against.
#
# The suffix is stripped because the same app account has two spellings —
# GraphQL reports CodeRabbit as `coderabbitai`, while REST and the web UI show
# `coderabbitai[bot]`. Threads come from GraphQL, so a literal `[bot]` value
# would never match anything; accepting both spellings avoids a config that
# silently produces an empty column forever.
#
# Order is the order configured (columns follow it), so duplicates are dropped
# by hand rather than with unique_by, which would sort.
thread_watch_users() {
  jq -cn --arg raw "${THREAD_WATCH_USERS:-}" '
    $raw
    | split(",")
    | map(gsub("^\\s+|\\s+$"; "") | sub("\\s*\\[bot\\]$"; ""; "i"))
    | map(select(length > 0) | {display: ., key: ascii_downcase})
    | reduce .[] as $u ([]; if any(.[]; .key == $u.key) then . else . + [$u] end)'
}

# Review-thread stats and viewed-file stats aren't exposed by `gh pr
# list`/`pr view --json` (no reviewThreads/files fields), so fetch via
# GraphQL. Both are per-PR lookups, so they share one batched query (one
# aliased pullRequest field per PR carrying both selections) — a single round
# trip for the whole PR list instead of two, and instead of one per PR.
#
# Threads are split by who left the *opening* comment (a static fact about
# the thread, not an activity trace of every reply): $2 ("mine") vs anyone
# else ("theirs"). Each bucket counts every thread, resolved ones included,
# and breaks the total into three disjoint states that sum back to it:
#   resolved — marked resolved on GitHub
#   answered — still open, but the *last* comment is the PR owner's, meaning
#              they've replied (e.g. "Fixed") without the thread being closed
#   pending  — still open with no reply from the owner yet
# Note reviewThreads(first:100) is unpaginated (100 is GraphQL's per-page
# max), and that cap now covers resolved threads too — a PR with a very long
# resolved history can therefore undercount. pageInfo.hasNextPage rides along
# as "truncated" so the undercount is visible rather than silent: threadsCell
# in common.jq suffixes such totals with "+".
#
# Args: $1 = JSON array of PRs (needs .number and .author.login), $2 = login
# to attribute as "mine", $3 = "threads" to skip the viewed-file half (the
# fallback below is all-or-nothing, so a caller with no VIEWED column
# shouldn't pay for that selection — or risk losing its thread stats to an
# error in data it never renders). Default: both. $4 = the watched-login array
# from thread_watch_users (default []); those logins each get a bucket of their
# own and are taken out of "theirs".
# Prints: {threads: {"<number>": {"mine":      {"total": N, "pending": P, "answered": A, "resolved": R},
#                                 "theirs":    {"total": M, "pending": Q, "answered": B, "resolved": S},
#                                 "watched":   {"<key>": {"total": ..., ...}},
#                                 "truncated": <bool>}},
#          viewed:  {"<number>": {"viewed": N, "total": M}}}
# With $3 = "threads", .viewed is an empty map. On a failed lookup the whole
# result collapses to {threads: {}, viewed: {}} — the accessors in common.jq
# read through the missing keys, so no caller needs to special-case it.
fetch_pr_review_state() {
  local prs="$1" me="$2" want="${3:-all}" watch_users="${4:-[]}" owner repo_name numbers number query result
  local empty='{"threads":{},"viewed":{}}' files_sel="" want_viewed=true
  if [ "$want" = "threads" ]; then
    want_viewed=false
  else
    files_sel="files(first:100){nodes{path viewerViewedState}}"
  fi
  owner="${REPO%%/*}"
  repo_name="${REPO##*/}"
  numbers=$(jq -r '.[].number' <<<"$prs")
  [ -n "$numbers" ] || { echo "$empty"; return; }

  query="query(\$owner:String!,\$repo:String!){repository(owner:\$owner,name:\$repo){"
  while IFS= read -r number; do
    query+="pr${number}:pullRequest(number:${number}){reviewThreads(first:100){pageInfo{hasNextPage} nodes{isResolved comments(first:1){nodes{author{login}}} lastComments: comments(last:1){nodes{author{login}}}}} ${files_sel}} "
  done <<<"$numbers"
  query+="}}"

  # A failed/rate-limited lookup must not abort the whole command — fall back
  # to empty maps (every PR renders "-") and keep going.
  result=$(gh api graphql -f query="$query" -f owner="$owner" -f repo="$repo_name" 2>/dev/null \
    | jq --arg me "$me" --argjson prs "$prs" --argjson wantViewed "$want_viewed" \
         --argjson watch "$watch_users" '
        # Input is the thread list for one bucket; $owner is the login of the
        # PR author, whose reply is what makes an open thread "answered".
        def bucketStats($owner):
          ([.[] | select(.isResolved)] | length) as $resolved
          | [.[] | select(.isResolved | not)] as $open
          | ([$open[] | select(.lastComments.nodes[0].author.login == $owner)] | length) as $answered
          | { total: length,
              pending: (($open | length) - $answered),
              answered: $answered,
              resolved: $resolved };

        # A thread belongs to whoever opened it. Matched case-insensitively so
        # a profile spelling like "CodeRabbitAI" still lines up with the login
        # GraphQL reports.
        def openerKey: ((.comments.nodes[0].author.login // "") | ascii_downcase);

        # Watched logins are taken out of "theirs" so the watched columns and
        # THREADS partition the threads rather than double-counting them. Only
        # "theirs" ever loses threads this way — "mine" is what todo displays
        # and it is defined by author, so watching your own login duplicates
        # that column rather than cannibalizing it, with no special case here.
        ($watch | map(.key)) as $subtractKeys
        | (reduce $prs[] as $pr ({}; .[$pr.number | tostring] = $pr.author.login)) as $owners
        | .data.repository
        | to_entries
        | map(select(.value != null) | .num = (.key | ltrimstr("pr")))
        | { threads: (map({
              key: .num,
              value: (
                ($owners[.num] // "") as $owner
                | [.value.reviewThreads.nodes[]?] as $threads
                | { mine:   ($threads | map(select(.comments.nodes[0].author.login == $me)) | bucketStats($owner)),
                    theirs: ($threads
                             | map(. as $t | ($t | openerKey) as $k
                                   | select($t.comments.nodes[0].author.login != $me
                                            and ($subtractKeys | index($k)) == null))
                             | bucketStats($owner)),
                    watched: (reduce $watch[] as $u ({};
                                .[$u.key] = ($threads
                                             | map(select(openerKey == $u.key))
                                             | bucketStats($owner)))),
                    truncated: (.value.reviewThreads.pageInfo.hasNextPage // false) }
              )
            }) | from_entries),
            viewed: (if $wantViewed then (map({
              key: .num,
              value: (
                [.value.files.nodes[]?] as $files
                | { viewed: ([$files[] | select(.viewerViewedState == "VIEWED")] | length),
                    total: ($files | length) }
              )
            }) | from_entries) else {} end) }
      ') || result="$empty"
  echo "$result" | jq -e . >/dev/null 2>&1 || result="$empty"
  echo "$result"
}

# Jira ----------------------------------------------------------------------
#
# Every Jira setting lives in the profile file, the token included — it is a
# local env file, sourced like the rest of the config. An environment
# JIRA_API_TOKEN overrides the profile for a single invocation (CI, a
# throwaway token), the same precedence GH_PR_TOOLS_TEAM_CACHE uses.
#
# JIRA_BASE_URL (the /browse URL) predates JIRA_SITE and is what older
# profiles carry. normalize_jira_config derives whichever of the two is
# missing, so an existing profile keeps working untouched and a new one only
# needs JIRA_SITE.

# Fill in JIRA_SITE / JIRA_BASE_URL from whichever one the profile set, and
# strip the trailing slash both the prompt and hand-editing tend to leave.
normalize_jira_config() {
  JIRA_SITE="${JIRA_SITE:-}"
  JIRA_BASE_URL="${JIRA_BASE_URL:-}"
  JIRA_SITE="${JIRA_SITE%/}"
  JIRA_BASE_URL="${JIRA_BASE_URL%/}"
  if [ -z "$JIRA_SITE" ] && [ -n "$JIRA_BASE_URL" ]; then
    JIRA_SITE="${JIRA_BASE_URL%/browse}"
    JIRA_SITE="${JIRA_SITE%/}"
  fi
  if [ -z "$JIRA_BASE_URL" ] && [ -n "$JIRA_SITE" ]; then
    JIRA_BASE_URL="$JIRA_SITE/browse"
  fi
  JIRA_EMAIL="${JIRA_EMAIL:-}"
  JIRA_API_TOKEN="${JIRA_API_TOKEN:-}"
  JIRA_CLOUD_ID="${JIRA_CLOUD_ID:-}"
}

# The site host is not a usable API base on every tenant: a Cloud org can have
# an auth policy that makes <site>.atlassian.net ignore API-token credentials
# and answer as an anonymous user — HTTP 200 with an empty result rather than
# a 401, for a valid and an invalid token alike. api.atlassian.com/ex/jira
# honors the token and returns a real 401 when it is wrong, so prefer it
# whenever a cloud ID is known.
#
# Falls back to the site host when there is no cloud ID, which is also the
# correct base for a Data Center/Server instance (no gateway, no cloud ID).
jira_api_base() {
  if [ -n "${JIRA_CLOUD_ID:-}" ]; then
    printf 'https://api.atlassian.com/ex/jira/%s' "$JIRA_CLOUD_ID"
  else
    printf '%s' "${JIRA_SITE:-}"
  fi
}

# A Cloud site publishes its own cloud ID unauthenticated, so init can resolve
# it without the token and a hand-written profile can leave it out. Prints
# nothing for a non-Cloud instance or an unreachable site.
# Accepts a bare org ("yourorg") or a full site URL, and normalizes both to
# the site root — the one value a profile carries, from which normalize_jira_config
# derives the /browse URL and jira_api_base the REST base. Empty in, empty out.
# Shared by init and `profile set` so the two cannot drift.
normalize_jira_site_input() { # $1: what the user typed
  local input="$1" site=""
  [ -n "$input" ] || { printf '\n'; return; }
  case "$input" in
    http://*|https://*) site="$input" ;;
    *)                  site="https://${input}.atlassian.net" ;;
  esac
  site="${site%/}"
  site="${site%/browse}"
  site="${site%/}"
  printf '%s\n' "$site"
}

jira_lookup_cloud_id() { # $1: site root
  curl -sS --max-time 10 "$1/_edge/tenant_info" 2>/dev/null \
    | jq -r 'if type == "object" and (.cloudId | type) == "string" then .cloudId else empty end' 2>/dev/null
}

# True when there is enough configuration to ask Jira for issue statuses.
# False is not an error: the status lookup is skipped and links still render.
jira_status_enabled() {
  [ -n "${JIRA_SITE:-}" ] && [ -n "${JIRA_EMAIL:-}" ] && [ -n "${JIRA_API_TOKEN:-}" ]
}

# Jira issue statuses for a set of ticket keys, in one bulkfetch call.
#
# bulkfetch is used rather than a JQL `key in (...)` search because the keys
# here are scraped out of branch names: a key for a deleted or moved issue
# makes JQL fail the whole query, while bulkfetch just leaves it out of the
# response. Its cap is 1000 keys per call when the request names fields
# explicitly (as this one does) — far beyond the number of open PRs any of
# these commands lists, so there is no chunking.
#
# Args: $1 = JSON array of upper-cased issue keys.
# Prints a JSON object: {"KF-1309": "In Review"}
# An empty object means "no statuses" and always renders as "-"; it is the
# result for every failure mode as well, matching fetch_pr_review_state's
# policy of degrading rather than aborting a whole command over one lookup.
fetch_jira_statuses() {
  local keys="$1" empty='{}' body code result
  jira_status_enabled || { echo "$empty"; return; }
  [ "$(jq 'length' <<<"$keys")" -gt 0 ] || { echo "$empty"; return; }

  body=$(mktemp)
  # The token goes on argv here, where it is briefly visible to `ps`. That is
  # the same exposure as the profile file it came from, which is plain text.
  code=$(jq -nc --argjson keys "$keys" '{issueIdsOrKeys: $keys, fields: ["status"]}' \
    | curl -sS -o "$body" -w '%{http_code}' --max-time 20 \
        -u "$JIRA_EMAIL:$JIRA_API_TOKEN" \
        -X POST "$(jira_api_base)/rest/api/3/issue/bulkfetch" \
        -H 'Content-Type: application/json' \
        --data-binary @- 2>/dev/null) || code=000

  case "$code" in
    200) ;;
    401|403)
      # Worth one line on stderr, unlike a timeout: a rejected token stays
      # rejected, so silence here would leave the column blank indefinitely
      # with nothing pointing at the cause. Jira API tokens expire within a
      # year, so this is a question of when, not whether.
      echo "gh pr-tools: Jira rejected the API token (HTTP $code) —" \
           "ticket status unavailable; re-run: gh pr-tools init" >&2
      rm -f "$body"; echo "$empty"; return ;;
    *)
      rm -f "$body"; echo "$empty"; return ;;
  esac

  result=$(jq '[.issues[]?
                | select(.key != null and .fields.status.name != null)
                | {key: .key, value: .fields.status.name}]
               | from_entries' "$body" 2>/dev/null) || result="$empty"
  rm -f "$body"
  jq -e . >/dev/null 2>&1 <<<"$result" || result="$empty"
  echo "$result"
}
