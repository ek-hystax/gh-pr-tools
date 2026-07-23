#!/usr/bin/env bash
# gh pr-tools stale-branches — closed PRs whose head branch still exists.
set -euo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$dir/common.sh"
load_config

limit=1000
author=""
author_set=false
show_all=false
while [ $# -gt 0 ]; do
  case "$1" in
    --limit|-L)
      [ $# -ge 2 ] || { echo "gh pr-tools stale-branches: $1 requires a number" >&2; exit 1; }
      limit="$2"
      shift 2
      ;;
    --limit=*) limit="${1#*=}"; shift ;;
    --author|-a)
      [ $# -ge 2 ] || { echo "gh pr-tools stale-branches: $1 requires a GitHub login" >&2; exit 1; }
      author="$2"
      author_set=true
      shift 2
      ;;
    --author=*) author="${1#*=}"; author_set=true; shift ;;
    --all) show_all=true; shift ;;
    *) echo "gh pr-tools stale-branches: unknown option '$1' (supported: --limit N, --author LOGIN, --all)" >&2; exit 1 ;;
  esac
done
# ^[1-9][0-9]*$ (not ^[0-9]+$) so a leading zero (e.g. "010") is rejected
# outright, rather than silently reaching bash arithmetic later, which
# parses a leading-zero numeral as octal.
[[ "$limit" =~ ^[1-9][0-9]*$ ]] || {
  echo "gh pr-tools stale-branches: --limit must be a positive integer" >&2
  exit 1
}
if [ "$author_set" = true ] && [ "$show_all" = true ]; then
  echo "gh pr-tools stale-branches: --author and --all are mutually exclusive" >&2
  exit 1
fi
# GitHub login rules: alphanumeric, single internal hyphens, no leading/
# trailing hyphen, max 39 chars. Rejects an empty value too (--author ""),
# which would otherwise silently fall through to the author:@me default
# below, and rejects whitespace/multi-word values that GitHub's search
# would otherwise reinterpret as extra free-text search terms rather than
# erroring.
if [ "$author_set" = true ] && ! [[ "$author" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,37}[A-Za-z0-9])?$ ]]; then
  echo "gh pr-tools stale-branches: --author must be a valid GitHub login (got '$author')" >&2
  exit 1
fi

# Default stays "mine" (author:@me) so a plain `stale-branches` matches
# mine/todo's own default scope; --author lets you check someone else's
# leftovers (e.g. a manager spot-checking a report), --all drops the author
# filter entirely to scan the whole repo.
if [ "$show_all" = true ]; then
  author_clause=""
  show_author=true
elif [ "$author_set" = true ]; then
  author_clause="author:$author"
  show_author=true
else
  author_clause="author:@me"
  show_author=false
fi

# is:closed matches both merged and closed-without-merge PRs (GitHub search
# treats "merged" as a subset of "closed") — scanning both catches abandoned
# branches from PRs that were closed without merging, not just the
# forgot-to-delete-after-merge case. One paginated GraphQL query covers both
# "list matching closed PRs" and "does the head branch still exist" — see
# fetch_closed_prs_with_branch_status in common.sh.
result=$(fetch_closed_prs_with_branch_status "$limit" "$author_clause")
prs=$(jq '.prs' <<<"$result")

# GitHub's search index itself caps any single query at 1000 results, no
# matter what --limit asks for — there's no "branch still exists" qualifier
# to filter narrower than that. `.truncated` (set by
# fetch_closed_prs_with_branch_status from the last page's own hasNextPage)
# is true only when the fetch actually stopped short of the full result set
# — unlike comparing the returned count against min(limit, 1000), which
# false-positives whenever the true total happens to equal that cap exactly
# even though nothing was cut off. Say so instead of silently under-reporting
# (the #317 bug this replaced). --all hits this far sooner since it's
# scanning the whole repo, not one author.
if [ "$(jq -r '.truncated' <<<"$result")" = "true" ]; then
  count=$(jq 'length' <<<"$prs")
  echo "gh pr-tools stale-branches: scanned $count closed PRs and hit the cap (GitHub search maxes out at 1000 results per query$([ "$limit" -lt 1000 ] && echo "; your --limit $limit is lower still")) — older closed PRs may not have been scanned." >&2
fi

jq -rn -L "$dir" \
  --argjson showAuthor "$show_author" \
  -f "$dir/stale-branches.jq" <<<"$prs"
