include "common";

# Inputs supplied by mine.sh: $threads, $teamLogins, $approvalThreshold,
# $jiraBase, $jiraPattern, $jiraStatuses, $long, $shortLinks, $shortLabels

def ci: ciState;
def jiraKey: jiraKeyFromBranch($jiraPattern);
def jira: jiraCell($jiraBase; jiraKey; $shortLinks);

def waitingPaint: waitingPaintFor(.updatedAt);

def size:
  "\(.changedFiles // 0)f +\(.additions // 0)/-\(.deletions // 0)";

def sizePaint:
  "\(.changedFiles // 0 | tostring | . + "f" | cyan)"
  + " +\(.additions // 0 | tostring | green)"
  + "/\("-" + (.deletions // 0 | tostring) | red)";

# Watched-login columns. THREADS counts only the threads reviewers opened
# (theirs bucket); each watched column counts the threads that login opened.
# $watchUsers arrives as [{display, key}] in configured order (see
# thread_watch_users in common.sh); the column key is prefixed so a login can
# never collide with a built-in column name, and $display carries the login in
# the case it was configured with, since uppercasing headers the way the
# built-in ones do would mangle a mixed-case login.
def watchCol($u): "WATCH:\($u.key)";
def watchCols: [$watchUsers[] | watchCol(.)];
def watchHeaders: reduce $watchUsers[] as $u ({}; .[watchCol($u)] = $u.display);

def watchCells:
  . as $pr
  | ($pr | threadsTruncated($threads)) as $trunc
  | reduce $watchUsers[] as $u ({};
      .[watchCol($u)] = ($pr | threadsCell(threadsWatched($threads; $u.key); $trunc; $shortLabels)));

def merge:
  if .mergeable == "CONFLICTING" then "conflict"
  else (.mergeStateStatus // "-" | ascii_downcase)
  end;

def paintMerge:
  if IN("conflict", "dirty", "blocked") then red
  elif IN("behind", "unstable") then yellow
  elif . == "clean" then green
  else dim end;

# Columns are named object keys, not positional array indices — see
# todo.jq for why (cols/paint reference these names directly, so adding or
# reordering a column never requires renumbering anything else here).
def cells:
  {
    PR:         (if $shortLinks then "#\(.number)" else .url end),
    TITLE:      .title[0:80],
    STATUS:     approvalDecision(._approvalStats; $approvalThreshold),
    THREADS:    threadsCell(threadsTheirs($threads); threadsTruncated($threads); $shortLabels),
    APPROVALS:  approvalsCell(._approvalStats; $approvalThreshold),
    CI:         ci,
    JIRA:       jira,
    JIRA_STATUS: jiraStatusText($jiraStatuses; jiraKey),
    WAITING:    isoRel(.updatedAt),
    AGE:        isoRel(.createdAt),
    SIZE:       size,
    MERGE:      merge
  } + watchCells;

def headers:
  {
    PR: "PR", TITLE: "TITLE", STATUS: "STATUS", THREADS: "THREADS",
    APPROVALS: "APPROVALS", CI: "CI", JIRA: "JIRA", JIRA_STATUS: "JIRA STATUS",
    WAITING: "PENDING SINCE", AGE: "AGE", SIZE: "SIZE", MERGE: "MERGE"
  } + watchHeaders;

# SIZE, THREADS, WAITING and JIRA_STATUS need the raw PR object, not cell
# text, so the render loop special-cases them instead of routing through
# paint($col).
def paint($col):
  if   $col == "PR" then linkStyle
  elif $col == "STATUS" then paintDecision
  elif $col == "CI" then paintCi
  elif $col == "AGE" then dim
  elif $col == "MERGE" then paintMerge
  else . end;

# Watched-login columns are spliced in directly after THREADS, in configured
# order, and appear in both column sets — always rendered, even when every row
# is "-", so the table keeps the same shape between runs.
def cols:
  (if $long then ["TITLE", "PR", "STATUS", "THREADS", "WAITING", "APPROVALS", "CI", "JIRA", "JIRA_STATUS", "AGE", "SIZE", "MERGE"]
   else ["TITLE", "PR", "STATUS", "THREADS", "WAITING", "APPROVALS", "CI", "JIRA", "JIRA_STATUS"]
   end) as $base
  | ($base | index("THREADS")) as $i
  | $base[0:$i + 1] + watchCols + $base[$i + 1:];

# Main
[inputs][0]
| cols as $cols
| (. | map(. + {_approvalStats: approvalStats(.author.login; $teamLogins)}) | sort_by(.createdAt)) as $rows
| ([$cols[] | headers[.]]) as $headerCells
| ([$rows[] | cells as $all | [$cols[] | $all[.]]]) as $plain
| colWidths($headerCells; $plain) as $w
| renderHeaderRow($cols; headers; $w),

( range(0; $rows | length) as $r
  | $rows[$r] as $pr
  | $plain[$r] as $c
  | [ range(0; $c | length) as $i
      | if $cols[$i] == "PR" then
          ($c[$i] | linkStyle | hyperlink($pr.url)) + (" " * ($w[$i] - ($c[$i] | length)))
        elif $cols[$i] == "SIZE" then
          ($pr | sizePaint) + (" " * ($w[$i] - ($c[$i] | length)))
        elif $cols[$i] == "THREADS" then
          ($pr | threadsPaint(threadsTheirs($threads); threadsTruncated($threads); $shortLabels)) + (" " * ($w[$i] - ($c[$i] | length)))
        elif ($cols[$i] | startswith("WATCH:")) then
          ($pr | threadsPaint(threadsWatched($threads; $cols[$i] | ltrimstr("WATCH:")); threadsTruncated($threads); $shortLabels)) + (" " * ($w[$i] - ($c[$i] | length)))
        elif $cols[$i] == "WAITING" then
          ($pr | waitingPaint) + (" " * ($w[$i] - ($c[$i] | length)))
        elif $cols[$i] == "JIRA" then
          ($pr | jiraCellPaint($jiraBase; jiraKey; $shortLinks)) + (" " * ($w[$i] - ($c[$i] | length)))
        elif $cols[$i] == "JIRA_STATUS" then
          ($pr | jiraStatusPaint($jiraStatuses; jiraKey)) + (" " * ($w[$i] - ($c[$i] | length)))
        elif $cols[$i] == "APPROVALS" then
          ($pr | approvalsPaint(._approvalStats; $approvalThreshold)) + (" " * ($w[$i] - ($c[$i] | length)))
        else
          ($c[$i] | paint($cols[$i])) + (" " * ($w[$i] - ($c[$i] | length)))
        end
    ]
  | join("  ")
)
