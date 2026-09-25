include "common";

# Inputs supplied by todo.sh: $me, $threads, $viewed, $teamMembers, $teamLogins,
# $approvalThreshold, $jiraBase, $jiraPattern, $jiraStatuses, $long, $shortLinks,
# $shortLabels

def yn($b): if $b then "yes" else "-" end;

# PR fields
def mine:
  [ .reviews[]? | select(.author.login == $me) ] | last;

def mineState:
  mine as $m
  | if $m == null then "-"
    else $m.state | ascii_downcase | gsub("_"; " ")
    end;

def needsRereview:
  mine as $m
  | ($m.submittedAt // null) != null
    and ((.updatedAt | fromdateiso8601) > ($m.submittedAt | fromdateiso8601));

# No "review requested at" timestamp exists via the API, so proxy it: PR age
# if unreviewed (or only a draft review), time since the push if new commits
# landed since my review, else time since my own last review.
def waitingSince:
  mine as $m
  | if ($m == null or $m.submittedAt == null) then .createdAt
    elif needsRereview then .updatedAt
    else $m.submittedAt
    end;

# Whether anything is still pending on me specifically — false once I've
# given a fresh (non-stale) approval and no new commits have landed since.
# Used to keep PENDING SINCE's urgency coloring from escalating on rows
# iAmReviewer includes but that don't actually need my attention.
def needsMyAction:
  mine as $m
  | ($m == null or $m.state != "APPROVED" or needsRereview);

# Escalating urgency color only applies while something's still pending on
# me; once I've already given a fresh approval, show the elapsed time dim
# regardless of age instead of falsely flagging it as overdue.
def waitingPaint:
  if needsMyAction then waitingPaintFor(waitingSince)
  else (isoRel(waitingSince) | dim)
  end;

# Matches both a direct request (.login == $me) and a team request where
# $me is a member of the requested team (.slug, resolved via $teamMembers).
def requestedFromMe:
  ([ .reviewRequests[]? | select(.login == $me) ] | length > 0)
  or ([ .reviewRequests[]? | select(.slug) | (.slug | split("/") | last) ] as $teams
      | any($teams[]; $teamMembers[.] // [] | index($me) != null));

# Any PR where I'm an actual reviewer (currently requested, or I've left any
# review) — including ones where I've already given a fresh approval and
# nothing further is needed from me; MINE/STATUS/NEW CHANGES already convey
# that state, so this list doesn't need to filter them out.
def iAmReviewer:
  mine as $m
  | ($m != null or requestedFromMe);

# Watched-login columns (see watchCells in common.jq). THREADS counts only
# the threads I opened (mine bucket); each watched column counts the threads
# that login opened, so the two never overlap.
def watchCols: watchCols($watchUsers);
def watchHeaders: watchHeaders($watchUsers);
def watchCells: watchCells($watchUsers; $threads; $shortLabels);

def viewedCell:
  ($viewed[.number | tostring] // null) as $v
  | if $v == null then "-"
    else "\($v.viewed // 0)/\($v.total // 0)"
    end;

def viewedPaint:
  ($viewed[.number | tostring] // null) as $v
  | if $v == null then ("-" | dim)
    elif ($v.viewed // 0) == ($v.total // 0) then viewedCell | green
    else
      ("\($v.viewed // 0)" | dim)
      + ("/" | dim)
      + ("\($v.total // 0)" | yellow)
    end;

def paintMine:
  if startswith("approved") then green
  elif startswith("changes") then red
  elif startswith("commented") then cyan
  elif . == "-" then dim
  else yellow end;

# Columns are named object keys, not positional array indices — cols/paint
# reference these names directly, so adding/reordering a column never
# requires renumbering anything else in this file.
def cells:
  {
    PR:         (if $shortLinks then "#\(.number)" else .url end),
    TITLE:      .title[0:80],
    AUTHOR:     .author.login,
    STATUS:     statusCell(._approvalStats; $approvalThreshold),
    APPROVALS:  approvalsCell(._approvalStats; $approvalThreshold; true),
    MINE:       mineState,
    THREADS:    threadsCell(threadsMine($threads); threadsTruncated($threads); $shortLabels),
    VIEWED:     viewedCell,
    WAITING:    isoRel(waitingSince),
    UPDATED:    isoRel(.updatedAt),
    AGE:        isoRel(.createdAt),
    RE_REVIEW:  yn(needsRereview),
    SIZE:       sizeCell,
    CI:         ciState,
    MERGE:      mergeState,
    JIRA:       jiraCell($jiraBase; jiraKeyFromBranch($jiraPattern); $shortLinks),
    JIRA_STATUS: jiraStatusText($jiraStatuses; jiraKeyFromBranch($jiraPattern))
  } + watchCells;

def headers:
  {
    PR: "PR", TITLE: "TITLE", AUTHOR: "AUTHOR", STATUS: "STATUS", APPROVALS: "APPROVALS", MINE: "MINE",
    THREADS: "THREADS", VIEWED: "VIEWED", WAITING: "PENDING SINCE", UPDATED: "UPDATED", AGE: "AGE", RE_REVIEW: "NEW CHANGES",
    SIZE: "SIZE", CI: "CI", MERGE: "MERGE", JIRA: "JIRA", JIRA_STATUS: "JIRA STATUS"
  } + watchHeaders;

# Columns whose color depends only on their own cell text.
def paint($col):
  if   $col == "AUTHOR" then cyan
  elif $col == "STATUS" then paintDecision
  elif $col == "MINE" then paintMine
  elif $col == "RE_REVIEW" then (if . == "yes" then yellow else dim end)
  elif $col == "CI" then paintCi
  elif $col == "MERGE" then paintMerge
  elif $col == "UPDATED" or $col == "AGE" then dim
  else . end;

# One colored cell, for renderTable (common.jq): input is {row, col, text}.
# PR, SIZE, THREADS, watched-login columns, VIEWED, WAITING, JIRA,
# JIRA_STATUS and APPROVALS need the raw PR object, not just the cell text;
# everything else goes through paint($col).
def paintCell:
  .row as $pr
  | .col as $col
  | .text as $text
  | if $col == "PR" then ($text | linkStyle | hyperlink($pr.url))
    elif $col == "SIZE" then ($pr | sizePaint)
    elif $col == "THREADS" then ($pr | threadsPaint(threadsMine($threads); threadsTruncated($threads); $shortLabels))
    elif ($col | isWatchCol) then ($pr | watchPaint($col; $threads; $shortLabels))
    elif $col == "VIEWED" then ($pr | viewedPaint)
    elif $col == "WAITING" then ($pr | waitingPaint)
    elif $col == "JIRA" then ($pr | jiraCellPaint($jiraBase; jiraKeyFromBranch($jiraPattern); $shortLinks))
    elif $col == "JIRA_STATUS" then ($pr | jiraStatusPaint($jiraStatuses; jiraKeyFromBranch($jiraPattern)))
    elif $col == "APPROVALS" then ($pr | approvalsPaint(._approvalStats; $approvalThreshold; true))
    else ($text | paint($col))
    end;

# THREADS and VIEWED sit right after MINE in both column sets, rather than at
# the end. Watched-login columns are spliced in directly after THREADS, in
# configured order, and appear in both the default and --long sets — they are
# always rendered, even when every row is "-", so the table keeps the same
# shape between runs.
def cols:
  (if $long then ["TITLE", "PR", "AUTHOR", "STATUS", "MINE", "APPROVALS", "THREADS", "VIEWED", "RE_REVIEW", "WAITING", "UPDATED", "CI", "JIRA", "JIRA_STATUS", "AGE", "SIZE", "MERGE"]
   else ["TITLE", "PR", "AUTHOR", "STATUS", "MINE", "APPROVALS", "THREADS", "VIEWED", "RE_REVIEW", "WAITING", "JIRA", "JIRA_STATUS"]
   end) as $base
  | ($base | index("THREADS")) as $i
  | $base[0:$i + 1] + watchCols + $base[$i + 1:];

# Main
[inputs]
| (.[0] | map(select(iAmReviewer) | . + {_approvalStats: approvalStats(.author.login; $teamLogins)}) | sort_by(.createdAt)) as $rows
| renderTable($rows; cols; headers; cells; paintCell)
