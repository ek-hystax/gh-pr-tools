# Request building and page merging for fetch_pr_review_state in common.sh
# (included via `include "review-state";` with `jq -L "$dir"`). The counting
# rules stay in common.sh; everything here only moves pages around.
#
# The state these defs pass between rounds is, per PR:
#   {"<number>": {"threads": <conn>, "files": <conn> | null, "changedFiles": N | null}}
# where <conn> is {nodes, hasNext, cursor, pages, failed} and a files <conn>
# also carries "offsets" (see offsetCursor). files is null when the caller
# did not ask for it or its first page came back without nodes.

def threadSel:
  "pageInfo{hasNextPage endCursor} nodes{isResolved comments(first:1){totalCount nodes{author{login}}} lastComments: comments(last:1){nodes{author{login}}}}";

def fileSel: "pageInfo{hasNextPage endCursor} nodes{viewerViewedState}";

# PR files cursors are the base64 of the item offset ("MTAw" is 100), so any
# page can be asked for without walking the ones before it. GitHub does not
# document that, so it is only relied on for a PR whose first page ended on
# exactly this cursor (init sets "offsets"); anything else falls back to
# following endCursor. reviewThreads cursors are opaque and always followed.
# Padding is stripped to match what GitHub emits ("Mw" for 3); padded input
# is accepted too, and offsets of 100 to 900 never need padding anyway. An
# offset past the last file returns an empty page rather than an error.
def offsetCursor: tostring | @base64 | gsub("="; "");

# A page with no nodes array failed, whether the whole alias came back null
# or GitHub rejected the cursor, which leaves the connection present with
# nodes: null.
def pageOk: (.nodes | type) == "array";

def conn: {nodes, hasNext: (.pageInfo.hasNextPage // false), cursor: .pageInfo.endCursor, pages: 1, failed: false};

def firstRequest($owner; $repo; $wantViewed):
  { query: ("query($owner:String!,$repo:String!){repository(owner:$owner,name:$repo){"
            + (map("pr\(.number):pullRequest(number:\(.number)){reviewThreads(first:100){\(threadSel)}"
                   + (if $wantViewed then " changedFiles files(first:100){\(fileSel)}" else "" end)
                   + "}")
               | join(" "))
            + "}}"),
    variables: {owner: $owner, repo: $repo} };

# Input is the first response. A PR whose alias came back null is left out
# (its row renders "-"), so one bad PR no longer blanks the rest; only a
# response with no repository object at all is an error.
def init($wantViewed):
  .data.repository
  | if type == "object" then . else error("no repository in response") end
  | to_entries
  | map(select(.value.reviewThreads | pageOk)
        | {key: (.key | ltrimstr("pr")),
           value: {threads: (.value.reviewThreads | conn),
                   changedFiles: .value.changedFiles,
                   files: (if $wantViewed and (.value.files | pageOk)
                           then .value.files | conn | .offsets = (.cursor == (100 | offsetCursor))
                           else null end)}})
  | from_entries;

# The aliases the next round asks for, one entry each. A connection stays in
# the plan while it has a next page, has not failed, and has fewer than
# $maxPages pages. Threads get one alias per PR per round. Files with offsets
# get every remaining page up to changedFiles (or $maxPages) at once, aliased
# f<number>_<page> and listed in page order so the merge sees the last page
# last; at least one page is asked for even if changedFiles says there is
# nothing left.
# A round holds at most $maxAliases aliases, threads first, so a slow or
# failed round of file pages cannot take every thread page down with it.
# What does not fit waits for the next round: a cut fan-out resumes from the
# pages that did arrive, since .pages counts them.
# Not $max: a def parameter $x also defines a filter x, which would shadow
# the max builtin used below.
def plan($maxPages; $maxAliases):
  [ to_entries[] | .key as $num | .value as $pr
    | ($pr.threads
       | select(.hasNext and (.failed | not) and .pages < $maxPages)
       | {alias: "t\($num)", num: $num, conn: "threads", after: .cursor}),
      ($pr.files
       | select(. != null and .hasNext and (.failed | not) and .pages < $maxPages)
       | if .offsets then
           ([([(($pr.changedFiles // 0) / 100 | ceil), .pages + 1] | max), $maxPages] | min) as $last
           | range(.pages; $last) as $k
           | {alias: "f\($num)_\($k)", num: $num, conn: "files", after: ($k * 100 | offsetCursor)}
         else {alias: "f\($num)", num: $num, conn: "files", after: .cursor} end) ]
  | (map(select(.conn == "threads")) + map(select(.conn == "files")))[:$maxAliases]
  | to_entries
  | map(.value + {var: "c\(.key)"});

# Cursors go in as variables rather than query text.
def request($owner; $repo; $plan):
  { query: ("query($owner:String!,$repo:String!"
            + ($plan | map(",$\(.var):String!") | join(""))
            + "){repository(owner:$owner,name:$repo){"
            + ($plan
               | map("\(.alias):pullRequest(number:\(.num)){"
                     + (if .conn == "threads"
                        then "reviewThreads(first:100,after:$\(.var)){\(threadSel)}"
                        else "files(first:100,after:$\(.var)){\(fileSel)}" end)
                     + "}")
               | join(" "))
            + "}}"),
    variables: ({owner: $owner, repo: $repo} + ($plan | map({(.var): .after}) | add)) };

# Input is the state the plan was built from; $repo is the response
# repository object ({} when the round failed outright). A failed page marks
# its connection failed, which takes it out of the plan and makes it
# truncated whatever later pages of the same round report.
def merge($plan; $repo):
  reduce $plan[] as $e (.;
    ($repo[$e.alias] | if $e.conn == "threads" then .reviewThreads else .files end) as $page
    | if $page | pageOk
      then .[$e.num][$e.conn] |= (.nodes += $page.nodes
                                  | .hasNext = ($page.pageInfo.hasNextPage // false)
                                  | .cursor = $page.pageInfo.endCursor
                                  | .pages += 1)
      else .[$e.num][$e.conn].failed = true end);

# Whether a connection stopped short of its last page.
def connTruncated: .hasNext or .failed;
