include "common";

# Inputs supplied by mine.sh: $me, $threads, $teamLogins, $approvalThreshold,
# $jiraBase, $jiraPattern, $jiraStatuses, $long, $shortLinks, $shortLabels,
# $includeAssigned

def ci: ciState;
def jiraKey: jiraKeyFromBranch($jiraPattern);
def jira: jiraCell($jiraBase; jiraKey; $shortLinks);

def waitingPaint: waitingPaintFor(.updatedAt);

# AUTHOR only exists under --include-assigned, the one case where a row can
# be someone else's PR. It reads "-" on your own PRs, so the ones handed to
# you are the only rows with a login in them.
def authorCell: if .author.login == $me then "-" else .author.login end;

# Watched-login columns (see watchCells in common.jq). THREADS counts every
# thread a watched login didn't open (unwatched bucket) — reviewers', bots'
# and your own alike, since agents open threads under your login; each
# watched column counts the threads that login opened, and the two sets
# partition the PR's threads.
def watchCols: watchCols($watchUsers);
def watchHeaders: watchHeaders($watchUsers);
def watchCells: watchCells($watchUsers; $threads; $shortLabels);

# Columns are named object keys, not positional array indices — see
# todo.jq for why (cols/paint reference these names directly, so adding or
# reordering a column never requires renumbering anything else here).
def cells:
  {
    PR:         (if $shortLinks then "#\(.number)" else .url end),
    TITLE:      .title[0:80],
    AUTHOR:     authorCell,
    STATUS:     statusCell(._approvalStats; $approvalThreshold),
    THREADS:    threadsCell(threadsUnwatched($threads); threadsTruncated($threads); $shortLabels),
    APPROVALS:  approvalsCell(._approvalStats; $approvalThreshold; true),
    CI:         ci,
    JIRA:       jira,
    JIRA_STATUS: jiraStatusText($jiraStatuses; jiraKey),
    WAITING:    isoRel(.updatedAt),
    AGE:        isoRel(.createdAt),
    SIZE:       sizeCell,
    MERGE:      mergeState
  } + watchCells;

def headers:
  {
    PR: "PR", TITLE: "TITLE", AUTHOR: "AUTHOR", STATUS: "STATUS", THREADS: "THREADS",
    APPROVALS: "APPROVALS", CI: "CI", JIRA: "JIRA", JIRA_STATUS: "JIRA STATUS",
    WAITING: "PENDING SINCE", AGE: "AGE", SIZE: "SIZE", MERGE: "MERGE"
  } + watchHeaders;

# Columns whose color depends only on their own cell text.
def paint($col):
  if   $col == "AUTHOR" then (if . == "-" then dim else cyan end)
  elif $col == "STATUS" then paintDecision
  elif $col == "CI" then paintCi
  elif $col == "AGE" then dim
  elif $col == "MERGE" then paintMerge
  else . end;

# One colored cell, for renderTable (common.jq): input is {row, col, text}.
# PR, SIZE, THREADS, watched-login columns, WAITING, JIRA, JIRA_STATUS and
# APPROVALS need the raw PR object, not just the cell text; everything else
# goes through paint($col).
def paintCell:
  .row as $pr
  | .col as $col
  | .text as $text
  | if $col == "PR" then ($text | linkStyle | hyperlink($pr.url))
    elif $col == "SIZE" then ($pr | sizePaint)
    elif $col == "THREADS" then ($pr | threadsPaint(threadsUnwatched($threads); threadsTruncated($threads); $shortLabels))
    elif ($col | isWatchCol) then ($pr | watchPaint($col; $threads; $shortLabels))
    elif $col == "WAITING" then ($pr | waitingPaint)
    elif $col == "JIRA" then ($pr | jiraCellPaint($jiraBase; jiraKey; $shortLinks))
    elif $col == "JIRA_STATUS" then ($pr | jiraStatusPaint($jiraStatuses; jiraKey))
    elif $col == "APPROVALS" then ($pr | approvalsPaint(._approvalStats; $approvalThreshold; true))
    else ($text | paint($col))
    end;

# Watched-login columns are spliced in directly after THREADS, in configured
# order, and appear in both column sets — always rendered, even when every row
# is "-", so the table keeps the same shape between runs. AUTHOR follows PR,
# where todo and track put it, and depends only on the flag, never on the
# rows, for the same reason.
def cols:
  (if $long then ["TITLE", "PR", "STATUS", "THREADS", "WAITING", "APPROVALS", "CI", "JIRA", "JIRA_STATUS", "AGE", "SIZE", "MERGE"]
   else ["TITLE", "PR", "STATUS", "THREADS", "WAITING", "APPROVALS", "CI", "JIRA", "JIRA_STATUS"]
   end) as $base
  | ($base | index("THREADS")) as $i
  | $base[0:$i + 1] + watchCols + $base[$i + 1:]
  | if $includeAssigned then .[0:2] + ["AUTHOR"] + .[2:] else . end;

# Main
[inputs][0]
| (. | map(. + {_approvalStats: approvalStats(.author.login; $teamLogins)}) | sort_by(.createdAt)) as $rows
| renderTable($rows; cols; headers; cells; paintCell)
