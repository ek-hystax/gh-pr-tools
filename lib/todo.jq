include "common";

# Inputs supplied by todo.sh: $me, $threads, $teamMembers, $teamLogins,
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

def waitingPaint: waitingPaintFor(waitingSince);

# Matches both a direct request (.login == $me) and a team request where
# $me is a member of the requested team (.slug, resolved via $teamMembers).
def requestedFromMe:
  ([ .reviewRequests[]? | select(.login == $me) ] | length > 0)
  or ([ .reviewRequests[]? | select(.slug) | (.slug | split("/") | last) ] as $teams
      | any($teams[]; $teamMembers[.] // [] | index($me) != null));

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

# Only threads I opened (mine bucket) — the ones I'm waiting on the owner
# for. "Answered" (owner replied) is what needs my attention next, since the
# thread is still open despite the reply, so it's the count worth
# highlighting.
def threadsPaint:
  threadsMineTotal($threads) as $t | threadsMineAnswered($threads) as $a
  | if $t == 0 then ("-" | dim)
    else
      ("\($t)" | cyan) + (" (" | dim)
      + ("\($a) answered" | if $a > 0 then yellow else dim end)
      + (")" | dim)
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
    APPROVALS:  approvalsCell(._approvalStats),
    MINE:       mineState,
    THREADS:    threadsCell(threadsMineTotal($threads); threadsMineAnswered($threads)),
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
    THREADS: "THREADS", WAITING: "WAITING", UPDATED: "UPDATED", AGE: "AGE", RE_REVIEW: "RE-REVIEW",
    SIZE: "SIZE", CI: "CI", MERGE: "MERGE", URL: "URL", JIRA: "JIRA"
  };

# SIZE, THREADS, WAITING need the raw PR object, not cell text, so the
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

# THREADS sits right after MINE in both column sets, rather than at the end.
def cols:
  if $long then ["PR", "TITLE", "AUTHOR", "STATUS", "APPROVALS", "MINE", "THREADS", "RE_REVIEW", "WAITING", "UPDATED", "CI", "URL", "JIRA", "AGE", "SIZE", "MERGE"]
  else ["PR", "TITLE", "AUTHOR", "STATUS", "APPROVALS", "MINE", "THREADS", "RE_REVIEW", "WAITING", "URL"]
  end;

# Main
[inputs]
| cols as $cols
| (.[0] | map(select(stillNeedsMe) | . + {_approvalStats: approvalStats(.author.login; $teamLogins)}) | sort_by(.createdAt)) as $rows
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
