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

# Clickable cells (PR, JIRA). Cyan matches the AUTHOR column, and the
# underline is what actually marks the cell as a link: OSC 8 targets are
# invisible, so without it a hyperlinked cell looks like any other colored
# text. One definition so the two columns can never drift apart.
def linkStyle: c("4;36");

# OSC 8 explicit hyperlink: the input is the visible label and $url is the
# hidden destination. Supported by WezTerm and other modern terminals.
def hyperlink($url):
  "\u001b]8;;\($url)\u001b\\\(.)\u001b]8;;\u001b\\";

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

# First ticket key in $text, upper-cased, or null when there is none.
# Upper-casing matters beyond cosmetics: a branch may well be bug/kf-1309,
# while Jira keys — and the keys bulkfetch echoes back — are always upper
# case, so the status map below would miss every lower-case branch otherwise.
def jiraKey($jiraPattern; $text):
  ("(?<t>\\b" + $jiraPattern + "\\b)") as $re
  | if ($text | test($re; "i"))
    then ($text | capture($re; "i").t | ascii_upcase)
    else null
    end;

# Ticket key from branch name only (todo/mine convention)
def jiraKeyFromBranch($jiraPattern):
  jiraKey($jiraPattern; (.headRefName // ""));

# Ticket key from branch name, falling back to PR title (prd convention)
def jiraKeyFromBranchOrTitle($jiraPattern):
  jiraKey($jiraPattern; "\(.headRefName // "") \(.title // "")");

def jiraUrl($jiraBase; $key):
  if $jiraBase == "" or $key == null then "-" else "\($jiraBase)/\($key)" end;

# JIRA cell text: the full browse URL, or just the ticket key under
# --short-links. The URL is by far the widest cell in these tables and every
# character before the key is identical on every row, so the short form is
# the same trade the PR column already makes.
def jiraCell($jiraBase; $key; $short):
  if $jiraBase == "" or $key == null then "-"
  elif $short then $key
  else jiraUrl($jiraBase; $key)
  end;

# Under --short-links the visible label no longer contains the URL, so the
# cell carries it as an OSC 8 target instead — keeping the ticket clickable
# exactly as the PR column stays clickable when it shows "#1154".
def jiraCellPaint($jiraBase; $key; $short):
  jiraCell($jiraBase; $key; $short) as $text
  | if $text == "-" then ($text | dim)
    else ($text | linkStyle | hyperlink(jiraUrl($jiraBase; $key)))
    end;

# Ticket from branch name only (todo/mine convention)
def jiraFromBranch($jiraBase; $jiraPattern):
  jiraUrl($jiraBase; jiraKeyFromBranch($jiraPattern));

# Ticket from branch name, falling back to PR title (prd convention)
def jiraFromBranchOrTitle($jiraBase; $jiraPattern):
  jiraUrl($jiraBase; jiraKeyFromBranchOrTitle($jiraPattern));

# Jira issue status for a ticket key, from the map fetch_jira_statuses built.
# "-" covers every reason a status can be absent — no ticket in the branch,
# Jira not configured, the lookup failed, the issue deleted or invisible —
# deliberately, since none of them is worth a distinct cell in a table.
def jiraStatusText($statuses; $key):
  if $key == null then "-" else ($statuses[$key] // "-") end;

# Colored by status name. Jira's statusCategory would be the portable choice
# — three values every workflow maps onto — but it cannot tell "Approved"
# from "Review": both are "indeterminate", and those are precisely the two
# states worth distinguishing at a glance. Anything unrecognised stays dim,
# like the header row, rather than guessing. Extending this is one more
# branch per name.
def jiraStatusPaint($statuses; $key):
  jiraStatusText($statuses; $key) as $name
  | ($name | ascii_downcase) as $lower
  | if   $lower == "approved" then ($name | green)
    elif $lower == "review"   then ($name | yellow)
    else ($name | dim)
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
    staleCount: (staleApproverLogins($author) | length),
    staleTeamCount: (staleTeamApproverLogins($author; $teamLogins) | length),
    changesRequested: hasChangesRequested($author) };

# "N/Y (team M; stale K)" — N total distinct approvers (fresh + stale) out
# of Y required (the profile's APPROVAL_THRESHOLD), team M of whom are
# teammates (fresh + stale), with the "; stale K" segment only shown when
# K > 0. approvalStats keeps fresh and stale counts separate; this is where
# they're combined for display. Must render the exact same visible
# characters as approvalsPaint below (colWidths sizes columns off this
# plain form).
def approvalsCell($stats; $approvalThreshold):
  ($stats.count + $stats.staleCount) as $total
  | ($stats.teamCount + $stats.staleTeamCount) as $teamTotal
  | "\($total)/\($approvalThreshold) (team \($teamTotal)\(if $stats.staleCount > 0 then "; stale \($stats.staleCount)" else "" end))";

# The tool's own approval verdict, driven by the profile's
# APPROVAL_THRESHOLD (how many approvals *this user* personally requires) —
# independent of GitHub's reviewDecision/branch-protection rule. An active
# CHANGES_REQUESTED review from any reviewer blocks "Approved"/"Approved
# (stale)" outright — it folds into "Awaiting Approval" rather than getting
# its own distinct label, but it's never silently overridden by other
# reviewers' approvals meeting the threshold. "Approved (stale)" only fires
# when fresh + stale approvers together meet the threshold; below threshold
# even counting stale approvers, it's "Awaiting Approval".
def approvalDecision($stats; $approvalThreshold):
  if $stats.changesRequested then "Awaiting Approval"
  elif $stats.count >= $approvalThreshold then "Approved"
  elif $stats.staleCount > 0 and ($stats.count + $stats.staleCount) >= $approvalThreshold then "Approved (stale)"
  else "Awaiting Approval"
  end;

# Shared by mine.jq/todo.jq (Title Case cell text) and prd.jq (lowercased
# prose) — compares case-insensitively so callers can colorize either casing
# without duplicating this per file. For "Approved (stale)", the
# "Approved"/"approved" word (always 8 chars in either casing) is colored
# green and the trailing " (stale)" is colored yellow.
def paintDecision:
  (. | ascii_downcase) as $l
  | if $l == "approved" then green
    elif $l == "approved (stale)" then (.[0:8] | green) + (.[8:] | yellow)
    else yellow end;

# Colors just the leading total (fresh + stale) green once it meets the
# profile's approval threshold *and* nothing is currently blocking it (i.e.
# approvalDecision doesn't say "Awaiting Approval"), dim otherwise; " (team
# M...)" stays dim and the "stale K" segment is always yellow regardless of
# threshold. Must produce the exact same visible characters as approvalsCell
# above — only ANSI codes differ — since colWidths pads rows based on that
# plain-text length.
def approvalsPaint($stats; $approvalThreshold):
  (approvalDecision($stats; $approvalThreshold) != "Awaiting Approval") as $met
  | ($stats.count + $stats.staleCount) as $total
  | ($stats.teamCount + $stats.staleTeamCount) as $teamTotal
  | (if $met then ("\($total)/\($approvalThreshold)" | green) else ("\($total)/\($approvalThreshold)" | dim) end) as $num
  | (" (team \($teamTotal)" | dim) as $mid
  | (if $stats.staleCount > 0 then ("; " | dim) else "" end) as $sep
  | (if $stats.staleCount > 0 then ("stale \($stats.staleCount)" | yellow) else "" end) as $staleNum
  | (")" | dim) as $suffix
  | $num + $mid + $sep + $staleNum + $suffix;

# Review-thread stats, keyed by PR number, as {"mine": <bucket>, "theirs":
# <bucket>} where each bucket is {"total": N, "pending": P, "answered": A,
# "resolved": R} — see fetch_pr_review_state in common.sh for how $map is
# built and what the three states mean. Missing PR (failed lookup) yields {},
# which the // 0 defaults below turn into a "-" cell.
def threadsMine($map):   ($map[.number | tostring].mine   // {});
def threadsTheirs($map): ($map[.number | tostring].theirs // {});

# One watched login's bucket, keyed by its lowercased login — see
# thread_watch_users in common.sh for where those keys come from.
def threadsWatched($map; $key): ($map[.number | tostring].watched[$key] // {});

# Whether this PR has more review threads than the single page the lookup
# asks for, in which case every bucket for it is a floor rather than a count.
def threadsTruncated($map): ($map[.number | tostring].truncated // false);

# The non-zero parts of a bucket, in pending -> answered -> resolved order.
# Zero states are dropped so a settled PR reads "4 (4 resolved)" instead of
# padding out every row with noise; since the three sum to total, a non-zero
# total always leaves at least one segment.
#
# Each segment carries its state name separately from the label it prints
# under: the name is what threadColors is keyed by and never varies, while
# --short-labels ($short) collapses the label to a single initial. Keeping
# them apart is what lets the flag change the text without touching the
# colors.
def threadSegments($stats; $short):
  [ {n: ($stats.pending  // 0), state: "pending",  label: (if $short then "P" else "pending"  end)},
    {n: ($stats.answered // 0), state: "answered", label: (if $short then "A" else "answered" end)},
    {n: ($stats.resolved // 0), state: "resolved", label: (if $short then "R" else "resolved" end)} ]
  | map(select(.n > 0));

# One segment: "2 pending" long, "2P" short. The short form drops the space
# too, so each count reads as one token — "2P 1A 3R" rather than a row of
# loose numbers and letters.
def threadSegmentText($seg; $short):
  if $short then "\($seg.n)\($seg.label)" else "\($seg.n) \($seg.label)" end;

# Separator between segments. Commas earn their place between words but not
# between two-character tokens, where they would out-weigh what they separate.
def threadSegmentSep($short): if $short then " " else ", " end;

# "N (P pending, A answered, R resolved)", or "N (PP AA RR)" under
# --short-labels — N total threads in the bucket, split into the three states
# (zero ones omitted). Plain-text form shared by todo.jq/mine.jq; "-" when the
# bucket is empty.
# $truncated marks the PR as having threads past the fetched page: the total
# then prints as "27+", so an undercount reads as obviously incomplete instead
# of as a wrong number. A bucket can be empty and still truncated (the missing
# threads may all be this login's), which is why that case prints "0+" rather
# than the "-" a genuinely empty bucket gets.
def threadsCell($stats; $truncated; $short):
  ($stats.total // 0) as $t
  | if $t == 0 and ($truncated | not) then "-"
    elif $t == 0 then "0+"
    else "\($t)\(if $truncated then "+" else "" end) ("
         + ( threadSegments($stats; $short)
             | map(threadSegmentText(.; $short))
             | join(threadSegmentSep($short)) )
         + ")"
    end;

# Colors are named rather than passed as functions (jq has no first-class
# functions) so the map below can live next to the states it keys off. Only
# the names the THREADS callers use are mapped; anything else falls back to
# dim.
def paintByName($name):
  if   $name == "red"    then red
  elif $name == "yellow" then yellow
  elif $name == "green"  then green
  else dim end;

# One state -> color map for every threads-style column, keyed by the
# threadSegments state names. Which side an open thread is waiting on differs
# between the THREADS column and the watched-login columns, but a reader
# scanning one row across both should not have to re-learn what a color means,
# so the states are painted the same everywhere. The three run a traffic
# light, worst first: red pending (nobody has answered), yellow answered
# (spoken for, not closed), green resolved (settled) — so a row reads by color
# before it reads by number. The total stays cyan, outside that scale, since
# it is a count rather than a state. This matters more under --short-labels,
# where the color is doing more of the work than a bare "P" or "A" can.
def threadColors: {pending: "red", answered: "yellow", resolved: "green"};

# Colored form of threadsCell. Because zero segments are omitted, a segment
# being present already means it is non-zero, so the colors are unconditional.
# Both forms are built from the same threadSegments list and the same text and
# separator helpers, which is what keeps them emitting identical visible
# characters — required, since colWidths sizes columns off the plain cell and
# callers pad by its length.
def threadsPaint($stats; $truncated; $short):
  ($stats.total // 0) as $t
  | (if $truncated then ("+" | yellow) else "" end) as $more
  | if $t == 0 and ($truncated | not) then ("-" | dim)
    elif $t == 0 then ("0" | dim) + $more
    else
      ("\($t)" | cyan) + $more + (" (" | dim)
      + ( threadSegments($stats; $short)
          | map(. as $s | threadSegmentText($s; $short) | paintByName(threadColors[$s.state]))
          | join(threadSegmentSep($short) | dim) )
      + (")" | dim)
    end;
