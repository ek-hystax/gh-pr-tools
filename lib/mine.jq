include "common";

# Inputs supplied by mine.sh: $unresolved, $jiraBase, $jiraPattern, $long

def decision:
  if .reviewDecision == "APPROVED" then "Approved"
  elif .reviewDecision == "CHANGES_REQUESTED" then "Changes requested"
  else "Pending review"
  end;

def paintDecision:
  if . == "Approved" then green
  elif . == "Changes requested" then red
  else yellow end;

def unresolvedCount:
  ($unresolved[.number | tostring] // 0);

def unresolvedCell:
  unresolvedCount as $n | if $n == 0 then "-" else ($n | tostring) end;

def approvals:
  approvalsCount(.author.login);

def ci: ciState;
def jira: jiraFromBranch($jiraBase; $jiraPattern);

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

def paintMerge:
  if IN("conflict", "dirty", "blocked") then red
  elif IN("behind", "unstable") then yellow
  elif . == "clean" then green
  else dim end;

# Plain cells (also used for column widths)
def cells:
  [
    "#\(.number)",
    .title[0:80],
    decision,
    unresolvedCell,
    (approvals | tostring),
    ci,
    .url,
    jira,
    isoRel(.updatedAt),
    isoRel(.createdAt),
    size,
    merge
  ];

def headers:
  ["PR", "TITLE", "STATUS", "UNRESOLVED", "APPROVALS", "CI", "URL", "JIRA", "UPDATED", "AGE", "SIZE", "MERGE"];

def paint($i):
  if   $i == 0 then green
  elif $i == 2 then paintDecision
  elif $i == 3 then (if . == "-" then dim else yellow end)
  elif $i == 5 then paintCi
  elif $i == 6 or $i == 7 or $i == 8 or $i == 9 then dim
  elif $i == 11 then paintMerge
  else . end;

# Columns shown by default vs --long (indexes into cells/headers)
def cols:
  if $long then [range(0; headers | length)]
  else [0, 1, 2, 3, 4, 5, 6, 7]
  end;

# Main
[inputs][0]
| cols as $cols
| (. | sort_by(.updatedAt)) as $rows
| ([$rows[] | cells as $all | [$cols[] | $all[.]]]) as $plain
| ( [[$cols[] | headers[.]]] + $plain | transpose | map(map(length) | max) ) as $w
| def pad($i): . + (" " * ($w[$i] - length));

( [range(0; $cols | length) as $i | (headers[$cols[$i]] | pad($i))] | join("  ") | dim ),

( range(0; $rows | length) as $r
  | $rows[$r] as $pr
  | $plain[$r] as $c
  | [ range(0; $c | length) as $i
      | if $cols[$i] == 10 then
          ($pr | sizePaint) + (" " * ($w[$i] - ($c[$i] | length)))
        else
          ($c[$i] | paint($cols[$i])) + (" " * ($w[$i] - ($c[$i] | length)))
        end
    ]
  | join("  ")
)
