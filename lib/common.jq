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

def approvalsCount($author):
  [ latestReviews($author)[] | select(.state == "APPROVED") ] | length;

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
