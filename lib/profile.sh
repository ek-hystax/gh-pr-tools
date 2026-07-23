#!/usr/bin/env bash
# gh pr-tools profile list|show|remove — manage named profiles.
set -euo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$dir/common.sh"

usage() {
  cat <<'EOF' >&2
usage: gh pr-tools profile <list|show|remove> ...
  list                 list all profiles, marking a checkout match with (cwd)
  show [name]          print a profile's settings (default: currently resolved)
  remove <name>        delete a profile
EOF
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
    echo "JIRA_PREFIX=${JIRA_PREFIX:-}"
    echo "JIRA_BASE_URL=${JIRA_BASE_URL:-}"
    echo "APPROVAL_THRESHOLD=${APPROVAL_THRESHOLD:-1}"
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
