#!/usr/bin/env bash
# gh pr-tools init — create or update a named profile for this machine.
set -euo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$dir/common.sh"

mkdir -p "$profiles_dir"
chmod 700 "$config_dir" "$profiles_dir"

default_repo=$(cwd_repo 2>/dev/null || true)

default_name="default"
if [ -n "$default_repo" ]; then
  default_name=$(suggest_profile_name "${default_repo##*/}")
fi

read -rp "Profile name [$default_name]: " name
name="${name:-$default_name}"
validate_profile_name "$name"

read -rp "GitHub repo (owner/name)${default_repo:+ [$default_repo]}: " repo
repo="${repo:-$default_repo}"
[ -n "$repo" ] || { echo "gh pr-tools: repo is required" >&2; exit 1; }

assert_repo_unique "$name" "$repo"

default_org="${repo%%/*}"
read -rp "GitHub org for team-review lookups [$default_org]: " org
org="${org:-$default_org}"

default_username=$(gh api user --jq .login 2>/dev/null || true)
read -rp "Your GitHub username${default_username:+ [$default_username]}: " username
username="${username:-$default_username}"
[ -n "$username" ] || { echo "gh pr-tools: GitHub username is required" >&2; exit 1; }

read -rp "Jira ticket prefix, e.g. KF (blank = match any PROJECT-123 style ticket): " prefix

read -rp "Jira site, e.g. yourorg or https://yourorg.atlassian.net (blank = no Jira links): " jira_input
# Bare org or full URL, normalized to the site root — see normalize_jira_site_input.
jira_site=$(normalize_jira_site_input "$jira_input")

# The token is optional and only buys the ticket *status* column — links work
# without it — so every prompt below can be skipped with a blank answer.
jira_email=""
jira_api_token=""
if [ -n "$jira_site" ]; then
  echo
  echo "Optional: an API token lets todo/mine/prd show each ticket's Jira status."
  echo "Create one at https://id.atlassian.com/manage-profile/security/api-tokens"
  echo "A scoped token needs read:jira-work; a classic token needs no scopes."
  echo "It is stored in the profile file, which is created readable only by you."
  # No default offered: the Atlassian account is frequently not the git
  # committer identity, and a wrong default here fails as a 401 much later.
  read -rp "Jira account email (blank = links only): " jira_email
fi

if [ -n "$jira_site" ] && [ -n "$jira_email" ]; then
  read -rsp "Jira API token (hidden, blank = links only): " jira_api_token
  echo
fi

# Resolved once here rather than on every run. See jira_api_base for why the
# gateway is preferred over the site host; an empty value is fine and simply
# means requests go to the site host instead.
jira_cloud_id=""
if [ -n "$jira_api_token" ]; then
  jira_cloud_id=$(jira_lookup_cloud_id "$jira_site" || true)
  if [ -n "$jira_cloud_id" ]; then
    echo "Resolved Jira cloud ID $jira_cloud_id"
  else
    echo "gh pr-tools: could not resolve a Jira cloud ID from $jira_site —" \
         "requests will go to the site host" >&2
  fi
fi

read -rp "Approval threshold — approvals you personally require to call a PR \"Approved\" [1]: " threshold
threshold="${threshold:-1}"
if ! [[ "$threshold" =~ ^[0-9]+$ ]] || [ "$threshold" -lt 1 ]; then
  echo "gh pr-tools: approval threshold must be a positive integer" >&2
  exit 1
fi

# Nothing here is validated against GitHub: a login that never opened a thread
# and a login that does not exist both render an empty column, and a network
# check on every init is a poor trade for telling those two apart. A "[bot]"
# suffix is accepted and stripped at read time, since that is the spelling
# GitHub's UI shows even though the API this uses reports the bare login.
echo
echo "Optional: logins whose review threads get their own todo/mine column,"
echo "e.g. coderabbitai — their threads then stop inflating the THREADS column."
read -rp "Watch review threads by (comma-separated logins, blank = none): " watch_users

path=$(profile_path "$name")
# The profile can hold an API token, so create it unreadable to anyone else
# from the start rather than chmod-ing after the write — the file mode is the
# only thing protecting it. gh keeps its own config at 600 for the same reason.
(
  umask 077
  {
    printf 'REPO=%q\n' "$repo"
    printf 'ORG=%q\n' "$org"
    printf 'GH_USERNAME=%q\n' "$username"
    printf 'JIRA_PREFIX=%q\n' "$prefix"
    printf 'JIRA_SITE=%q\n' "$jira_site"
    printf 'JIRA_EMAIL=%q\n' "$jira_email"
    [ -n "$jira_cloud_id" ] && printf 'JIRA_CLOUD_ID=%q\n' "$jira_cloud_id"
    [ -n "$jira_api_token" ] && printf 'JIRA_API_TOKEN=%q\n' "$jira_api_token"
    printf 'APPROVAL_THRESHOLD=%q\n' "$threshold"
    printf 'THREAD_WATCH_USERS=%q\n' "$watch_users"
  } > "$path"
)
chmod 600 "$path"
unset jira_api_token

echo "Wrote $path"
echo "Next: gh pr-tools tg add <github-login> <telegram-handle>   (optional, per-person)"
