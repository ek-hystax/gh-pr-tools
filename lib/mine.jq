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

# Columns are named object keys, not positional array indices — see
# todo.jq for why (cols/paint reference these names directly, so adding or
# reordering a column never requires renumbering anything else here).
def cells:
  {
    PR:         "#\(.number)",
    TITLE:      .title[0:80],
    STATUS:     decision,
    UNRESOLVED: unresolvedCell($unresolved),
    APPROVALS:  (approvals | tostring),
    CI:         ci,
    URL:        .url,
    JIRA:       jira,
    UPDATED:    isoRel(.updatedAt),
    AGE:        isoRel(.createdAt),
    SIZE:       size,
    MERGE:      merge
  };

def headers:
  {
    PR: "PR", TITLE: "TITLE", STATUS: "STATUS", UNRESOLVED: "UNRESOLVED",
    APPROVALS: "APPROVALS", CI: "CI", URL: "URL", JIRA: "JIRA",
    UPDATED: "UPDATED", AGE: "AGE", SIZE: "SIZE", MERGE: "MERGE"
  };

def paint($col):
  if   $col == "PR" then green
  elif $col == "STATUS" then paintDecision
  elif $col == "CI" then paintCi
  elif $col == "URL" or $col == "JIRA" or $col == "UPDATED" or $col == "AGE" then dim
  elif $col == "MERGE" then paintMerge
  else . end;

def cols:
  if $long then ["PR", "TITLE", "STATUS", "UNRESOLVED", "APPROVALS", "CI", "URL", "JIRA", "UPDATED", "AGE", "SIZE", "MERGE"]
  else ["PR", "TITLE", "STATUS", "UNRESOLVED", "APPROVALS", "CI", "URL", "JIRA"]
  end;

# Main
[inputs][0]
| cols as $cols
| (. | sort_by(.createdAt)) as $rows
| ([$rows[] | cells as $all | [$cols[] | $all[.]]]) as $plain
| ( [[$cols[] | headers[.]]] + $plain | transpose | map(map(length) | max) ) as $w
| def pad($i): . + (" " * ($w[$i] - length));

( [range(0; $cols | length) as $i | (headers[$cols[$i]] | pad($i))] | join("  ") | dim ),

( range(0; $rows | length) as $r
  | $rows[$r] as $pr
  | $plain[$r] as $c
  | [ range(0; $c | length) as $i
      | if $cols[$i] == "SIZE" then
          ($pr | sizePaint) + (" " * ($w[$i] - ($c[$i] | length)))
        elif $cols[$i] == "UNRESOLVED" then
          ($pr | unresolvedPaint($unresolved)) + (" " * ($w[$i] - ($c[$i] | length)))
        else
          ($c[$i] | paint($cols[$i])) + (" " * ($w[$i] - ($c[$i] | length)))
        end
    ]
  | join("  ")
)
