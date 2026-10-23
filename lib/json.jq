include "common";
include "review-state";

# Inputs (print_json, common.sh): $command, $repo, $me, $review, $watchUsers, $teamMembers, $approvalThreshold,
# and for mine $jiraStatuses, $jiraBase, $jiraPattern

def approval:
  .author.login as $a
  | { threshold: $approvalThreshold,
      approvers: approverLogins($a),
      staleApprovers: staleApproverLogins($a),
      changesRequestedBy: changesRequestedLogins($a),
      decision: approvalVerdict(approvalStats($a; []); $approvalThreshold) };

def reviewOut:
  { id, author: (.author.login // "ghost"), state, submittedAt, commitOid: (.commit.oid // null) };

def excerpt:
  gsub("\\s+"; " ") | gsub("^ | $"; "")
  | if length > 200 then .[0:200] | gsub(" $"; "") | . + "…" else . end;

def threadOut($owners; $watchKeys):
  .lastComments.nodes[0] as $last
  | { id,
      state: threadState($owners),
      opener: (.comments.nodes[0].author.login // "ghost"),
      lastAuthor: ($last.author.login // "ghost"),
      watched: (openerKey as $k | $watchKeys | index($k) != null),
      commentCount: .comments.totalCount,
      path: (.path // null),
      url: $last.url,
      lastCommentAt: $last.createdAt,
      excerpt: ($last.bodyText // "" | excerpt) };

# null = lookup failed; todo keeps only threads the viewer opened, as its table does.
def threadsOut:
  ($review[0].rich[.number | tostring]) as $r
  | if $r == null then null
    else
      ($watchUsers | map(.key)) as $watchKeys
      | [ $r.nodes[]
          | select($command == "mine" or .comments.nodes[0].author.login == $me)
          | select(.lastComments.nodes[0] != null)
          | threadOut($r.owners; $watchKeys) ]
    end;

# ciState already says "fail" while other checks still run; "-" (no checks) is "none".
# Drops repeats but keeps first-seen order (unique would sort).
def uniqKeepOrder:
  reduce .[] as $n ([]; if any(.[]; . == $n) then . else . + [$n] end);

# A CheckRun is "workflow / job" when it has a workflow, a StatusContext is its context.
def checkName:
  if (.workflowName // "") != "" and .name then "\(.workflowName) / \(.name)" else (.name // .context // "") end;

def ciOut:
  { state: (ciState | if . == "-" then "none" else . end),
    failedJobs: ([ (.statusCheckRollup // [])[] | select(ciFail(.)) | checkName | select(. != "") ] | uniqKeepOrder | .[0:20]) };

def mergeStateOut:
  (.mergeStateStatus // "") as $s
  | if $s | IN("BEHIND", "BLOCKED", "CLEAN", "DIRTY", "DRAFT", "HAS_HOOKS", "UNSTABLE") then $s | ascii_downcase else "unknown" end;

# Users by login, teams by name (not the "org/slug").
def pendingReviewersOut:
  [ (.reviewRequests // [])[] | (.login // .name) | select(type == "string" and . != "") ] | uniqKeepOrder | .[0:20];

# The ticket named by the branch. null = no ticket key; status null = no token, a failed lookup or an issue
# this account cannot see; url null = no Jira site in the profile.
def jiraOut:
  jiraKeyFromBranch($jiraPattern) as $key
  | if $key == null then null
    else { key: $key,
           url: (if $jiraBase == "" then null else "\($jiraBase)/\($key)" end),
           status: ($jiraStatuses[$key] // null) }
    end;

def prOut:
  { number,
    url,
    title,
    branch: .headRefName,
    author: (.author.login // "ghost"),
    isDraft: (.isDraft // false),
    createdAt,
    updatedAt,
    headOid: .headRefOid,
    reviews: [ .reviews[]? | reviewOut ],
    approval: approval,
    threads: threadsOut,
    threadsTruncated: ($review[0].threads[.number | tostring].truncated // false) }
  + (if $command == "todo" then {requestedFromMe: requestedFrom($me; $teamMembers)} else {ci: ciOut, mergeState: mergeStateOut, pendingReviewers: pendingReviewersOut, jira: jiraOut} end);

{ schemaVersion: 1,
  command: $command,
  generatedAt: (now | floor | strftime("%Y-%m-%dT%H:%M:%SZ")),
  repo: $repo,
  viewer: $me,
  prs: ((if $command == "todo" then map(select(isReviewer($me; $teamMembers))) else . end)
        | sort_by(.createdAt)
        | map(prOut)) }
