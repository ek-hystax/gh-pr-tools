#!/usr/bin/env bash
# gh pr-tools profile list|show|remove — manage named profiles.
set -euo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$dir/common.sh"

usage() {
  cat <<'EOF' >&2
usage: gh pr-tools profile <list|show|set|unset|remove> ...
  list                 list all profiles, marking a checkout match with (cwd)
  show [name]          print a profile's settings (default: currently resolved)
  set <key> [value]    change one setting, leaving the rest of the file alone
                       (omit the value to be prompted; required for JIRA_API_TOKEN)
  unset <key>          drop one setting, reverting it to its default
  remove <name>        delete a profile

set/unset act on the resolved profile; use the global --profile NAME to pick
another. Keys are case-insensitive and - is accepted for _, so
"thread-watch-users" and "THREAD_WATCH_USERS" are the same key.
EOF
}

# Keys a profile may carry. Anything else is rejected rather than written:
# catching a typo is the main thing `set` buys over editing the file by hand,
# and a misspelled key would otherwise sit there silently doing nothing.
settable_keys="REPO ORG GH_USERNAME JIRA_PREFIX JIRA_SITE JIRA_EMAIL \
JIRA_CLOUD_ID JIRA_API_TOKEN APPROVAL_THRESHOLD THREAD_WATCH_USERS \
GH_PR_TOOLS_TEAM_CACHE"

# REPO and ORG have no usable default — load_config aborts without them — so
# they can be changed but not dropped.
required_keys="REPO ORG GH_USERNAME"

canonical_key() { # $1: what the user typed
  printf '%s\n' "$1" | tr '[:lower:]-' '[:upper:]_'
}

assert_known_key() { # $1: canonical key
  local k
  for k in $settable_keys; do
    if [ "$k" = "$1" ]; then return 0; fi
  done
  echo "gh pr-tools: unknown profile key '$1'" >&2
  echo "known keys: $settable_keys" >&2
  exit 1
}

# Validation mirrors what init already enforces at its own prompts, so a
# profile written by `set` can't be one init would have refused to write.
validate_profile_value() { # $1: profile name, $2: key, $3: value
  local name="$1" key="$2" value="$3"
  case "$key" in
    REPO)
      [[ "$value" =~ ^[^/]+/[^/]+$ ]] || {
        echo "gh pr-tools: REPO must be owner/name (got '$value')" >&2; exit 1; }
      assert_repo_unique "$name" "$value"
      ;;
    ORG|GH_USERNAME)
      [ -n "$value" ] || {
        echo "gh pr-tools: $key must not be empty, and is required — give it another value" >&2
        exit 1; }
      ;;
    APPROVAL_THRESHOLD)
      { [[ "$value" =~ ^[0-9]+$ ]] && [ "$value" -ge 1 ]; } || {
        echo "gh pr-tools: APPROVAL_THRESHOLD must be a positive integer (got '$value')" >&2; exit 1; }
      ;;
    GH_PR_TOOLS_TEAM_CACHE)
      valid_gh_duration "$value" || {
        echo "gh pr-tools: $key must be a duration like 30m, 1h30m, or 0 (got '$value')" >&2; exit 1; }
      ;;
    # THREAD_WATCH_USERS is deliberately unvalidated — a login that never
    # opened a thread and one that doesn't exist look the same, and checking
    # would cost a network call. JIRA_SITE is normalized by the caller.
    *) ;;
  esac
}

# The profile is a shell file that can hold keys this command doesn't know
# about (GH_PR_TOOLS_TEAM_CACHE is documented as profile-settable, and people
# hand-edit these), so the rewrite is line-oriented: the matching KEY= line is
# replaced where it stands and every other line is copied through untouched.
# Values are %q-quoted exactly as init writes them.
#
# $1 = profile path, $2 = key, $3 = value, $4 = "delete" to drop the line.
# Returns non-zero only when a "delete" found nothing to remove, which `unset`
# reports as "nothing changed" — so every other caller must guard it with
# `|| true` or use it in a condition, or set -e will abort on that case.
rewrite_profile_key() {
  local path="$1" key="$2" value="${3:-}" mode="${4:-set}" tmp line seen=0
  # Created in the same directory so the mv is atomic, and unreadable to
  # anyone else from the start — the file can hold a Jira API token.
  tmp=$(umask 077; mktemp "$path.XXXXXX")
  # Cleared once the mv lands. Until then a signal or a failed write must not
  # leave a half-written file sitting in $profiles_dir.
  trap 'rm -f "$tmp"' EXIT INT TERM
  while IFS= read -r line || [ -n "$line" ]; do
    # Leading blanks and an "export " prefix source to the same assignment,
    # so both have to count as the key being present — otherwise unset reports
    # success while the old line stays live, and set leaves a stale duplicate
    # above the new one. Keys come from settable_keys, so they are [A-Z_] only
    # and safe to interpolate into the pattern.
    if [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?${key}= ]]; then
      # Rewrite the first occurrence where it stands and drop any later
      # duplicate: sourcing the file would have used the last one, so
      # collapsing them changes nothing about how it reads.
      if [ "$mode" = "set" ] && [ "$seen" -eq 0 ]; then
        printf '%s=%q\n' "$key" "$value" >> "$tmp"
      fi
      seen=1
      continue
    fi
    printf '%s\n' "$line" >> "$tmp"
  done < "$path"
  if [ "$mode" = "set" ] && [ "$seen" -eq 0 ]; then
    printf '%s=%q\n' "$key" "$value" >> "$tmp"
  fi
  mv "$tmp" "$path"
  trap - EXIT INT TERM
  chmod 600 "$path"
  [ "$seen" -eq 1 ] || [ "$mode" = "set" ]
}

cmd="${1:-list}"
[ $# -gt 0 ] && shift || true

case "$cmd" in
  list)
    names=$(list_profile_names)
    if [ -z "$names" ]; then
      echo "(no profiles — run: gh pr-tools init)"
      exit 0
    fi
    cwd=$(cwd_repo 2>/dev/null || true)
    while IFS= read -r name; do
      [ -n "$name" ] || continue
      markers=""
      if [ -n "$cwd" ] && [ "$(profile_repo "$name" || true)" = "$cwd" ]; then
        markers="(cwd)"
      fi
      printf '%s%s\n' "$name" "${markers:+ $markers}"
    done <<< "$names"
    ;;
  show)
    if [ -n "${1:-}" ]; then
      require_profile_exists "$1"
      name="$1"
    else
      name=$(resolve_profile)
    fi
    echo "profile: $name"
    # shellcheck source=/dev/null
    source "$(profile_path "$name")"
    echo "REPO=$REPO"
    echo "ORG=$ORG"
    echo "GH_USERNAME=${GH_USERNAME:-}"
    normalize_jira_config
    echo "JIRA_PREFIX=${JIRA_PREFIX:-}"
    echo "JIRA_SITE=${JIRA_SITE:-}"
    echo "JIRA_BASE_URL=${JIRA_BASE_URL:-}"
    echo "JIRA_EMAIL=${JIRA_EMAIL:-}"
    echo "JIRA_CLOUD_ID=${JIRA_CLOUD_ID:-}"
    echo "JIRA_API_BASE=$(jira_api_base)"
    # Presence only — printing the token would defeat the file mode.
    echo "JIRA_API_TOKEN=$([ -n "${JIRA_API_TOKEN:-}" ] && echo '(set)' || echo '(not set)')"
    echo "APPROVAL_THRESHOLD=${APPROVAL_THRESHOLD:-1}"
    echo "THREAD_WATCH_USERS=${THREAD_WATCH_USERS:-}"
    echo "GH_PR_TOOLS_TEAM_CACHE=${GH_PR_TOOLS_TEAM_CACHE:-$team_cache_default}"
    ;;
  set)
    # ${1:?} inside a command substitution only kills the subshell, so the
    # error it prints is bash's raw diagnostic — check up front instead.
    [ $# -gt 0 ] || { usage; exit 1; }
    key=$(canonical_key "$1")
    shift
    assert_known_key "$key"
    # An unquoted "a, b" arrives as two arguments and would otherwise be
    # written as "a," with the rest dropped and nothing said about it.
    [ $# -le 1 ] || {
      echo "gh pr-tools: too many arguments — quote the value if it contains spaces or commas" >&2
      exit 1; }
    name=$(resolve_profile)
    path=$(profile_path "$name")

    if [ "$key" = "JIRA_API_TOKEN" ]; then
      # Never off argv: a command line is visible to `ps` for as long as it
      # runs and lands in shell history besides. init prompts hidden for the
      # same reason.
      [ $# -eq 0 ] || {
        echo "gh pr-tools: don't pass the Jira API token on the command line —" \
             "run 'gh pr-tools profile set jira-api-token' and paste it at the prompt" >&2
        exit 1; }
      read -rsp "Jira API token (hidden): " value || {
        echo; echo "gh pr-tools: aborted — nothing changed" >&2; exit 1; }
      echo
      [ -n "$value" ] || { echo "gh pr-tools: no token entered — nothing changed" >&2; exit 1; }
    elif [ $# -gt 0 ]; then
      value="$1"
    else
      read -rp "$key: " value || {
        echo "gh pr-tools: aborted — nothing changed" >&2; exit 1; }
    fi

    validate_profile_value "$name" "$key" "$value"

    if [ "$key" = "JIRA_SITE" ]; then
      value=$(normalize_jira_site_input "$value")
    fi

    rewrite_profile_key "$path" "$key" "$value"

    # A cloud ID belongs to one site and is only worth storing once there is
    # a token to use it with, so both keys that can invalidate it reconcile it
    # here rather than only JIRA_SITE. Covering the token is what stops "add a
    # token to an existing profile" from ending with a token and no cloud ID —
    # a state init cannot produce, and one where jira_api_base falls back to
    # the site host, which on some orgs answers a valid token as an anonymous
    # user (see its comment) and blanks JIRA STATUS with no diagnostic.
    case "$key" in
      JIRA_SITE|JIRA_API_TOKEN)
        # Read the stored values back through a subshell rather than sourcing
        # into this one: the profile is a shell file and a hand-added lowercase
        # key could otherwise shadow $path or $value here.
        jira_state=$( ( source "$path" >/dev/null; \
                        printf '%s\n%s' "${JIRA_SITE:-}" "${JIRA_API_TOKEN:+yes}" ) )
        site="${jira_state%%$'\n'*}"
        has_token="${jira_state##*$'\n'}"
        cloud_id=""
        if [ -n "$site" ] && [ "$has_token" = yes ]; then
          cloud_id=$(jira_lookup_cloud_id "$site" || true)
        fi
        if [ -n "$cloud_id" ]; then
          rewrite_profile_key "$path" JIRA_CLOUD_ID "$cloud_id"
          echo "Resolved Jira cloud ID $cloud_id"
        else
          rewrite_profile_key "$path" JIRA_CLOUD_ID "" delete || true
          if [ -n "$site" ] && [ "$has_token" = yes ]; then
            echo "gh pr-tools: could not resolve a Jira cloud ID from $site —" \
                 "requests will go to the site host" >&2
          fi
        fi
        ;;
    esac

    # The token is the one value never echoed back, for the same reason it is
    # never printed by `show`.
    if [ "$key" = "JIRA_API_TOKEN" ]; then
      echo "Set $key in profile '$name'"
    else
      echo "Set $key=$value in profile '$name'"
    fi
    ;;
  unset)
    [ $# -gt 0 ] || { usage; exit 1; }
    key=$(canonical_key "$1")
    shift
    assert_known_key "$key"
    [ $# -eq 0 ] || { echo "gh pr-tools: unset takes a single key" >&2; exit 1; }
    for required in $required_keys; do
      if [ "$key" = "$required" ]; then
        echo "gh pr-tools: $key is required — set it to another value instead of unsetting it" >&2
        exit 1
      fi
    done
    name=$(resolve_profile)
    path=$(profile_path "$name")
    if rewrite_profile_key "$path" "$key" "" delete; then
      echo "Unset $key in profile '$name'"
    else
      echo "$key was not set in profile '$name' — nothing changed"
    fi
    ;;
  remove)
    name="${1:?usage: gh pr-tools profile remove <name>}"
    require_profile_exists "$name"
    rm -f "$(profile_path "$name")"
    echo "Removed profile '$name'"
    ;;
  *)
    usage
    exit 1
    ;;
esac
