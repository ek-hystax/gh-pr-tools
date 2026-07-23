include "common";

# Inputs supplied by mine.sh: $threads, $teamLogins, $approvalThreshold,
# $jiraBase, $jiraPattern, $long

def ci: ciState;
def jira: jiraFromBranch($jiraBase; $jiraPattern);

def waitingPaint: waitingPaintFor(.updatedAt);

def size:
  "\(.changedFiles // 0)f +\(.additions // 0)/-\(.deletions // 0)";

def sizePaint:
  "\(.changedFiles // 0 | tostring | . + "f" | cyan)"
  + " +\(.additions // 0 | tostring | green)"
  + "/\("-" + (.deletions // 0 | tostring) | red)";

# Only threads reviewers opened (theirs bucket) — the ones waiting on me. The
# unanswered portion (total minus answered) is what still needs my reply, so
# that's what's worth highlighting; once everything's answered, the whole
# thing is just waiting on the reviewer next.
def threadsPaint:
  threadsTheirsTotal($threads) as $t | threadsTheirsAnswered($threads) as $a
  | ($t - $a) as $pending
  | if $t == 0 then ("-" | dim)
    else
      ("\($t)" | cyan) + (" (" | dim)
      + ("\($a) answered" | if $pending > 0 then yellow else dim end)
      + (")" | dim)
    end;

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
    STATUS:     approvalDecision(._approvalStats; $approvalThreshold),
    THREADS:    threadsCell(threadsTheirsTotal($threads); threadsTheirsAnswered($threads)),
    APPROVALS:  approvalsCell(._approvalStats),
    CI:         ci,
    URL:        .url,
    JIRA:       jira,
    WAITING:    isoRel(.updatedAt),
    AGE:        isoRel(.createdAt),
    SIZE:       size,
    MERGE:      merge
  };

def headers:
  {
    PR: "PR", TITLE: "TITLE", STATUS: "STATUS", THREADS: "THREADS",
    APPROVALS: "APPROVALS", CI: "CI", URL: "URL", JIRA: "JIRA",
    WAITING: "WAITING", AGE: "AGE", SIZE: "SIZE", MERGE: "MERGE"
  };

# SIZE, THREADS, WAITING need the raw PR object, not cell text, so the
# render loop special-cases them instead of routing through paint($col).
def paint($col):
  if   $col == "PR" then green
  elif $col == "STATUS" then paintDecision
  elif $col == "CI" then paintCi
  elif $col == "URL" or $col == "JIRA" or $col == "AGE" then dim
  elif $col == "MERGE" then paintMerge
  else . end;

def cols:
  if $long then ["PR", "TITLE", "STATUS", "THREADS", "WAITING", "APPROVALS", "CI", "URL", "JIRA", "AGE", "SIZE", "MERGE"]
  else ["PR", "TITLE", "STATUS", "THREADS", "WAITING", "APPROVALS", "CI", "URL", "JIRA"]
  end;

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
      | if $cols[$i] == "SIZE" then
          ($pr | sizePaint) + (" " * ($w[$i] - ($c[$i] | length)))
        elif $cols[$i] == "THREADS" then
          ($pr | threadsPaint) + (" " * ($w[$i] - ($c[$i] | length)))
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
