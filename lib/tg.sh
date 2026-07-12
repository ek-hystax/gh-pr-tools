#!/usr/bin/env bash
# gh pr-tools tg add|remove|list — manage the local GitHub-login -> Telegram map.
set -euo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$dir/common.sh"

mkdir -p "$config_dir"
[ -f "$tgmap_file" ] || echo '{}' > "$tgmap_file"

cmd="${1:-list}"
[ $# -gt 0 ] && shift || true

case "$cmd" in
  add)
    login="${1:?usage: gh pr-tools tg add <github-login> <telegram-handle>}"
    handle="${2:?usage: gh pr-tools tg add <github-login> <telegram-handle>}"
    tmp=$(mktemp)
    jq --arg l "$login" --arg h "$handle" '.[$l] = $h' "$tgmap_file" > "$tmp" && mv "$tmp" "$tgmap_file"
    echo "Added $login -> https://t.me/$handle"
    ;;
  remove)
    login="${1:?usage: gh pr-tools tg remove <github-login>}"
    tmp=$(mktemp)
    jq --arg l "$login" 'del(.[$l])' "$tgmap_file" > "$tmp" && mv "$tmp" "$tgmap_file"
    echo "Removed $login"
    ;;
  list)
    if [ "$(jq 'length' "$tgmap_file")" -eq 0 ]; then
      echo "(empty — add someone with: gh pr-tools tg add <github-login> <telegram-handle>)"
    else
      jq -r 'to_entries[] | "\(.key)\thttps://t.me/\(.value)"' "$tgmap_file"
    fi
    ;;
  *)
    echo "usage: gh pr-tools tg <add|remove|list> ..." >&2
    exit 1
    ;;
esac
