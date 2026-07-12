# Inputs supplied by todo.sh: $me, $jiraBase, $jiraPattern

# ANSI
def c($code): "\u001b[\($code)m\(.)\u001b[0m";
def green:  c("32");
def cyan:   c("36");
def dim:    c("2");
def yellow: c("33");
def red:    c("31");

def yn($b): if $b then "yes" else "-" end;

def relTime($ts):
  (now - $ts) as $d
  | if   $d < 45      then "just now"
    elif $d < 3600    then "\(($d / 60) | floor)m ago"
    elif $d < 86400   then "\(($d / 3600) | floor)h ago"
    elif $d < 604800  then "\(($d / 86400) | floor)d ago"
    elif $d < 2592000 then "\(($d / 604800) | floor)w ago"
    else                   "\(($d / 2592000) | floor)mo ago"
    end;

def isoRel($at):
  if $at == null then "-" else ($at | fromdateiso8601 | relTime(.)) end;

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

# Keep comments / changes-requested; drop stale approvals
def stillNeedsMe:
  mine as $m
  | $m == null or $m.state != "APPROVED" or needsRereview;

def jira:
  if $jiraBase == "" then "-"
  else
    (.headRefName // "") as $branch
    | ("(?<t>" + $jiraPattern + ")") as $re
    | if ($branch | test($re))
      then "\($jiraBase)/\($branch | capture($re).t)"
      else "-"
      end
  end;

def size:
  "\(.changedFiles // 0)f +\(.additions // 0)/-\(.deletions // 0)";

def sizePaint:
  "\(.changedFiles // 0 | tostring | . + "f" | cyan)"
  + " +\(.additions // 0 | tostring | green)"
  + "/\("-" + (.deletions // 0 | tostring) | red)";

def ciFail($c): $c.conclusion | IN("FAILURE", "CANCELLED", "TIMED_OUT", "ACTION_REQUIRED");
def ciPending($c):
  ($c.status | IN("IN_PROGRESS", "QUEUED", "PENDING"))
  or ($c.status == "COMPLETED" and $c.conclusion == null);

def ci:
  (.statusCheckRollup // []) as $checks
  | if ($checks | length) == 0 then "-"
    elif any($checks[] | ciFail(.)) then "fail"
    elif any($checks[] | ciPending(.)) then "pending"
    else "pass"
    end;

def merge:
  if .mergeable == "CONFLICTING" then "conflict"
  else (.mergeStateStatus // "-" | ascii_downcase)
  end;

def decision: .reviewDecision // "PENDING";

# Plain cells (also used for column widths)
def cells:
  [
    "#\(.number)",
    .title[0:80],
    .author.login,
    decision,
    mineState,
    isoRel(.updatedAt),
    isoRel(.createdAt),
    yn(needsRereview),
    size,
    ci,
    merge,
    .url,
    jira
  ];

def headers:
  ["PR", "TITLE", "AUTHOR", "DECISION", "MINE", "UPDATED", "AGE", "RE-REVIEW", "SIZE", "CI", "MERGE", "URL", "JIRA"];

def paintDecision:
  if startswith("APPROVED") then green
  elif startswith("CHANGES") then red
  else yellow end;

def paintMine:
  if startswith("approved") then green
  elif startswith("changes") then red
  elif startswith("commented") then cyan
  elif . == "-" then dim
  else yellow end;

def paintCi:
  if . == "pass" then green
  elif . == "fail" then red
  elif . == "pending" then yellow
  else dim end;

def paintMerge:
  if IN("conflict", "dirty", "blocked") then red
  elif IN("behind", "unstable") then yellow
  elif . == "clean" then green
  else dim end;

def paint($i):
  if   $i == 0 then green
  elif $i == 2 then cyan
  elif $i == 3 then paintDecision
  elif $i == 4 then paintMine
  elif $i == 7 then (if . == "yes" then yellow else dim end)
  elif $i == 9 then paintCi
  elif $i == 10 then paintMerge
  elif $i == 5 or $i == 6 or $i == 11 or $i == 12 then dim
  else . end;

# Main
[inputs]
| (.[0] | map(select(stillNeedsMe)) | sort_by(.updatedAt)) as $rows
| ([$rows[] | cells]) as $plain
| ( [headers] + $plain | transpose | map(map(length) | max) ) as $w
| def pad($i): . + (" " * ($w[$i] - length));

( [range(0; headers | length) as $i | (headers[$i] | pad($i))] | join("  ") | dim ),

( range(0; $rows | length) as $r
  | $rows[$r] as $pr
  | $plain[$r] as $c
  | [ range(0; $c | length) as $i
      | if $i == 8 then
          ($pr | sizePaint) + (" " * ($w[8] - ($c[8] | length)))
        else
          ($c[$i] | paint($i)) + (" " * ($w[$i] - ($c[$i] | length)))
        end
    ]
  | join("  ")
)
