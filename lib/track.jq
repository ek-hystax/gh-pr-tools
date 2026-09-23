include "common";

# Inputs supplied by track.sh: $threads, $watchUsers, $approvalThreshold,
# $jiraBase, $jiraPattern, $jiraStatuses, $order, $long, $shortLinks,
# $shortLabels

def ci: ciState;

# Unlike todo/mine, which read the ticket out of the branch name only, track
# falls back to the title the way prd does. This command lists the whole
# repo, so it covers authors who put the ticket in the title and never in the
# branch — for whom branch-only matching silently renders "-".
def jiraKey: jiraKeyFromBranchOrTitle($jiraPattern);
def jira: jiraCell($jiraBase; jiraKey; $shortLinks);

# GitHub reports state as OPEN/CLOSED/MERGED with draftness as a separate
# boolean; the four values users actually think in come from combining them.
# Title Case to match STATUS, the other column that says what a PR *is* —
# CI and MERGE stay lowercase, being mechanical check results.
def stateCell:
  if .state == "MERGED" then "Merged"
  elif .state == "CLOSED" then "Closed"
  elif (.isDraft // false) then "Draft"
  else "Open"
  end;

# Merged is green because it is the state this command exists to drive PRs
# toward — not "healthy", but "done". Closed is red because on a list someone
# deliberately typed out, an abandoned PR is a discrepancy worth seeing, not
# a neutral outcome.
def paintState:
  if . == "Merged" then green
  elif . == "Open" then cyan
  elif . == "Draft" then dim
  else red
  end;

# Merged and Closed rows are history, and most of what the table says about a
# live PR reads as a call to action on them. A PR merged three weeks ago
# would render PENDING SINCE bold red — badly overdue, when it is in fact
# finished — and STATUS a yellow "Awaiting Approval" that nobody is awaiting
# any more; its CI, approvals and threads are equally settled. So on a
# terminal row those columns keep their text, which is still true as history,
# but lose their color and render dim; STATE keeps its own color, since it is
# the column saying why. Same idea todo.jq applies to PENDING SINCE via
# needsMyAction. MERGE goes further and shows "-": GitHub keeps reporting a
# merged PR's last computed mergeability — a merged PR can still read
# CONFLICTING, which would render as a red "conflict" — and "can the button
# be pressed" has no answer once the PR is closed. Draft is state OPEN, so
# drafts are live and keep their colors. JIRA and JIRA STATUS are left alone:
# the ticket can still be moving after the PR has merged.
def settled: .state != "OPEN";

def dimWhenSettled($col):
  IN($col; "STATUS", "APPROVALS", "THREADS", "CI", "WAITING") or ($col | isWatchCol);

def waitingPaint: waitingPaintFor(.updatedAt);

# Watched-login columns (see watchCells in common.jq), identical in meaning to
# mine's: THREADS counts every thread a watched login did not open, each
# watched column counts the threads that login opened, and together they
# partition the PR's threads. The buckets fetch_pr_review_state produces are
# relative to the PR's own author, not to whoever is running the command, so
# they carry over to this viewer-neutral listing unchanged.
def watchCols: watchCols($watchUsers);
def watchHeaders: watchHeaders($watchUsers);
def watchCells: watchCells($watchUsers; $threads; $shortLabels);

def merge: if settled then "-" else mergeState end;

# Columns are named object keys, not positional array indices — see todo.jq
# for why.
def cells:
  {
    PR:         (if $shortLinks then "#\(.number)" else .url end),
    TITLE:      .title[0:80],
    AUTHOR:     .author.login,
    STATE:      stateCell,
    STATUS:     approvalDecision(._approvalStats; $approvalThreshold),
    APPROVALS:  approvalsCell(._approvalStats; $approvalThreshold; false),
    THREADS:    threadsCell(threadsUnwatched($threads); threadsTruncated($threads); $shortLabels),
    CI:         ci,
    WAITING:    isoRel(.updatedAt),
    JIRA:       jira,
    JIRA_STATUS: jiraStatusText($jiraStatuses; jiraKey),
    AGE:        isoRel(.createdAt),
    SIZE:       sizeCell,
    MERGE:      merge
  } + watchCells;

def headers:
  {
    PR: "PR", TITLE: "TITLE", AUTHOR: "AUTHOR", STATE: "STATE", STATUS: "STATUS",
    APPROVALS: "APPROVALS", THREADS: "THREADS", CI: "CI", WAITING: "PENDING SINCE",
    JIRA: "JIRA", JIRA_STATUS: "JIRA STATUS", AGE: "AGE", SIZE: "SIZE", MERGE: "MERGE"
  } + watchHeaders;

# Columns whose color depends only on their own cell text.
def paint($col):
  if   $col == "AUTHOR" then cyan
  elif $col == "STATE" then paintState
  elif $col == "STATUS" then paintDecision
  elif $col == "CI" then paintCi
  elif $col == "AGE" then dim
  elif $col == "MERGE" then paintMerge
  else . end;

# One colored cell, for renderTable (common.jq): input is {row, col, text}.
# A settled row's dimmed columns are decided first, from the plain text, so
# no column's own coloring can override it. Otherwise PR, SIZE, THREADS,
# watched-login columns, WAITING, JIRA, JIRA_STATUS and APPROVALS need the
# raw PR object, not just the cell text; everything else goes through
# paint($col).
def paintCell:
  .row as $pr
  | .col as $col
  | .text as $text
  | if ($pr | settled) and dimWhenSettled($col) then ($text | dim)
    elif $col == "PR" then ($text | linkStyle | hyperlink($pr.url))
    elif $col == "SIZE" then ($pr | sizePaint)
    elif $col == "THREADS" then ($pr | threadsPaint(threadsUnwatched($threads); threadsTruncated($threads); $shortLabels))
    elif ($col | isWatchCol) then ($pr | watchPaint($col; $threads; $shortLabels))
    elif $col == "WAITING" then ($pr | waitingPaint)
    elif $col == "JIRA" then ($pr | jiraCellPaint($jiraBase; jiraKey; $shortLinks))
    elif $col == "JIRA_STATUS" then ($pr | jiraStatusPaint($jiraStatuses; jiraKey))
    elif $col == "APPROVALS" then ($pr | approvalsPaint(._approvalStats; $approvalThreshold; false))
    else ($text | paint($col))
    end;

# Watched-login columns are spliced in directly after THREADS, in configured
# order, and appear in both column sets — always rendered, even when every row
# is "-", so the table keeps the same shape between runs. STATE is likewise
# always present: unfiltered it separates Open from Draft, and with explicit
# numbers it carries all four values.
def cols:
  (if $long then ["TITLE", "PR", "AUTHOR", "STATE", "STATUS", "APPROVALS", "THREADS", "CI", "WAITING", "JIRA", "JIRA_STATUS", "AGE", "SIZE", "MERGE"]
   else ["TITLE", "PR", "AUTHOR", "STATE", "STATUS", "APPROVALS", "THREADS", "CI", "WAITING", "JIRA", "JIRA_STATUS"]
   end) as $base
  | ($base | index("THREADS")) as $i
  | $base[0:$i + 1] + watchCols + $base[$i + 1:];

# With explicit PR references, the order they were given in is the order they
# are shown in: a list someone typed out is usually a merge order, and
# re-sorting it would throw that away. $order is empty for the unfiltered
# listing, which falls back to oldest-first like todo and mine.
def orderRows:
  if ($order | length) > 0 then
    ($order | to_entries | map({key: (.value | tostring), value: .key}) | from_entries) as $pos
    | sort_by($pos[.number | tostring] // 0)
  else sort_by(.createdAt)
  end;

# Main
#
# approvalStats takes the current user's team memberships to split APPROVALS
# into total vs. teammate counts. This listing is not about the current user,
# so the split is suppressed (approvalsCell/approvalsPaint get $showTeam
# false) and the empty roster below is what makes that honest — track never
# makes the team-membership lookup at all.
[inputs][0]
| (. | map(. + {_approvalStats: approvalStats(.author.login; [])}) | orderRows) as $rows
| renderTable($rows; cols; headers; cells; paintCell)
