include "common";

# Inputs supplied by stale-branches.sh: $showAuthor
# Each PR object already carries .branchExists and .author — computed
# alongside the fetch itself by fetch_closed_prs_with_branch_status in
# common.sh.

def merged: .mergedAt != null;

def cells:
  {
    PR:     "#\(.number)",
    TITLE:  .title[0:80],
    AUTHOR: .author,
    BRANCH: .headRefName,
    MERGED: (if merged then "yes" else "-" end),
    CLOSED: isoRel(.closedAt),
    URL:    .url
  };

def headers:
  {
    PR: "PR", TITLE: "TITLE", AUTHOR: "AUTHOR", BRANCH: "BRANCH", MERGED: "MERGED",
    CLOSED: "CLOSED", URL: "URL"
  };

def paint($col):
  if   $col == "PR" then green
  elif $col == "AUTHOR" then cyan
  elif $col == "BRANCH" then cyan
  elif $col == "MERGED" then (if . == "yes" then green else dim end)
  elif $col == "CLOSED" or $col == "URL" then dim
  else . end;

# AUTHOR is only useful once results span more than one person — the
# default "mine" view drops it to stay identical to before --author/--all
# existed.
def cols:
  if $showAuthor then ["PR", "TITLE", "AUTHOR", "BRANCH", "MERGED", "CLOSED", "URL"]
  else ["PR", "TITLE", "BRANCH", "MERGED", "CLOSED", "URL"]
  end;

# Main
[inputs][0]
| cols as $cols
| length as $total
# Oldest-closed-first, same triage convention as mine.jq's sort_by(.createdAt)
# — the longest-forgotten leftover branches surface first.
| (map(select(.branchExists)) | sort_by(.closedAt)) as $rows
| ($rows | length) as $count
| ([$cols[] | headers[.]]) as $headerCells
| ([$rows[] | cells as $all | [$cols[] | $all[.]]]) as $plain
| colWidths($headerCells; $plain) as $w

# Built as separately-colored segments rather than one string wrapped in an
# outer paint — c() (see common.jq) always appends its own reset code, so
# nesting a colored $count inside an outer dim(...) would reset color
# early and leave the rest of the line unstyled.
| ( "\($count | tostring | (if $count == 0 then dim else green end))"
  + (" of \($total) closed PRs still have a branch" | dim) ),
"",

renderHeaderRow($cols; headers; $w),

( range(0; $rows | length) as $r
  | $plain[$r] as $c
  | [ range(0; $c | length) as $i
      | ($c[$i] | paint($cols[$i])) + (" " * ($w[$i] - ($c[$i] | length)))
    ]
  | join("  ")
)
