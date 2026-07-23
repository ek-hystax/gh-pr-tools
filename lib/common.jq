# Shared jq helpers for gh-pr-tools subcommands (included via `include "common";`,
# with `jq -L "$dir"` set by the caller's .sh script so the module resolves
# regardless of the caller's current working directory).
# jq modules don't see the includer's --arg-bound globals, so any def here that
# needs profile-derived values ($jiraBase, $jiraPattern, ...) takes them as
# explicit function parameters instead of closing over caller variables.

# ANSI
def c($code): "\u001b[\($code)m\(.)\u001b[0m";
def green:  c("32");
def cyan:   c("36");
def dim:    c("2");
def yellow: c("33");
def red:    c("31");
def boldRed: c("1;31");

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

# Column width per position: max of the header cell and every row cell at
# that position. $headerCells and each row in $plainRows must already be
# arrays ordered the same as the table's column list.
def colWidths($headerCells; $plainRows):
  ( [$headerCells] + $plainRows | transpose | map(map(length) | max) );

# Padded, dimmed header row for a table, given column order, the
# headers-by-name object, and widths from colWidths.
def renderHeaderRow($cols; $headers; $w):
  [ range(0; $cols | length) as $i
    | ($headers[$cols[$i]]) as $h
    | $h + (" " * ($w[$i] - ($h | length)))
  ] | join("  ") | dim;

# Escalating color by elapsed seconds: <1d/1-3d/3-7d/7d+. 1d/7d boundaries
# match relTime's own bucket edges.
def waitPaint($seconds):
  if   $seconds < 86400  then dim
  elif $seconds < 259200 then .
  elif $seconds < 604800 then yellow
  else boldRed
  end;

def waitingPaintFor($sinceIso):
  isoRel($sinceIso) as $text
  | if $sinceIso == null then ($text | dim)
    else ($text | waitPaint(now - ($sinceIso | fromdateiso8601)))
    end;

# Ticket from branch name only (todo/mine convention)
def jiraFromBranch($jiraBase; $jiraPattern):
  if $jiraBase == "" then "-"
  else
    (.headRefName // "") as $branch
    | ("(?<t>\\b" + $jiraPattern + "\\b)") as $re
    | if ($branch | test($re))
      then "\($jiraBase)/\($branch | capture($re).t)"
      else "-"
      end
  end;

# Ticket from branch name, falling back to PR title (prd convention)
def jiraFromBranchOrTitle($jiraBase; $jiraPattern):
  if $jiraBase == "" then "-"
  else
    "\(.headRefName // "") \(.title // "")" as $s
    | ("(?<t>\\b" + $jiraPattern + "\\b)") as $re
    | if ($s | test($re))
      then "\($jiraBase)/\($s | capture($re).t)"
      else "-"
      end
  end;

# Rollup entries are CheckRuns (status/conclusion) or StatusContexts (state only).
def ciFail($c):
  ($c.conclusion | IN("FAILURE", "CANCELLED", "TIMED_OUT", "ACTION_REQUIRED", "STARTUP_FAILURE", "STALE"))
  or ($c.state | IN("ERROR", "FAILURE"));
def ciPending($c):
  ($c.status | IN("IN_PROGRESS", "QUEUED", "PENDING", "REQUESTED", "WAITING"))
  or ($c.status == "COMPLETED" and $c.conclusion == null)
  or ($c.state | IN("PENDING", "EXPECTED"));

def ciState:
  (.statusCheckRollup // []) as $checks
  | if ($checks | length) == 0 then "-"
    elif any($checks[]; ciFail(.)) then "fail"
    elif any($checks[]; ciPending(.)) then "pending"
    else "pass"
    end;

def paintCi:
  if . == "pass" then green
  elif . == "fail" then red
  elif . == "pending" then yellow
  else dim end;

# Latest submitted review per reviewer (author's own reviews and pending drafts excluded)
def latestReviews($author):
  [ .reviews[]? | select(.author != null and .author.login != $author and .state != "PENDING") ]
  | group_by(.author.login)
  | map(sort_by(.submittedAt) | last);

# An approval is stale once new commits have landed since it was submitted —
# i.e. the review's own commit doesn't match the PR's current head — and
# must not count toward the approvals total or the "Approved" decision.
def approverLogins($author):
  .headRefOid as $head
  | [ latestReviews($author)[]
      | select(.state == "APPROVED" and .commit.oid == $head)
      | .author.login ];

def teamApproverLogins($author; $teamLogins):
  [ approverLogins($author)[] | select(. as $l | $teamLogins | index($l) != null) ];

def hasChangesRequested($author):
  [ latestReviews($author)[] | select(.state == "CHANGES_REQUESTED") ] | length > 0;

# Reviewers whose latest review is APPROVED but against an older commit —
# the complement of approverLogins() (same reviews, opposite commit-oid
# check).
def staleApproverLogins($author):
  .headRefOid as $head
  | [ latestReviews($author)[] | select(.state == "APPROVED" and .commit.oid != $head) | .author.login ];

def staleTeamApproverLogins($author; $teamLogins):
  [ staleApproverLogins($author)[] | select(. as $l | $teamLogins | index($l) != null) ];

# Bundles the review-derived numbers the STATUS/APPROVALS cells need,
# computed once per PR — approvalDecision/approvalsCell/approvalsPaint all
# read from this instead of separately re-walking .reviews. $teamLogins is
# the current user's team-membership union, resolved once per invocation by
# my_team_logins() in common.sh — not to be confused with a per-PR
# requested-team member map like prd.jq's own $teamMembers.
def approvalStats($author; $teamLogins):
  { count: (approverLogins($author) | length),
    teamCount: (teamApproverLogins($author; $teamLogins) | length),
    changesRequested: hasChangesRequested($author),
    staleCount: (staleApproverLogins($author) | length),
    staleTeamCount: (staleTeamApproverLogins($author; $teamLogins) | length) };

# "N (team M; stale K)" — N total distinct approvers (fresh + stale), team M
# of whom are teammates (fresh + stale), with the "; stale K" segment only
# shown when K > 0. approvalStats keeps fresh and stale counts separate;
# this is where they're combined for display. Must render the exact same
# visible characters as approvalsPaint below (colWidths sizes columns off
# this plain form).
def approvalsCell($stats):
  ($stats.count + $stats.staleCount) as $total
  | ($stats.teamCount + $stats.staleTeamCount) as $teamTotal
  | "\($total) (team \($teamTotal)\(if $stats.staleCount > 0 then "; stale \($stats.staleCount)" else "" end))";

# The tool's own approval verdict, driven by the profile's
# APPROVAL_THRESHOLD (how many approvals *this user* personally requires) —
# independent of GitHub's reviewDecision/branch-protection rule. "Approved
# (stale)" only fires when fresh + stale approvers together meet the
# threshold; below threshold even counting stale approvers, it's "Pending
# review".
def approvalDecision($stats; $approvalThreshold):
  if $stats.changesRequested then "Changes requested"
  elif $stats.count >= $approvalThreshold then "Approved"
  elif $stats.staleCount > 0 and ($stats.count + $stats.staleCount) >= $approvalThreshold then "Approved (stale)"
  else "Pending review"
  end;

# Shared by mine.jq/todo.jq (Title Case cell text) and prd.jq (lowercased
# prose) — compares case-insensitively so callers can colorize either casing
# without duplicating this per file. For "Approved (stale)", the
# "Approved"/"approved" word (always 8 chars in either casing) is colored
# green and the trailing " (stale)" is colored yellow.
def paintDecision:
  (. | ascii_downcase) as $l
  | if $l == "approved" then green
    elif $l == "changes requested" then red
    elif $l == "approved (stale)" then (.[0:8] | green) + (.[8:] | yellow)
    else yellow end;

# Colors the APPROVALS cell to match the STATUS decision for the same row:
# the "total (team teamTotal" part and the closing ")" are dim for
# "Pending review"/"Changes requested" and green for "Approved"; the
# "stale K" segment is always yellow. Must produce the exact same visible
# characters as approvalsCell above — only ANSI codes differ — since
# colWidths pads rows based on that plain-text length.
def approvalsPaint($stats; $approvalThreshold):
  approvalDecision($stats; $approvalThreshold) as $d
  | ($stats.count + $stats.staleCount) as $total
  | ($stats.teamCount + $stats.staleTeamCount) as $teamTotal
  | "\($total) (team \($teamTotal)" as $prefix
  | (if $stats.staleCount > 0 then "; " else "" end) as $sep
  | (if $stats.staleCount > 0 then ("stale \($stats.staleCount)" | yellow) else "" end) as $staleNum
  | ")" as $suffix
  | if $d == "Changes requested" then ($prefix | dim) + ($sep | dim) + $staleNum + ($suffix | dim)
    elif $d == "Approved" then ($prefix | green) + ($sep | green) + $staleNum + ($suffix | green)
    else ($prefix | dim) + ($sep | dim) + $staleNum + ($suffix | dim)
    end;

# Open review-thread stats, keyed by PR number, as
# {"mine": {"total": N, "answered": X}, "theirs": {"total": M, "answered": Y}}
# (see fetch_review_threads in common.sh for how $map is built and what
# "answered" means).
def threadsMineTotal($map): ($map[.number | tostring].mine.total // 0);
def threadsMineAnswered($map): ($map[.number | tostring].mine.answered // 0);
def threadsTheirsTotal($map): ($map[.number | tostring].theirs.total // 0);
def threadsTheirsAnswered($map): ($map[.number | tostring].theirs.answered // 0);

# Plain-text formatter shared by todo.jq/mine.jq — each picks its own bucket
# (mine vs theirs) and paint emphasis, since which count matters most differs
# by perspective.
def threadsCell($total; $answered):
  if $total == 0 then "-"
  else "\($total) (\($answered) answered)" end;
