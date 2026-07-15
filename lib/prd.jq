include "common";

# Inputs supplied by prd.sh: $teamMembers, $tgmap, $jiraBase, $jiraPattern

def tglink($login):
  ($tgmap[$login] // "") as $u
  | if $u == "" then "-" else "https://t.me/\($u)" end;

def paintDecision:
  if startswith("APPROVED") then green
  elif startswith("CHANGES") then red
  else yellow end;

def paintReason:
  if . == "changes requested" then red
  elif IN("commented", "dismissed") then cyan
  else yellow end;

# Main
. as $pr
| .author.login as $author

# Latest submitted review per reviewer (PR author and pending drafts excluded)
| ($pr | latestReviews($author)
   | map({key: .author.login, value: {state, submittedAt}})
   | from_entries) as $latest

| def reviewedReason($login):
    $latest[$login].state | ascii_downcase | gsub("_"; " ");

# 1. Individually requested users (GitHub itself decides when someone needs
# re-review, e.g. via branch-protection re-request on push — trust reviewRequests
# rather than guessing staleness from commit timestamps)
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

# Union, deduped by login; first reason wins
| ($requested + $teamPending + $nonApproving
   | reduce .[] as $cand ([]; if any(.[]; .login == $cand.login) then . else . + [$cand] end)
  ) as $pending

# Approved: latest review is APPROVED and not overridden by a (re-)request above
| ([ $latest | to_entries[]
     | select(.value.state == "APPROVED")
     | select(any($pending[]; .login == .key) | not)
     | {login: .key, submittedAt: .value.submittedAt} ]
   | sort_by(.submittedAt)) as $approved

# Output
| ( "\("#\($pr.number)" | green)  \($pr.title)" ),
  ( "\("author:" | dim) \($pr.author.login | cyan)   \("updated:" | dim) \(isoRel($pr.updatedAt))   \("decision:" | dim) \($pr.reviewDecision // "PENDING" | paintDecision)" ),
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
      | "  \((.login | green) + (" " * ($lw - (.login | length))))  \(tglink(.login))"
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
