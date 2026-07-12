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
  import)
    src="${1:--}"
    json_mode=false
    if [ "$src" = "--json" ]; then
      json_mode=true
      src="${2:--}"
    fi

    if [ "$src" = "-" ]; then
      input=$(cat)
    else
      [ -f "$src" ] || { echo "gh pr-tools: no such file: $src" >&2; exit 1; }
      input=$(cat "$src")
    fi

    if $json_mode; then
      additions="$input"
      echo "$additions" | jq -e 'type == "object"' >/dev/null \
        || { echo "gh pr-tools: --json input must be a {\"login\": \"handle\"} object" >&2; exit 1; }
    else
      # Lines of "<login> <handle>" or "<login>,<handle>"; blank lines and
      # lines starting with # are skipped.
      additions=$(echo "$input" | jq -Rn '
        [inputs
         | gsub("^\\s+|\\s+$"; "")
         | select(length > 0 and (startswith("#") | not))
         | (if test(",") then split(",") else split("\\s+"; "") end)
         | select(length >= 2)
         | {key: .[0], value: .[1]}]
        | from_entries')
    fi

    count=$(echo "$additions" | jq 'length')
    [ "$count" -eq 0 ] && { echo "gh pr-tools: no valid entries found in $src" >&2; exit 1; }

    tmp=$(mktemp)
    jq --argjson add "$additions" '. + $add' "$tgmap_file" > "$tmp" && mv "$tmp" "$tgmap_file"
    echo "Imported $count mapping(s):"
    echo "$additions" | jq -r 'to_entries[] | "  \(.key) -> https://t.me/\(.value)"'
    ;;
  list)
    if [ "$(jq 'length' "$tgmap_file")" -eq 0 ]; then
      echo "(empty — add someone with: gh pr-tools tg add <github-login> <telegram-handle>)"
    else
      jq -r 'to_entries[] | "\(.key)\thttps://t.me/\(.value)"' "$tgmap_file"
    fi
    ;;
  *)
    echo "usage: gh pr-tools tg <add|remove|list|import> ..." >&2
    exit 1
    ;;
esac
