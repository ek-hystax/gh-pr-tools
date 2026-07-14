#!/usr/bin/env bash
# gh pr-tools notify <pr-number | TICKET-123 | jira-link | branch-name>
# Poll a PR's CI checks every 5s; macOS notification once they finish.
set -euo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$dir/common.sh"
load_config

arg="${1:?usage: gh pr-tools notify <pr-number | TICKET-123 | jira-link | branch-name>}"
ticket_pattern="${JIRA_PREFIX:-[A-Za-z]+}-[0-9]+"
pr=$(resolve_pr "$arg")

info=$(gh pr view "$pr" --repo "$REPO" --json title,url)
title=$(jq -r .title <<<"$info")
url=$(jq -r .url <<<"$info")
echo "Watching #$pr — $title"
echo "$url"

# PR titles come from GitHub and may contain double quotes or backslashes —
# escape them before embedding in an AppleScript string literal.
osa_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

# Desktop notifications are macOS-only; everywhere else this is a silent no-op
# and the terminal status line is the only feedback.
notify_supported() { [ "$(uname -s)" = "Darwin" ] && command -v osascript >/dev/null 2>&1; }

# "DefaultSoundName" is NSUserNotificationDefaultSoundName — the stock macOS
# notification chime (what e.g. the Claude app plays), not a /System/Library/Sounds name.
# Best-effort: an osascript failure must not change the command's exit code.
notify_mac() { # $1 title, $2 message, $3 sound
  notify_supported || return 0
  osascript -e "display notification \"$(osa_escape "$2")\" with title \"$(osa_escape "$1")\" sound name \"$3\"" || true
}

while :; do
  json=$(gh pr view "$pr" --repo "$REPO" --json statusCheckRollup)
  # First line: "STATE\tHUMAN STATUS"; on fail, the rest is one failed check name per line.
  out=$(jq -r -f "$dir/notify.jq" <<<"$json")
  first="${out%%$'\n'*}"
  IFS=$'\t' read -r state line <<<"$first"
  printf '\r\033[K[%s] %s' "$(date +%H:%M:%S)" "$line"
  case "$state" in
    pending) sleep 5 ;;
    pass)
      echo
      notify_mac "✅ CI passed — #$pr" "$title" "DefaultSoundName"
      exit 0
      ;;
    fail)
      echo
      [ "$out" != "$first" ] && printf '%s\n' "${out#*$'\n'}"
      notify_mac "❌ CI failed — #$pr" "$title" "DefaultSoundName"
      exit 1
      ;;
  esac
done
