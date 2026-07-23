include "common";

# Inputs supplied by prd.sh: $teamMembers, $teamLogins, $approvalThreshold,
# $tgmap, $jiraBase, $jiraPattern

def tglink($login):
  ($tgmap[$login] // "") as $u
  | if $u == "" then "-" else "https://t.me/\($u)" end;

def paintReason:
  if . == "changes requested" then red
  elif IN("commented", "dismissed") then cyan
  else yellow end;

# Main
. as $pr
| .author.login as $author

# Latest submitted review per reviewer (PR author and pending drafts excluded)
| ($pr | latestReviews($author)
   | map({key: .author.login, value: {state, submittedAt, commit}})
   | from_entries) as $latest

| def reviewedReason($login):
    $latest[$login].state | ascii_downcase | gsub("_"; " ");

# 1. Individually requested users. Scoped to *this* category only: GitHub
# itself decides when someone needs re-review via branch-protection
# re-request on push, so this trusts reviewRequests rather than deriving
# re-review need from commit timestamps. (Category 4 below, stale
# approvals, is a separate signal computed independently of this one.)
  ([ $pr.reviewRequests[]?
     | select(.login)
     | { login,
         reason: (if $latest[.login] then "re-requested" else "requested" end) } ]) as $requested

# 2. Requested teams expanded to members via $teamMembers
| ([ $pr.reviewRequests[]?
     | select(.slug)
     | (.slug | split("/") | last) as $team
     | ($teamMembers[$team] // [])[]
     | select(. != $author)
     | . as $login
     | $latest[$login] as $r
     | if $r == null then {login: $login, reason: "team:\($team)"}
       elif $r.state == "APPROVED" then empty
       else {login: $login, reason: reviewedReason($login)}
       end ]) as $teamPending

# 3. Reviewed, but latest review is not an approval
| ([ $latest | to_entries[]
     | select(.value.state != "APPROVED")
     | {login: .key, reason: (.value.state | ascii_downcase | gsub("_"; " "))} ]) as $nonApproving

# 4. Approved, but new commits have landed since (the review's own commit
# doesn't match the PR's current head) — same staleness rule as
# approverLogins/approvalDecision in common.jq, so this list and the
# decision: line above never disagree about who still counts as approved.
| ([ $latest | to_entries[]
     | select(.value.state == "APPROVED" and (.value.commit.oid // null) != $pr.headRefOid)
     | {login: .key, reason: "stale approval"} ]) as $staleApproved

# Union, deduped by login; first reason wins
| ($requested + $teamPending + $nonApproving + $staleApproved
   | reduce .[] as $cand ([]; if any(.[]; .login == $cand.login) then . else . + [$cand] end)
  ) as $pending

# Approved: latest review is APPROVED against the current head commit, and
# not overridden by a (re-)request above, plus stale approvers (reason ==
# "stale approval" in $pending) tagged (stale). A reviewer can appear here
# and under "Waiting on" at the same time when their approval is stale.
| ([ $latest | to_entries[]
     | select(.value.state == "APPROVED" and (.value.commit.oid // null) == $pr.headRefOid)
     | select(any($pending[]; .login == .key) | not)
     | {login: .key, submittedAt: .value.submittedAt, stale: false} ]
   + [ $pending[] | select(.reason == "stale approval")
     | {login, submittedAt: $latest[.login].submittedAt, stale: true} ]
   | sort_by(.submittedAt)) as $approved

# Output
| ( "\("#\($pr.number)" | green)  \($pr.title)" ),
  ( "\("author:" | dim) \($pr.author.login | cyan)   \("updated:" | dim) \(isoRel($pr.updatedAt))   \("decision:" | dim) \(($pr | approvalStats($author; $teamLogins)) as $stats | (approvalDecision($stats; $approvalThreshold)) as $d | ($d | ascii_downcase | paintDecision))" ),
  "",
  ( "\("PR:" | dim) \($pr.url)" ),
  ( "\("Jira:" | dim) \($pr | jiraFromBranchOrTitle($jiraBase; $jiraPattern))" ),
  ( "\("Branch:" | dim) \($pr.headRefName // "-") -> \($pr.baseRefName // "-")" ),
  "",
  ( if ($approved | length) == 0
    then empty
    else
      "Approved by:",
      ( ($approved | map(.login | length) | max) as $lw
      | $approved[]
      | (if (.login as $l | $teamLogins | index($l)) then ("(team)" | dim) else "" end) as $teamTag
      | (if .stale then ("(stale)" | yellow) else "" end) as $staleTag
      | ([$teamTag, $staleTag] | map(select(. != "")) | join(" ")) as $tags
      | "  \((.login | green) + (" " * ($lw - (.login | length))))  \($tags)  \(tglink(.login))"
      ),
      ""
    end ),
  ( if ($pending | length) == 0
    then ("All reviewers have approved." | green)
    else
      "Waiting on:",
      ( ($pending | map(.login | length) | max) as $lw
      | ($pending | map(.reason | length) | max) as $rw
      | $pending[]
      | "  \(.login + (" " * ($lw - (.login | length))))  \((.reason | paintReason) + (" " * ($rw - (.reason | length))))  \(tglink(.login))"
      )
    end )
