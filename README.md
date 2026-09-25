# gh-pr-tools

A [gh](https://cli.github.com/) extension for PR review triage.

- `prd` — who has approved a PR, and who still needs to
- `todo` — open PRs you're a reviewer on (whether or not you've already approved), including the threads you started split by pending / answered / resolved, and viewed-file progress
- `mine` — your own open PRs: review status, approvals, every open thread on them — yours as well as reviewers' — split by pending / answered / resolved, CI
- `track` — the repo's open PRs, drafts included (the oldest 50 by default), or just the ones you name (or keep in a file, re-read on every `--watch` refresh): state, approvals, threads, CI, Jira. Nobody's queue in particular — built for following a set of PRs toward a release
- `stale-branches` — closed PRs whose head branch is still around (yours by default; `--author`/`--all` for others)
- `notify` — poll CI until it finishes (macOS desktop notification when done)

Optional Telegram links next to reviewer names, and Jira ticket links from titles/branches. Multi-repo via named profiles. Bash + jq only — no other runtime.

## Getting Started

### 1. Install gh

macOS:

```bash
brew install gh
```

[Ubuntu/Debian](https://github.com/cli/cli/blob/trunk/docs/install_linux.md#debian):

```bash
(type -p wget >/dev/null || (sudo apt update && sudo apt install wget -y)) \
	&& sudo mkdir -p -m 755 /etc/apt/keyrings \
	&& out=$(mktemp) && wget -nv -O$out https://cli.github.com/packages/githubcli-archive-keyring.gpg \
	&& cat $out | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null \
	&& sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
	&& sudo mkdir -p -m 755 /etc/apt/sources.list.d \
	&& echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null \
	&& sudo apt update \
	&& sudo apt install gh -y
```

Then authenticate:

```bash
gh auth login
```

### 2. Install the extension

```bash
gh extension install ek-hystax/gh-pr-tools
gh pr-tools init
```

`init` creates a **named profile** and asks for:

| Prompt                   | Notes                                                                        |
| ------------------------ | ---------------------------------------------------------------------------- |
| **profile name**         | Defaults to the short repo name (the part after `/`)                         |
| **repo** (`owner/name`)  | Defaults to the current checkout if you're inside one                        |
| **org**                  | Expands team review requests (e.g. the `ui` team) into individual members    |
| **your GitHub username** | Defaults to your `gh` login; required                                        |
| **Jira ticket prefix**   | e.g. `KF` — leave blank to match any `PROJECT-123`-style ticket              |
| **Jira site**            | e.g. `yourorg` or `https://yourorg.atlassian.net` — leave blank to skip Jira links |
| **Jira account email**   | Only asked when a site is set. The Atlassian account an API token belongs to — leave blank for links without ticket status |
| **Jira API token**       | Only asked when an email is set. Input is hidden. Buys the ticket-status lookup; leave blank for links only. See [Jira token](#jira-token) |
| **approval threshold**   | How many approvals *you* personally require to call a PR "Approved" in `todo`/`mine`/`track`/`prd` — defaults to `1`. Independent of GitHub's own branch-protection rule, so teams that want stricter review (e.g. 2 approvals) can set it without changing repo settings. |
| **watched thread authors** | Comma-separated logins (e.g. `coderabbitai`) whose review threads get a column of their own in `todo`/`mine`/`track`, and out of `mine`'s and `track`'s `THREADS` count — leave blank for none. See [Watched thread authors](#watched-thread-authors-thread_watch_users) |

Settings go to `~/.config/gh-pr-tools/profiles/<name>.sh`. Re-run `gh pr-tools init` anytime to add another profile or overwrite an existing one.

Team-review expansion needs the `read:org` scope:

```bash
gh auth refresh -s read:org
```

### 3. First use

Who's approved a PR, and who's still pending:

```bash
gh pr-tools prd 886
```

Open PRs you're a reviewer on:

```bash
gh pr-tools todo
```

Your own open PRs — review status, approvals, review threads, CI:

```bash
gh pr-tools mine
```

Watch a PR's CI until it finishes (desktop notification on macOS):

```bash
gh pr-tools notify 886
```

See [Commands](#commands) below for the full option list and more ways to reference a PR (Jira ticket, Jira link, branch name).

### 4. Update or uninstall

Update to the latest published version:

```bash
gh extension upgrade pr-tools
```

If you installed from a local checkout (`gh extension install .`), the extension is a symlink to your working copy and always runs the current code — nothing to upgrade.

Uninstall completely (removes the extension and all local config — profiles + Telegram map):

```bash
gh pr-tools clear -y
gh extension remove pr-tools
```

### Profiles (multi-repo)

One install, several profiles (typically one per repo). Resolution for `prd` / `todo` / `mine` / `track` / `notify`:

1. `gh pr-tools --profile NAME …` / `-p NAME` (always wins)
2. Else you must be inside a git checkout whose `owner/name` matches exactly one profile's `REPO`:

- Not in a git checkout → error (run `gh pr-tools init`)
- No matching profile (or `gh` can't resolve the repo) → error (run `gh pr-tools init`)
- More than one match → error naming the conflicts (pass `--profile NAME`)

The Telegram map (`tg-map.json`) is **shared** across all profiles.

```bash
gh pr-tools profile list
gh pr-tools --profile side todo
gh pr-tools profile show
gh pr-tools profile remove side
```

### Team roster cache (`GH_PR_TOOLS_TEAM_CACHE`)

Team membership drives several columns: the `team N` part of APPROVALS in `todo` / `mine`, the `(team)` markers in `prd`, and the extra `team-review-requested:` searches that let `todo` see PRs where only your team was asked to review. Rosters change rarely, so those lookups are served from `gh`'s local response cache — **1 hour** by default. Everything about the PRs themselves (searches, reviews, threads, viewed files) is always fetched live.

The trade-off: a membership change can take up to the TTL to show up. If you were just added to a team and `todo` isn't listing its PRs, that's the cache.

Set any [Go duration](https://pkg.go.dev/time#ParseDuration) — `30m`, `1h30m`, `300s` — or `0` to skip the cache entirely:

```bash
GH_PR_TOOLS_TEAM_CACHE=0 gh pr-tools todo     # bypass for one run
```

To change the default, put it in a profile (`~/.config/gh-pr-tools/profiles/<name>.sh`) next to `REPO` and `ORG`:

```bash
GH_PR_TOOLS_TEAM_CACHE=24h
```

An environment value beats the profile. An unparseable value (`60`, `1hour`) is reported on stderr and ignored in favour of `1h`.

### Watched thread authors (`THREAD_WATCH_USERS`)

A review bot can drown out everything else. If CodeRabbit opens 40 threads on a
PR and a human opens two, `mine`'s `THREADS` column reads `42` and the two that
came from a person are invisible.

Name the logins you want split out, and each gets its own column in `todo`,
`mine` and `track`, headed with the login itself:

```bash
THREAD_WATCH_USERS=coderabbitai
THREAD_WATCH_USERS=coderabbitai,sonarcloud
```

`gh pr-tools init` prompts for this; blank means no extra columns and nothing
changes. To change it on a profile you already have, without re-running `init`
and re-entering everything else:

```bash
gh pr-tools profile set thread-watch-users coderabbitai
gh pr-tools profile unset thread-watch-users
```

Their threads are **subtracted** from `THREADS`, so the columns partition the
PR's threads rather than double-counting them — in `mine` and `track`, `THREADS`
then means "threads nobody I am tracking separately opened", which is the number
you actually wanted. In `todo`, `THREADS` counts the threads *you* opened and is
defined by author, so nothing is subtracted from it there.

Matching is case-insensitive, and a trailing `[bot]` is stripped, so
`coderabbitai` and `coderabbitai[bot]` both work. The bare form is what GitHub's
GraphQL API reports; the `[bot]` form is what its web UI and REST API show.

Nothing is validated. A login that never opened a thread and a login that
doesn't exist both render an empty column, so check your spelling if a column
stays `-` forever. An environment value overrides the profile for one run:

```bash
GH_PR_TOOLS_THREAD_WATCH_USERS=coderabbitai gh pr-tools mine
```

### Jira token

Jira **links** need only a site. Showing each ticket's **status** additionally needs an
Atlassian account email and an API token, since Jira's REST API has no anonymous read.

Create a token at
[id.atlassian.com](https://id.atlassian.com/manage-profile/security/api-tokens). A scoped
token needs exactly one scope, `read:jira-work`; a classic token takes no scopes and
inherits your account's own permissions. Read-only is enough — the tool never writes to
Jira. Underneath, you need the **Browse projects** permission on the project, which you
already have if you can open the tickets in a browser. Tokens expire after at most a
year, so this will need redoing.

The token is stored in the profile file like every other setting:

```bash
JIRA_SITE=https://yourorg.atlassian.net
JIRA_EMAIL=you@example.com
JIRA_CLOUD_ID=00000000-0000-0000-0000-000000000000
JIRA_API_TOKEN=ATATT3xFfGF0...
```

`init` resolves `JIRA_CLOUD_ID` for you from `<site>/_edge/tenant_info`, which needs no
credentials. It matters more than it looks: requests go to
`https://api.atlassian.com/ex/jira/<cloud-id>` rather than to your site host, because a
Cloud org can carry an auth policy under which `<site>.atlassian.net` **ignores API-token
credentials and answers as an anonymous user** — returning `200` with an empty result for
a valid and an invalid token alike, instead of `401`. The gateway honors the token and
fails loudly. Leave `JIRA_CLOUD_ID` blank (or omit it) for Data Center/Server, where the
site host is the right base and there is no gateway.

Profiles are created `600` in a `700` directory, so the token isn't readable by other
users on the machine, and `profile show` reports only whether it is `(set)`, never its
value. The file mode is the whole protection, though — keep `~/.config` out of a dotfiles
repo or a synced folder if there's a token in it.

`JIRA_API_TOKEN` in the environment overrides the profile for one invocation, for CI or a
throwaway token:

```bash
JIRA_API_TOKEN=$OTHER_TOKEN gh pr-tools todo --long
```

With no token, links still render and the status column shows `-`.

### Jira ↔ PR matching

Jira integration is optional (`JIRA_SITE` blank → no links). When enabled, tickets must appear in the PR so the tools can connect them.

Profiles written before `JIRA_SITE` existed carry `JIRA_BASE_URL` (the `/browse` URL)
instead. Each is derived from the other at load time, so an older profile keeps working
as-is; re-run `init` only when you want ticket status too.

| Goal                                                     | Requirement                                                                               |
| -------------------------------------------------------- | ----------------------------------------------------------------------------------------- |
| Look up a PR by ticket (`prd KF-1309`, `notify KF-1309`) | Ticket key is in the **PR title** as its own word (e.g. `KF-1309: fix login`)             |
| Look up a PR by Jira browse URL                          | Same — URL's last path segment is treated as the ticket, then matched on title            |
| Look up a PR by branch (`prd bug/KF-1309`)               | Pass the exact head branch name; no ticket needed in the name for this path               |
| Show a Jira link in `prd` output                         | Ticket key in the **branch name or title** (e.g. `feature/KF-1309-login` or `KF-1309: …`) |
| Show a Jira link in `todo` output                        | Ticket key in the **branch name** (title alone is not enough for `todo`)                  |
| Show a Jira link in `mine` output                        | Ticket key in the **branch name** (same convention as `todo`)                             |
| Show a Jira link in `track` output                       | Ticket key in the **branch name or title** (same convention as `prd`)                     |
| Show a ticket's Jira **status**                          | Same as the link, plus a token — see [Jira token](#jira-token)                             |

Ticket shape is `PREFIX-123`. If you set a Jira prefix at init (e.g. `KF`), only that prefix matches; leave it blank to accept any `PROJECT-123`-style key.

Examples that work:

```text
Title:   KF-1309: fix login redirect
Branch:  feature/KF-1309-login
         bug/KF-1309
```

If several open PRs share the same ticket in the title, lookup errors and lists the candidates — use a PR number or branch name instead.

## Commands

### `prd` — reviewers for one PR

```text
gh pr-tools prd [--watch[=INTERVAL]] <pr-number | TICKET-123 | jira-link | branch-name>
```

Shows approvers and who's still pending, expanding team review requests to members. The `decision:` line and "Approved by:" list use your profile's approval threshold (see `mine`, below) rather than GitHub's `reviewDecision`; approvers who belong to one of your own teams are tagged `(team)`.

Pass `--watch` (`-w`) to refresh the PR details in place every 5 minutes, or set an interval such as `--watch=30s`, `--watch 10m`, or `-w=1h`. Because `prd` also takes the PR as an argument, a separate interval needs its unit: `prd --watch 10m 886` refreshes PR 886 every 10 minutes, while `prd --watch 886` shows PR 886 on the 5m default. Write `--watch=90` for a unitless interval in seconds. Refreshes otherwise behave as in `todo` (below).

```bash
gh pr-tools prd 886
gh pr-tools prd --watch 886
gh pr-tools prd --watch 10m 886
gh pr-tools prd KF-1309
gh pr-tools prd https://yourorg.atlassian.net/browse/KF-1309
gh pr-tools prd bug/KF-1309
gh pr-tools -p work prd 886
```

### `todo` — PRs you're reviewing

```text
gh pr-tools todo [--long] [--short-links] [--short-labels] [--include-drafts] [--watch[=INTERVAL]]
```

Lists open PRs where you're an actual reviewer — currently requested, or you've left any review, including ones you've already approved. By default shows a compact table (title, linked PR URL, author, status, your review state, approvals, review threads, viewed-file progress, whether new changes landed since your review, how long it's been in its current state, and the Jira ticket with its status); pass `--long` for all columns, adding last-updated, age, size, CI, and merge status.

The `PR` and `JIRA` columns are always OSC 8 hyperlinks, rendered in underlined cyan so a clickable cell is distinguishable from ordinary colored text — an OSC 8 target is invisible otherwise. Pass `--short-links` (`-s`) to display their labels as `#1154` and `KF-1309` instead of the full URLs — the links still work, and the two widest columns in the table collapse to a few characters. WezTerm supports these links directly.

Draft PRs are left out. Pass `--include-drafts` (`-d`) to list them too; a draft row reads `Draft` in `STATUS`, dimmed, in place of the approval decision, since nothing can merge it until it's marked ready. `APPROVALS` still shows the counts.

Pass `--watch` (`-w`) to refresh in place every 5 minutes until Ctrl-C, with the last successful update time shown above the table. Supply a positive integer with an optional `s`, `m`, or `h` suffix to change the interval, such as `--watch=30s`, `--watch 10m`, or `-w=1h`. This built-in mode preserves colors and hyperlinks, unlike `procps-ng watch`.

Anything a refresh prints on stderr — a skipped PR, a rejected Jira token — is shown below the table rather than being cleared away with the previous frame. A refresh that fails once the watch is running (a network drop, a rate limit) doesn't end it: the last good table stays up under its original "Last updated" time, with the error and a note beneath it, and the next interval tries again. Only a failure on the very first refresh exits, with the error, the same as a single run would — at that point there's nothing to show, and the command line itself is the likely problem.

The `THREADS` column counts review threads *you* opened — a thread is attributed to whoever left its opening comment, not every participant. It shows `N (P pending, A answered, R resolved)`, where `N` is every thread you started on the PR and the three states are disjoint and sum to `N`:

- **pending** — still open with no reply from the PR author yet; the ball is in their court.
- **answered** — still open, but the author's reply is the latest comment (e.g. "Fixed"). These are the ones worth going back to re-check.
- **resolved** — marked resolved on GitHub; settled.

The three states run a traffic light, worst first: `pending` red, `answered` yellow, `resolved` green — so a row reads by color before it reads by number. The leading total stays cyan, outside that scale, since it's a count rather than a state. States with a count of zero are left out, so a fully settled PR reads `4 (4 resolved)` and a brand-new one reads `2 (2 pending)`. Shows `-` only when you opened no threads at all (or when the lookup fails).

Pass `--short-labels` (`-S`) to collapse the state words to their initials — `6 (2 pending, 1 answered, 3 resolved)` becomes `6 (2P 1A 3R)`, and `-` / `0+` / the `+` truncation marker are unchanged. The column is only ever these three states and the colors carry the same meaning either way, so the letters stay readable once you know the shape; it's there for when the thread columns are wider than the rest of the table put together. Independent of `--short-links`, so you can shorten the URLs, the labels, or both.

If [`THREAD_WATCH_USERS`](#watched-thread-authors-thread_watch_users) names any logins, each gets its own column right after `THREADS`, in the order configured, in both the default and `--long` views. The cells use the same `N (P pending, A answered, R resolved)` shape, counted over the threads that login opened. `todo`'s `THREADS` counts threads *you* opened, so nothing is subtracted from it here.

The colors match `THREADS` exactly — the same red / yellow / green — so a single row reads the same way across both columns. Nothing about an open thread is settled: a watched account resolves its own thread once satisfied, so one the PR author has already replied to is still waiting on that account.

A column is rendered even when every row is `-`, so the table keeps its shape between runs.

`VIEWED` shows `N/T`: how many files GitHub says the current viewer marked as viewed out of the first 100 PR files returned by GraphQL. Shows `-` if the viewed-file lookup fails.

`STATUS` and `APPROVALS` use the same threshold-based logic as `mine` (see below) rather than GitHub's `reviewDecision`: "Approved" once distinct approvals meet your profile's approval threshold, "Approved (stale)" if the threshold is only met by counting approvers whose approval is against an older commit, otherwise "Awaiting Approval" — this column doesn't distinguish an outright changes-requested review from one nobody has looked at yet. `APPROVALS` shows `total (team)` — total distinct approvers, and in parens how many are members of a team you belong to.

`NEW CHANGES` shows `yes` when new commits have landed on the PR since your last review (i.e. you should look again), `-` otherwise.

The `PENDING SINCE` column is color-graded by how long the PR has been in its current state relative to you — dim under a day, plain 1–3 days, yellow 3–7 days, bold red past a week — so the oldest unaddressed reviews stand out by default. `--long`'s `UPDATED` column is different: the PR's raw last-activity time, not specific to your own review.

### `mine` — your own open PRs

```text
gh pr-tools mine [--long] [--short-links] [--short-labels] [--include-drafts] [--include-assigned] [--watch[=INTERVAL]]
```

Lists your own open PRs with the columns you need to triage them: title, linked PR URL, review status (Approved / Approved (stale) / Awaiting Approval), review threads, how long it's been pending (`PENDING SINCE`, same color grading as `todo`), number of approvals, CI status, and the Jira ticket with its status (same branch-name convention as `todo`). Pass `--long` to add age, size, and merge status.

Drafts are left out by default, as in `todo`; `--include-drafts` (`-d`) brings them in, with `Draft` in `STATUS`.

Pass `--include-assigned` (`-a`) to also list open PRs you're an assignee on — the case where another developer opened a PR and handed it to you to finish. An `AUTHOR` column appears after `PR`: `-` on your own PRs, the author's login on the ones handed to you. The column comes with the flag rather than with the rows, so a `--watch` table keeps its shape when a handed-over PR merges. On those PRs a thread also counts as **answered** when you posted the last reply, not only when the author did, since the thread is now waiting on you. A draft handed to you still needs `--include-drafts` as well.

As with `todo`, `--short-links` (`-s`) shortens the linked `PR` and `JIRA` cells from full URLs to `#1154` and `KF-1309`.

`--watch` (`-w`) provides the same configurable refresh as `todo` and can be combined with any other flag.

`STATUS` is driven by your profile's approval threshold, not GitHub's `reviewDecision` field: it's "Approved" once distinct approvals meet your threshold, "Approved (stale)" if the threshold is only met by counting approvers whose approval is against an older commit, otherwise "Awaiting Approval" — this column doesn't distinguish an outright changes-requested review from one nobody has looked at yet. `APPROVALS` shows `total (team)` — total distinct approvers, and in parens how many of those are members of a team you belong to — colored green once the total meets your threshold. Set your threshold via `gh pr-tools init` or check it with `gh pr-tools profile show`.

The `THREADS` column counts **every** review thread on the PR, whoever raised it — reviewers, bots, and the ones opened under your own login, which is how threads posted on your behalf by an agent get here. It shows `N (P pending, A answered, R resolved)`, where `N` is every thread on the PR and the three states are disjoint and sum to `N`:

- **pending** — still open and still on your plate; the work left for you.
- **answered** — still open, but you have replied since the thread was opened, so it's waiting on someone else next. On a PR assigned to you (`--include-assigned`), the author's reply counts too.
- **resolved** — marked resolved on GitHub; settled.

Attribution is by opening comment, not by participant, and it decides only which *column* a thread lands in — `THREADS` versus a watched-login column. It does not change what the three states mean: `pending` is always "waiting on you", whether a reviewer asked for the change or you flagged it yourself.

That last part is why a thread you opened needs a **second** comment from you to count as answered. Its opening comment is already yours, so the plain "your reply is the latest comment" test would call a finding answered the moment it was posted — which is exactly backwards for the case the column exists to catch. A thread someone else opened is unaffected: your reply being last already implies a second comment.

The three states run a traffic light, worst first: `pending` red, `answered` yellow, `resolved` green. The leading total stays cyan. States with a count of zero are left out, so a PR you've fully worked through reads `4 (4 resolved)` and one you haven't touched yet reads `2 (2 pending)`. Shows `-` only when the PR has no threads at all (or when the lookup fails).

`--short-labels` (`-S`) collapses the state words here too: `5 (1P 1A 3R)` instead of `5 (1 pending, 1 answered, 3 resolved)`.

If [`THREAD_WATCH_USERS`](#watched-thread-authors-thread_watch_users) names any logins, each gets its own column right after `THREADS`, in the order configured, in both the default and `--long` views — and **their threads leave `THREADS`**, which therefore counts everything you are not tracking separately. Watching your review bot is what makes `THREADS` mean "a human opened this". Watching your *own* login works the same way: your threads move out of `THREADS` and into a column of their own.

The colors match `THREADS` exactly — the same red / yellow / green — so a single row reads the same way across both columns. A watched account resolves its own thread once satisfied, so an open thread you have already replied to is still waiting on it. A column is rendered even when every row is `-`, so the table keeps its shape between runs.

`JIRA` and `JIRA STATUS` are separate columns: the ticket link, and the issue's current
workflow status. Both appear in the default view of `todo`, `mine` and `track`.

`JIRA STATUS` is colored by status **name**:

| Status | Rendered |
| ------ | -------- |
| `Approved` | green |
| `Review` | yellow |
| anything else | gray |

Jira's own `statusCategory` would be the portable choice — three values (`new`,
`indeterminate`, `done`) that every workflow maps onto — but it cannot tell `Approved`
from `Review`: both are `indeterminate`, and those are exactly the two states worth
spotting at a glance. Matching is case-insensitive; adding another name is one more branch
in `jiraStatusPaint`.

The status is fetched for every listed ticket in **one** request, issued while the GitHub
lookups are still in flight, so it costs no meaningful wall-clock time. It shows `-` when
the branch carries no ticket key, when no token is configured, when the issue has been
deleted or isn't visible to you, or when the lookup fails — none of which is worth a
distinct cell. The link still renders in that last case, since the branch named a ticket
either way. A **rejected token** is the one failure that also prints a line to stderr,
since it stays broken until you re-run `init`, and Jira tokens expire within a year.

```bash
gh pr-tools mine
gh pr-tools mine --long
gh pr-tools mine --short-links
gh pr-tools mine --short-links --short-labels
gh pr-tools mine --short-links --watch
gh pr-tools mine --include-drafts
gh pr-tools mine --include-assigned --include-drafts --watch
gh pr-tools -p work mine
```

Review-thread stats aren't exposed by GitHub's `--json` convenience fields, so `mine`, `todo` and `track` each make one extra GraphQL call to fetch them — a single batched request covering every listed PR at once, not one call per PR, so it stays fast regardless of how many PRs you have open. That request takes the first 100 threads per PR, resolved ones included, so a PR with more threads than that can undercount. When it happens the totals are suffixed with `+` — `27+ (3 pending, 24 resolved)` — so an incomplete count reads as incomplete rather than as a wrong number. A bucket can be empty and still truncated, which prints `0+` rather than `-`.

All three also only request the PR fields their current column set needs. `gh` resolves a whole `--json` set in one request per page, but selections like `mergeable`, `mergeStateStatus` and `statusCheckRollup` are computed per PR on GitHub's side, so asking for them multiplies the work the server does before it answers — a 150-row page goes from about a second to about ten. That is why `--long` is noticeably slower than the default view.

### `track` — a board for a set of PRs

```text
gh pr-tools track [--long] [--short-links] [--short-labels] [--limit N] [--list FILE] [--watch[=INTERVAL]] [PR...]
```

`todo` and `mine` are queues: they answer "what is on *my* plate", one from the reviewer's side and one from the author's. `track` answers a different question — "what is the state of *these* PRs" — and takes no view on who you are. It exists for the case where someone is shepherding a set of PRs toward a release and needs to see approvals, threads, CI and Jira status for all of them at once, regardless of who wrote them or who is reviewing.

With no arguments it lists the repo's open PRs, oldest first, **drafts included** and your own included — up to `--limit` of them (50 by default), with a note on stderr when there are more. Name one or more PRs and it lists exactly those instead:

```bash
gh pr-tools track
gh pr-tools track 1154 1160 1177
gh pr-tools track https://github.com/acme/web/pull/1154/files
gh pr-tools track --limit 20 --short-links --short-labels
gh pr-tools track --watch=10m 1154 1160
```

A PR argument is a number or a GitHub PR link. Links are matched on their `<owner>/<repo>/pull/<number>` tail rather than by their last path segment, so the `/files` and `/commits` URLs you get from copying the address bar on a review page work as-is — and so does a GitHub Enterprise host. Because the link names its own repo, a link from a *different* repo is refused rather than quietly reinterpreted as that number in the profile's repo; showing the wrong PR confidently is worse than an error. Leading zeros are ignored, so `0160`, `#0160` and `160` are the same PR.

An argument that can't be used — a typo, an issue number, a link to another repo — prints a line on stderr and is skipped. The rest of the table still renders, so one bad digit doesn't cost you the other nineteen rows.

#### Reading the list from a file

`--list FILE` (`-f`) takes the PRs from a file instead of — or as well as — the command line. One reference per line, in any of the forms arguments accept:

```text
# Release 42 — QA tracking list

1183
#1184
https://github.com/acme/web/pull/1186/files
  691    # MongoDB migration, waiting on CI

# 1199  <- not started yet
```

Each line is trimmed of surrounding whitespace first, so indentation never changes what a line means. Blank lines are skipped. A line starting with `#` is a comment — unless a digit follows the `#` directly, since `#1184` is the PR shorthand. A line like that is always read as a reference, so `#1204 note here` is reported on stderr and skipped, like any other entry that can't be used, rather than vanishing as a comment; write `#1204  # note here` to annotate it. After the first word, a `#` preceded by whitespace starts a trailing comment. A `#` with no whitespace before it is left alone, which is why a URL copied out of a review thread keeps its `#discussion_r…` fragment — harmless, since only the `<owner>/<repo>/pull/<number>` part of a link is read. A trailing carriage return and a leading UTF-8 byte-order mark are dropped, so a file written on Windows works.

The path may be absolute or relative, `--list` may be given more than once, and a list combines with PRs named directly on the command line. Everything keeps the order it was written in, with each list expanded where its flag appeared, and duplicates dropped on first mention.

**The file is re-read on every `--watch` refresh**, which is the point of it. `--watch` re-executes the command each interval and only the path is carried across, never the expanded contents — so you can start a watch once and then edit the list to change what's on the board, without restarting anything:

```bash
gh pr-tools track --list ~/qa/release-42.txt --watch=10m
# ...then just edit release-42.txt; the next refresh picks it up
```

Editors save atomically — write-a-temp-then-rename, or truncate-then-write — so a watched file is briefly missing or empty every time you save it. A refresh that finds the file unreadable says so on stderr and tries again next time rather than killing the watch. A path that can't be read when you *start* a watch is a different thing and fails immediately.

A list naming nothing usable — empty, all comments, or caught mid-save — renders an empty board rather than an error, since an empty list is a valid list. PRs typed straight onto the command line are treated less forgivingly: if none of them resolve — none is a PR reference at all, or none of the numbers has a PR behind it — the invocation was wrong, and `track` says so and exits non-zero instead of printing a bare header row. Under `--watch` that check runs on the first refresh, so a command line that can't show anything fails straight away rather than starting a watch on an empty board.

**Named PRs bypass every filter.** A PR you asked for is shown whatever state it is in: merged, closed, or draft. That is the point — a tracked list that silently drops rows as they merge is indistinguishable from a tracked list that was wrong. `STATE` is the column that carries the difference:

| `STATE` | Rendered | Meaning |
| ------- | -------- | ------- |
| `Open` | cyan | Live and ready for review |
| `Draft` | dim | Live, but the author isn't asking yet |
| `Merged` | green | Shipped |
| `Closed` | red | Abandoned without merging |

`Merged` is green because it is the state this command exists to drive PRs toward — not "healthy" but "done". `Closed` is red because on a list somebody deliberately typed out, an abandoned PR is a discrepancy worth noticing rather than a neutral outcome. Unfiltered, only `Open` and `Draft` can appear.

`STATE` is not `STATUS`, and neither is `CI` or `MERGE`. The four answer different questions: `STATE` is whether the PR is still a live thing, `STATUS` whether the humans have signed off, `CI` whether the checks are green, and `MERGE` (under `--long`) whether the button can be pressed right now. A row reading `Merged · Approved · pass` is history; the same row reading `Open` is a cue to go merge it.

Rows appear in the order you named them, duplicates dropped on first mention — a list of PRs to merge usually has an order, and re-sorting it would throw that away. With no arguments the listing falls back to oldest-first, like `todo` and `mine`.

`STATUS`, `APPROVALS`, `THREADS`, watched-login columns, `CI`, `JIRA`, `JIRA STATUS` and `PENDING SINCE` all mean what they do in `mine`, with three differences:

- `APPROVALS` shows `N/Y` with **no** `(team M)` segment. That split counts approvers who are on a team *you* belong to, which is meaningless in a listing that isn't about you — and skipping it saves the team-membership lookup entirely.
- `JIRA` looks for the ticket key in the **branch name or the title**, the way `prd` does, rather than in the branch name alone the way `todo` and `mine` do. This command lists the whole repo, so it covers authors who put the ticket in the title and never in the branch — for whom branch-only matching renders an unexplained `-`. The practical consequence is that `track` finds tickets on PRs where `todo` and `mine` show nothing.
- A `Merged` or `Closed` row is history, and is drawn that way: `STATUS`, `APPROVALS`, `THREADS`, the watched-login columns, `CI` and `PENDING SINCE` keep their text but render dim, and `MERGE` (under `--long`) shows `-`. In color they would read as calls to action — a PR shipped three weeks ago would show a bold red `PENDING SINCE` and a yellow "Awaiting Approval" nobody is awaiting, and GitHub goes on reporting a merged PR's last computed mergeability, which can be a red `conflict`. `STATE` keeps its color, being the column that says why the rest went quiet, and so do `JIRA` and `JIRA STATUS`, since a ticket can still be moving after its PR merged. `Draft` rows are live and keep every color.

`THREADS` counts every thread on the PR that a watched login didn't open, whoever opened it, as in `mine`. That works unchanged on other people's PRs because the pending / answered / resolved states are defined relative to each PR's own author, not to whoever is running the command: "answered" means *that* PR's author replied last.

`--limit` (`-L`, the same short form `stale-branches` uses) caps the unfiltered listing at 50 PRs by default — the oldest 50, since the listing runs oldest-first. When the repo has more open PRs than the limit, a note on stderr says so (below the table under `--watch`), rather than letting a cut-off board pass for a complete one. It's ignored when you name PRs explicitly: if you listed sixty, you want sixty rows. Raising it is not free — see the note on `--long` and per-PR field cost above.

`--long` (`-l`), `--short-links` (`-s`), `--short-labels` (`-S`) and `--watch` (`-w`) all behave as they do in `todo` and `mine`; `--long` adds `AGE`, `SIZE` and `MERGE`. One difference in `--watch`, shared with `prd`: because `track` takes positional PR numbers, a bare number after a separate `--watch` would be ambiguous, so the interval needs a unit in that form. `track --watch 1154` tracks PR 1154 and refreshes on the 5m default; write `--watch=1154` if you really did mean 1154 seconds.

### `stale-branches` — closed PRs with a leftover branch

```text
gh pr-tools stale-branches [--limit N] [--author LOGIN | --all]
```

Lists closed PRs (merged or just closed) whose head branch is still on the remote — the ones someone meant to delete after merging but didn't. Prints a one-line summary above the table (e.g. `24 of 260 closed PRs still have a branch`) so you get the headline count even before reading the rows. Sorted oldest-closed first, since those are the ones most likely forgotten. No Jira column — `URL` is the way back to the PR here.

Scope defaults to your own PRs (`author:@me`), same as `mine`/`todo`. Pass `--author LOGIN` to check someone else's instead (e.g. a manager spot-checking a teammate), or `--all` to drop the author filter and scan every closed PR in the repo. `--author`/`--all` also add an `AUTHOR` column, since results can span more than one person; the default "mine" view omits it, since it'd always just be you.

Scans your `--limit` most recently updated matching closed PRs (default `1000` — GitHub search's own result ceiling, so a normal run already covers full history for one author). Lower it for a faster, narrower scan. If the matching set exceeds 1000 closed PRs (or a smaller `--limit` cuts it off), the oldest ones past that cutoff aren't scanned — the command warns on stderr when this happens rather than silently under-reporting. `--all` reaches that ceiling far sooner than the default, since it's scanning the whole repo instead of one person's history.

```bash
gh pr-tools stale-branches
gh pr-tools stale-branches --limit 50
gh pr-tools stale-branches --author teammate-login
gh pr-tools stale-branches --all
gh pr-tools -p work stale-branches
```

Uses GraphQL's `search` field directly (paginated 100 at a time) rather than `gh pr list`, so listing matching closed PRs and checking whether each one's branch still exists happens in the same query: `headRefName` is retained as a string forever even after the branch is deleted, but the actual `headRef` object turns `null` once it's gone — that's the only reliable signal, and this fetches it alongside everything else instead of a separate follow-up call.

### `notify` — watch CI

```text
gh pr-tools notify <pr-number | TICKET-123 | jira-link | branch-name>
```

Polls a PR's CI checks every 5 seconds (same PR arguments as `prd`) and stops once every check reaches a terminal state, printing a live status line meanwhile:

```bash
gh pr-tools notify 886
gh pr-tools notify KF-1309
gh pr-tools notify bug/KF-1309
```

Exits `0` when all checks pass, `1` if any failed — so it composes with `&&` / `||`:

```bash
gh pr-tools notify 886 && git checkout main
```

Runs until checks finish or you `Ctrl-C`. On macOS it also fires a native desktop notification ("CI passed" / "CI failed") so you can tab away. Elsewhere it still polls and prints the same terminal output — just no popup.

### `profile` — manage profiles

```bash
gh pr-tools profile list
gh pr-tools profile show [name]
gh pr-tools profile set <key> [value]
gh pr-tools profile unset <key>
gh pr-tools profile remove <name>
```

- `list` — all profiles; marks a checkout match with `(cwd)`
- `show [name]` — print settings (default: currently resolved profile)
- `set <key> [value]` — change one setting without re-running `init`
- `unset <key>` — drop one setting, reverting it to its default
- `remove <name>` — delete a profile

`set` and `unset` act on the resolved profile; use the global `--profile NAME`
to pick another. Keys are case-insensitive and `-` is accepted for `_`, so
these are the same key:

```bash
gh pr-tools profile set thread-watch-users coderabbitai
gh pr-tools profile set THREAD_WATCH_USERS coderabbitai
gh pr-tools -p work profile set approval-threshold 2
```

The rewrite is line-oriented: the one key changes where it stands and every
other line — including comments and keys these commands don't know about — is
left alone, as is the file's owner-only mode. A key written as `export KEY=` or
indented counts as the same key, since a hand-edited file sources it that way.
Each value is validated at least as strictly as `init` validates the matching
prompt, so `set` can't write a profile `init` would have refused. An unknown
key is rejected rather than written, which is the main thing this buys over
editing the file by hand.

Omit the value to be prompted for it. For `jira-api-token` that's required —
it refuses a value on the command line, since a command line is visible to
`ps` and lands in shell history:

```bash
gh pr-tools profile set jira-api-token      # prompts, hidden
```

`REPO`, `ORG` and `GH_USERNAME` can be changed but not unset — `init` requires
all three.

Changing `jira-site` normalizes a bare org into a full URL. Both `jira-site`
and `jira-api-token` then reconcile the stored cloud ID, which belongs to one
site and is only worth keeping alongside a token: it is re-resolved when the
profile has both, and dropped otherwise. That is why setting the token
resolves the cloud ID too, rather than leaving a token with no ID behind —
without one, Jira requests fall back to the site host, where some orgs answer
a valid token as an anonymous user and the status column silently goes blank.

### `tg` — Telegram map

Map GitHub logins → Telegram handles in `~/.config/gh-pr-tools/tg-map.json` (shared across profiles). Used to render `https://t.me/<handle>` links next to reviewer names in `prd`.

```bash
gh pr-tools tg add octocat octocat_tg
gh pr-tools tg list
gh pr-tools tg remove octocat
```

Bulk-add from a file (or stdin) of `login handle` or `login,handle` lines — blank lines and `#` comments are skipped:

```bash
gh pr-tools tg import team.txt
pbpaste | gh pr-tools tg import          # from clipboard
```

Or merge a raw `{"login": "handle"}` JSON map — handy for copying someone else's map wholesale:

```bash
gh pr-tools tg import --json team-tg-map.json
```

Per-machine, not shared — each person adds the handles they care about.

### `clear` — wipe local config

Removes everything under `~/.config/gh-pr-tools` (profiles + tg-map). Prompts unless `-y` / `--yes` is passed. Combine with removing the extension for a full uninstall:

```bash
gh pr-tools clear -y
gh extension remove pr-tools
```

## Layout

```text
gh-pr-tools             entry point — dispatches subcommands (required gh-extension filename)
lib/
  common.sh             profile resolution + tg-map loading
  common.jq             shared jq helpers (ANSI colors, relTime, jira link, CI state, the SIZE/MERGE/watched-login cells, and the table renderer todo/mine/track share) — included via `include "common";` from todo.jq/prd.jq/mine.jq/track.jq/stale-branches.jq
  init.sh               gh pr-tools init
  profile.sh            gh pr-tools profile
  prd.sh / prd.jq       gh pr-tools prd
  todo.sh / todo.jq     gh pr-tools todo
  mine.sh / mine.jq     gh pr-tools mine
  track.sh / track.jq   gh pr-tools track
  stale-branches.sh / stale-branches.jq  gh pr-tools stale-branches
  notify.sh / notify.jq gh pr-tools notify
  tg.sh                 gh pr-tools tg
  clear.sh              gh pr-tools clear
```
