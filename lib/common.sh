#!/usr/bin/env bash
# Shared config/tg-map loading for all gh-pr-tools subcommands.

config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/gh-pr-tools"
config_file="$config_dir/config.sh"
tgmap_file="$config_dir/tg-map.json"

load_config() {
  if [ ! -f "$config_file" ]; then
    echo "gh pr-tools: not configured yet — run: gh pr-tools init" >&2
    exit 1
  fi
  # shellcheck source=/dev/null
  source "$config_file"
  : "${REPO:?REPO missing in $config_file — re-run: gh pr-tools init}"
  : "${ORG:?ORG missing in $config_file — re-run: gh pr-tools init}"
}

tgmap_json() {
  if [ -f "$tgmap_file" ]; then cat "$tgmap_file"; else echo '{}'; fi
}
