include "common";

# Inputs supplied by todo.sh: $me, $threads, $viewed, $teamMembers, $teamLogins,
# $approvalThreshold, $jiraBase, $jiraPattern, $long

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

def size:
  "\(.changedFiles // 0)f +\(.additions // 0)/-\(.deletions // 0)";

def sizePaint:
  "\(.changedFiles // 0 | tostring | . + "f" | cyan)"
  + " +\(.additions // 0 | tostring | green)"
  + "/\("-" + (.deletions // 0 | tostring) | red)";

# Only threads I opened (mine bucket) — the ones I'm waiting on the owner
# for. "Answered" (owner replied, thread still open) is what needs my
# attention next, so it's the state worth highlighting; "pending" is still on
# the owner and needs nothing from me, and "resolved" is settled.
def threadsColors: {pending: "dim", answered: "yellow", resolved: "green"};

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

def merge:
  if .mergeable == "CONFLICTING" then "conflict"
  else (.mergeStateStatus // "-" | ascii_downcase)
  end;

def paintMine:
  if startswith("approved") then green
  elif startswith("changes") then red
  elif startswith("commented") then cyan
  elif . == "-" then dim
  else yellow end;

def paintMerge:
  if IN("conflict", "dirty", "blocked") then red
  elif IN("behind", "unstable") then yellow
  elif . == "clean" then green
  else dim end;

# Columns are named object keys, not positional array indices — cols/paint
# reference these names directly, so adding/reordering a column never
# requires renumbering anything else in this file.
def cells:
  {
    PR:         "#\(.number)",
    TITLE:      .title[0:80],
    AUTHOR:     .author.login,
    STATUS:     approvalDecision(._approvalStats; $approvalThreshold),
    APPROVALS:  approvalsCell(._approvalStats; $approvalThreshold),
    MINE:       mineState,
    THREADS:    threadsCell(threadsMine($threads)),
    VIEWED:     viewedCell,
    WAITING:    isoRel(waitingSince),
    UPDATED:    isoRel(.updatedAt),
    AGE:        isoRel(.createdAt),
    RE_REVIEW:  yn(needsRereview),
    SIZE:       size,
    CI:         ciState,
    MERGE:      merge,
    URL:        .url,
    JIRA:       jiraFromBranch($jiraBase; $jiraPattern)
  };

def headers:
  {
    PR: "PR", TITLE: "TITLE", AUTHOR: "AUTHOR", STATUS: "STATUS", APPROVALS: "APPROVALS", MINE: "MINE",
    THREADS: "THREADS", VIEWED: "VIEWED", WAITING: "PENDING SINCE", UPDATED: "UPDATED", AGE: "AGE", RE_REVIEW: "NEW CHANGES",
    SIZE: "SIZE", CI: "CI", MERGE: "MERGE", URL: "URL", JIRA: "JIRA"
  };

# SIZE, THREADS, VIEWED, WAITING need the raw PR object, not cell text, so the
# render loop special-cases them instead of routing through paint($col).
def paint($col):
  if   $col == "PR" then green
  elif $col == "AUTHOR" then cyan
  elif $col == "STATUS" then paintDecision
  elif $col == "MINE" then paintMine
  elif $col == "RE_REVIEW" then (if . == "yes" then yellow else dim end)
  elif $col == "CI" then paintCi
  elif $col == "MERGE" then paintMerge
  elif $col == "UPDATED" or $col == "AGE" or $col == "URL" or $col == "JIRA" then dim
  else . end;

# THREADS and VIEWED sit right after MINE in both column sets, rather than at the end.
def cols:
  if $long then ["PR", "TITLE", "AUTHOR", "STATUS", "MINE", "APPROVALS", "THREADS", "VIEWED", "RE_REVIEW", "WAITING", "UPDATED", "CI", "URL", "JIRA", "AGE", "SIZE", "MERGE"]
  else ["PR", "TITLE", "AUTHOR", "STATUS", "MINE", "APPROVALS", "THREADS", "VIEWED", "RE_REVIEW", "WAITING", "URL"]
  end;

# Main
[inputs]
| cols as $cols
| (.[0] | map(select(iAmReviewer) | . + {_approvalStats: approvalStats(.author.login; $teamLogins)}) | sort_by(.createdAt)) as $rows
| ([$cols[] | headers[.]]) as $headerCells
| ([$rows[] | cells as $all | [$cols[] | $all[.]]]) as $plain
| colWidths($headerCells; $plain) as $w
| renderHeaderRow($cols; headers; $w),

( range(0; $rows | length) as $r
  | $rows[$r] as $pr
  | $plain[$r] as $c
  | [ range(0; $c | length) as $i
      | if $cols[$i] == "SIZE" then
          ($pr | sizePaint) + (" " * ($w[$i] - ($c[$i] | length)))
        elif $cols[$i] == "THREADS" then
          ($pr | threadsPaint(threadsMine($threads); threadsColors)) + (" " * ($w[$i] - ($c[$i] | length)))
        elif $cols[$i] == "VIEWED" then
          ($pr | viewedPaint) + (" " * ($w[$i] - ($c[$i] | length)))
        elif $cols[$i] == "WAITING" then
          ($pr | waitingPaint) + (" " * ($w[$i] - ($c[$i] | length)))
        elif $cols[$i] == "APPROVALS" then
          ($pr | approvalsPaint(._approvalStats; $approvalThreshold)) + (" " * ($w[$i] - ($c[$i] | length)))
        else
          ($c[$i] | paint($cols[$i])) + (" " * ($w[$i] - ($c[$i] | length)))
        end
    ]
  | join("  ")
)
