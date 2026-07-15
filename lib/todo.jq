include "common";

# Inputs supplied by todo.sh: $me, $jiraBase, $jiraPattern, $long

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

def requestedFromMe:
  [ .reviewRequests[]? | select(.login == $me) ] | length > 0;

# Only PRs where I'm an actual reviewer (currently requested, or I've left
# a review): keep pending requests, comments, changes-requested; drop
# stale approvals.
def stillNeedsMe:
  mine as $m
  | ($m != null or requestedFromMe)
    and ($m == null or $m.state != "APPROVED" or needsRereview);

def size:
  "\(.changedFiles // 0)f +\(.additions // 0)/-\(.deletions // 0)";

def sizePaint:
  "\(.changedFiles // 0 | tostring | . + "f" | cyan)"
  + " +\(.additions // 0 | tostring | green)"
  + "/\("-" + (.deletions // 0 | tostring) | red)";

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
    ciState,
    merge,
    .url,
    jiraFromBranch($jiraBase; $jiraPattern)
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

# Columns shown by default vs --long (indexes into cells/headers)
def cols:
  if $long then [range(0; headers | length)]
  else [0, 1, 2, 4, 11]  # PR, TITLE, AUTHOR, MINE, URL
  end;

# Main
[inputs]
| cols as $cols
| (.[0] | map(select(stillNeedsMe)) | sort_by(.updatedAt)) as $rows
| ([$rows[] | cells as $all | [$cols[] | $all[.]]]) as $plain
| ( [[$cols[] | headers[.]]] + $plain | transpose | map(map(length) | max) ) as $w
| def pad($i): . + (" " * ($w[$i] - length));

( [range(0; $cols | length) as $i | (headers[$cols[$i]] | pad($i))] | join("  ") | dim ),

( range(0; $rows | length) as $r
  | $rows[$r] as $pr
  | $plain[$r] as $c
  | [ range(0; $c | length) as $i
      | if $cols[$i] == 8 then
          ($pr | sizePaint) + (" " * ($w[$i] - ($c[$i] | length)))
        else
          ($c[$i] | paint($cols[$i])) + (" " * ($w[$i] - ($c[$i] | length)))
        end
    ]
  | join("  ")
)
