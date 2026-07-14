#!/usr/bin/env bash
# gh pr-tools clear — remove all per-machine config created by `init`/`tg`.
set -euo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$dir/common.sh"

if [ ! -d "$config_dir" ]; then
  echo "gh pr-tools: nothing to clear ($config_dir does not exist)"
  exit 0
fi

force=0
[ "${1:-}" = "-y" ] || [ "${1:-}" = "--yes" ] && force=1

if [ "$force" -ne 1 ]; then
  read -rp "Remove $config_dir (profiles + tg map)? [y/N] " reply
  case "$reply" in
    y|Y|yes|YES) ;;
    *) echo "Aborted."; exit 1 ;;
  esac
fi

rm -rf "$config_dir"
echo "Removed $config_dir"
echo "Next: gh extension remove pr-tools   (to uninstall the extension itself)"
