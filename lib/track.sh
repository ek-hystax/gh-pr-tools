#!/usr/bin/env bash
# gh pr-tools track — the repo's open PRs (up to --limit), or just the ones
# you name.
set -euo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$dir/common.sh"

long=false
short_links=false
short_labels=false
watch=false
watch_interval=5m
limit=50
refs=()
list_given=false
command_args=()

usage_err() {
  echo "gh pr-tools track: $1" >&2
  echo "usage: gh pr-tools track [--long|-l] [--short-links|-s] [--short-labels|-S] [--limit|-L N] [--list|-f FILE] [--watch|-w[=INTERVAL]] [PR...]" >&2
  exit 1
}

# Read a PR list file into $refs: one reference per line, in the same forms
# the command line accepts. Expanded here, at parse time, so a list and any
# PRs named directly on the command line keep the order they were written in
# rather than the lists all sorting ahead of the arguments.
#
# Only the *path* goes into $command_args, never the expanded contents, which
# is what makes the file hot-swappable: --watch re-executes this script on
# every refresh, so each refresh re-reads the file and picks up whatever it
# says now.
#
# Each line is trimmed of surrounding whitespace first, so indentation never
# changes what a line means. Blank lines are skipped. A line starting with "#"
# is a comment unless a digit follows the "#" directly: "#1154" is how people
# write a PR, and a list is exactly where they write it. Anything that starts
# out as a reference stays one — "#1204 note here" reaches ref_to_number and
# gets its "skipped" warning, the same as "1204 note here" would, rather than
# vanishing as a comment. Past the first word, a "#" after whitespace starts a
# trailing comment. A "#" with no whitespace before it is left alone, which is
# why a URL copied out of a review thread keeps its "#discussion_r..."
# fragment; that is harmless, since ref_to_number reads only the
# <owner>/<repo>/pull/<n> part of a link. A trailing CR is dropped so a file
# written on Windows works, and a UTF-8 byte-order mark (which some Windows
# editors put at the start of the file) so it does not glue onto the first
# entry.
read_list_into_refs() {
  local path="$1" line first=true
  if [ ! -f "$path" ] || [ ! -r "$path" ]; then
    # Editors save atomically — write-a-temp-then-rename, or truncate-then-
    # write — so a file being watched is briefly missing or empty every time
    # it is saved. Killing a long-running watch at the exact moment its list
    # is edited would defeat the point of watching the list, so a refresh
    # skips an unreadable file and tries again on the next one.
    #
    # Only a refresh does that. Arguments are parsed — and so lists read — in
    # the process that starts a watch too, before it hands over to
    # refresh_command, and that process is not a watch child: a path that
    # cannot be read when the watch *starts* is a mistake in the invocation
    # and fails right here, as it does outside a watch, where there is
    # nothing to come back for.
    if [ -n "${GH_PR_TOOLS_TRACK_WATCH_CHILD:-}" ]; then
      echo "gh pr-tools track: list file '$path' is unreadable right now — skipped this refresh" >&2
      return 0
    fi
    usage_err "cannot read list file '$path'"
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    if [ "$first" = true ]; then
      line="${line#$'\xEF\xBB\xBF'}"
      first=false
    fi
    line="${line#"${line%%[![:space:]]*}"}"
    [ -n "$line" ] || continue
    if [[ "$line" == \#* ]] && ! [[ "$line" == \#[0-9]* ]]; then continue; fi
    line="${line%%[[:space:]]#*}"
    line="${line%"${line##*[![:space:]]}"}"
    refs+=("$line")
  done < "$path"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --long|-l) long=true; command_args+=("$1"); shift ;;
    --short-links|-s) short_links=true; command_args+=("$1"); shift ;;
    --short-labels|-S) short_labels=true; command_args+=("$1"); shift ;;
    --limit|-L)
      [ $# -ge 2 ] || usage_err "$1 requires a number"
      limit="$2"; command_args+=("$1" "$2"); shift 2 ;;
    --limit=*|-L=*) limit="${1#*=}"; command_args+=("$1"); shift ;;
    --list|-f)
      [ $# -ge 2 ] || usage_err "$1 requires a path to a list file"
      list_given=true; command_args+=("$1" "$2")
      read_list_into_refs "$2"; shift 2 ;;
    --list=*|-f=*)
      list_given=true; command_args+=("$1")
      read_list_into_refs "${1#*=}"; shift ;;
    --watch|-w)
      watch=true
      # A separate interval needs a unit here, as in prd: a bare number could
      # just as well be a PR — see is_watch_interval_arg in common.sh.
      if [ $# -gt 1 ] && is_watch_interval_arg "$2"; then watch_interval="$2"; shift 2
      else shift
      fi
      ;;
    --watch=*|-w=*) watch=true; watch_interval="${1#*=}"; shift ;;
    -*) usage_err "unknown option '$1' (supported: --long, --short-links, --short-labels, --limit N, --list FILE, --watch[=INTERVAL])" ;;
    *) refs+=("$1"); command_args+=("$1"); shift ;;
  esac
done

# ^[1-9][0-9]*$ rather than ^[0-9]+$ for the reason stale-branches gives: gh
# reads a leading-zero numeral as octal, so "010" would quietly mean 8.
[[ "$limit" =~ ^[1-9][0-9]*$ ]] || usage_err "invalid --limit '$limit' (expected a positive integer)"

if [ "$watch" = true ]; then
  watch_seconds=$(watch_interval_seconds "$watch_interval") || {
    echo "gh pr-tools track: invalid watch interval '$watch_interval' (expected e.g. 30s, 5m, or 1h)" >&2
    exit 1
  }
  watch_label="gh pr-tools track"
  [ "${#command_args[@]}" -eq 0 ] || watch_label+=" ${command_args[*]}"
  # Marks the refreshes as watch children, which tolerate a list file going
  # missing mid-edit — see read_list_into_refs. That is the only leniency
  # they get: PRs named on the command line cannot change between refreshes,
  # so the checks below that refuse a command line naming nothing usable
  # apply to every refresh, and the first refresh failing them ends the watch
  # before it draws a frame (see refresh_command).
  export GH_PR_TOOLS_TRACK_WATCH_CHILD=1
  refresh_command "$watch_seconds" "$watch_interval" "$watch_label" "$0" "${command_args[@]+"${command_args[@]}"}"
fi

load_config

ticket_pattern="${JIRA_PREFIX:-[A-Za-z]+}-[0-9]+"

# Turn one PR argument into a bare number. Two forms are accepted: a plain
# number, and a GitHub PR link.
#
# Either way the number is normalised before it goes anywhere: "0160" is a
# perfectly natural thing to type or to find in a spreadsheet export, but
# spliced into the GraphQL query it is not an Int literal, and the syntax
# error fails the whole batch — one zero-padded entry would blank every row.
# Normalised, "0160" and "160" are also the same PR to the de-duplication
# below. Zero is no PR at all, and anything past GraphQL's 32-bit Int range
# would fail the batch the same way, so both are refused here with a warning
# of their own.
#
# Links are matched on the <owner>/<repo>/pull/<n> tail rather than by taking
# the URL's last path segment the way resolve_pr does for Jira links, because
# the usual way to copy a PR URL is from a review page — .../pull/1154/files
# and .../pull/1154/commits are at least as common as the bare form, and a
# last-segment rule reads "files" out of them. Matching the tail rather than
# the host also means a GitHub Enterprise URL works unchanged.
#
# The link names its own repo, which is worth checking: a link pasted from
# another repo would otherwise resolve to whatever #1154 happens to be in
# this one and be displayed as though it were the PR that was asked for.
# Wrong data presented confidently is worse than an error, so a mismatch is
# refused.
ref_to_number() {
  local ref="$1" owner_repo num
  # "#1154" is how people write a PR reference, and it is what a list file
  # tends to contain; the bare number is the same thing.
  ref="${ref#\#}"
  if [[ "$ref" =~ ^[0-9]+$ ]]; then
    num="$ref"
  elif [[ "$ref" =~ ([A-Za-z0-9._-]+/[A-Za-z0-9._-]+)/pull/([0-9]+) ]]; then
    owner_repo="${BASH_REMATCH[1]}"
    num="${BASH_REMATCH[2]}"
    if [ "$(tr '[:upper:]' '[:lower:]' <<<"$owner_repo")" != "$(tr '[:upper:]' '[:lower:]' <<<"$REPO")" ]; then
      echo "gh pr-tools track: $ref points at $owner_repo, not $REPO — skipped" >&2
      return 1
    fi
  else
    echo "gh pr-tools track: '$ref' is not a PR number or a GitHub PR link — skipped" >&2
    return 1
  fi
  # Leading zeros are allowed, but at most ten significant digits: the range
  # check is then arithmetic on a value that cannot overflow, and 10# forces
  # base ten, since bash reads a leading-zero numeral as octal (and rejects
  # "08" outright).
  if ! [[ "$num" =~ ^0*[1-9][0-9]{0,9}$ ]] || [ "$((10#$num))" -gt 2147483647 ]; then
    echo "gh pr-tools track: '$ref' is not a valid PR number — skipped" >&2
    return 1
  fi
  printf '%s\n' "$((10#$num))"
}

# One bad reference must not cost you the other nineteen rows, so an argument
# that cannot be resolved warns on stderr and is dropped; stdout stays a
# clean, pipeable table. Duplicates are dropped on first occurrence, keeping
# the order they were given in.
numbers=()
for ref in "${refs[@]+"${refs[@]}"}"; do
  if n=$(ref_to_number "$ref"); then
    seen=false
    for existing in "${numbers[@]+"${numbers[@]}"}"; do
      if [ "$existing" = "$n" ]; then seen=true; break; fi
    done
    if [ "$seen" = false ]; then numbers+=("$n"); fi
  fi
done

# A list is data that legitimately changes, so a list naming nothing usable —
# empty, all comments, or mid-save — means an empty board, not a failure. PRs
# typed straight onto the command line are different: none of them resolving
# means the invocation was wrong, and saying so beats printing a bare header
# row. "Resolving" is checked twice — here for references that are not PRs at
# all, and after the fetch for numbers with no PR behind them — and applies
# under a watch too, where only the list file is expected to change.
filtered=false
if [ "$list_given" = true ] || [ "${#refs[@]}" -gt 0 ]; then filtered=true; fi

if [ "$filtered" = true ] && [ "${#numbers[@]}" -eq 0 ] && [ "$list_given" != true ]; then
  echo "gh pr-tools track: no usable PR references" >&2
  exit 1
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

if [ "${#numbers[@]}" -gt 0 ]; then
  # Explicit references bypass every filter the unfiltered listing applies:
  # if you named a PR you see it, whatever state it is in. A tracked list
  # that quietly loses rows as they merge is indistinguishable from a
  # tracked list that was wrong, which is the failure this avoids — the
  # STATE column is what carries the difference.
  order=$(printf '%s\n' "${numbers[@]}" | jq -R 'select(length > 0) | tonumber' | jq -s .)
  prs=$(fetch_prs_by_number "$(printf '%s\n' "${numbers[@]}")" "$long")
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    echo "gh pr-tools track: no PR #$n in $REPO — skipped" >&2
  done <<<"$(jq -r --argjson want "$order" '([.[].number]) as $got | ($want - $got)[]' <<<"$prs")"
  if [ "$list_given" != true ] && [ "$(jq 'length' <<<"$prs")" -eq 0 ]; then
    echo "gh pr-tools track: none of the named PRs exist in $REPO" >&2
    exit 1
  fi
elif [ "$filtered" = true ]; then
  # Asked for a specific set and it came out empty. Render the header row and
  # stop — falling through to the branch below would answer a question nobody
  # asked by listing every PR in the repo.
  order='[]'
  prs='[]'
else
  # No -is:draft here, unlike todo/mine: this is a board rather than a work
  # queue, and a draft PR aimed at the release is exactly the kind of thing
  # worth seeing coming. Own PRs are not excluded either — the listing is
  # about the repo, not about you.
  #
  # Fields beyond the default columns (size, merge status) cost real time,
  # even though gh resolves the whole --json set in a single GraphQL request
  # per page: those selections are computed per PR on GitHub's side, so a
  # repo-wide page goes from around a second to around ten. Only ask for
  # them under --long. statusCheckRollup is the one expensive field always
  # paid for, since CI is part of the default view.
  fields="number,title,author,url,state,isDraft,createdAt,updatedAt,headRefName,headRefOid,reviews,statusCheckRollup"
  if [ "$long" = true ]; then
    fields="$fields,changedFiles,additions,deletions,mergeable,mergeStateStatus"
  fi
  order='[]'
  # One row past the limit is asked for so that a cut-off listing can say so.
  # Oldest-first means the rows lost to the limit are the newest PRs — the
  # ones least likely to be missed at a glance — so dropping them silently
  # would leave a board that looks complete and is not.
  prs=$(gh pr list --repo "$REPO" --search "is:open sort:created-asc" --limit "$((limit + 1))" --json "$fields")
  if [ "$(jq 'length' <<<"$prs")" -gt "$limit" ]; then
    prs=$(jq -c --argjson n "$limit" '.[:$n]' <<<"$prs")
    echo "gh pr-tools track: showing the oldest $limit open PRs; there are more — raise --limit to see them" >&2
  fi
fi

# Review threads and Jira statuses, exactly as mine fetches them — see
# fetch_threads_and_jira_statuses in common.sh, which sets $watch_users,
# $threads and $jira_statuses — except for two arguments. The ticket key is
# read from the branch or the title, matching track's JIRA column. And the
# "me" login, which fetch_pr_review_state attributes its "mine" bucket to, is
# empty: track has no such column — THREADS here counts every thread a
# watched login did not open, whoever that was — so an empty login leaves
# that bucket empty and unread, and saves resolving the current user at all.
# The buckets track does read are relative to each PR's own author, not to
# whoever is running the command.
fetch_threads_and_jira_statuses "$prs" "" jiraKeyFromBranchOrTitle "$tmp"

jq -rn -L "$dir" \
  --argjson threads "$threads" \
  --argjson watchUsers "$watch_users" \
  --argjson jiraStatuses "$jira_statuses" \
  --argjson approvalThreshold "${APPROVAL_THRESHOLD:-1}" \
  --argjson order "$order" \
  --arg jiraBase "${JIRA_BASE_URL:-}" \
  --arg jiraPattern "$ticket_pattern" \
  --argjson long "$long" \
  --argjson shortLinks "$short_links" \
  --argjson shortLabels "$short_labels" \
  -f "$dir/track.jq" <<<"$prs"
