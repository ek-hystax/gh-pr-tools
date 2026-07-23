# gh-pr-tools

A [gh](https://cli.github.com/) extension for PR review triage.

- `prd` — who has approved a PR, and who still needs to
- `todo` — open PRs waiting on your review, including open threads you started and whether the author's answered
- `mine` — your own open PRs: review status, approvals, open threads reviewers started and whether you've answered, CI
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
| **Jira org**             | e.g. `yourorg` → builds `https://yourorg.atlassian.net/browse` — leave blank to skip Jira links |
| **approval threshold**   | How many approvals *you* personally require to call a PR "Approved" in `mine`/`prd` — defaults to `1`. Independent of GitHub's own branch-protection rule, so teams that want stricter review (e.g. 2 approvals) can set it without changing repo settings. |

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

Open PRs waiting on your review:

```bash
gh pr-tools todo
```

Your own open PRs — review status, approvals, open threads, CI:

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

One install, several profiles (typically one per repo). Resolution for `prd` / `todo` / `mine` / `notify`:

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

### Jira ↔ PR matching

Jira integration is optional (`JIRA_BASE_URL` blank → no links). When enabled, tickets must appear in the PR so the tools can connect them.

| Goal                                                     | Requirement                                                                               |
| -------------------------------------------------------- | ----------------------------------------------------------------------------------------- |
| Look up a PR by ticket (`prd KF-1309`, `notify KF-1309`) | Ticket key is in the **PR title** as its own word (e.g. `KF-1309: fix login`)             |
| Look up a PR by Jira browse URL                          | Same — URL's last path segment is treated as the ticket, then matched on title            |
| Look up a PR by branch (`prd bug/KF-1309`)               | Pass the exact head branch name; no ticket needed in the name for this path               |
| Show a Jira link in `prd` output                         | Ticket key in the **branch name or title** (e.g. `feature/KF-1309-login` or `KF-1309: …`) |
| Show a Jira link in `todo` output                        | Ticket key in the **branch name** (title alone is not enough for `todo`)                  |
| Show a Jira link in `mine` output                        | Ticket key in the **branch name** (same convention as `todo`)                             |

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
gh pr-tools prd <pr-number | TICKET-123 | jira-link | branch-name>
```

Shows approvers and who's still pending, expanding team review requests to members. The `decision:` line and "Approved by:" list use your profile's approval threshold (see `mine`, below) rather than GitHub's `reviewDecision`; approvers who belong to one of your own teams are tagged `(team)`.

```bash
gh pr-tools prd 886
gh pr-tools prd KF-1309
gh pr-tools prd https://yourorg.atlassian.net/browse/KF-1309
gh pr-tools prd bug/KF-1309
gh pr-tools -p work prd 886
```

### `todo` — PRs waiting on you

```text
gh pr-tools todo [--long]
```

Lists open PRs where you're a pending reviewer. By default shows a compact table (PR, title, author, status, approvals, your review state, open threads, how long it's been waiting on you, URL); pass `--long` for all columns, adding last-updated, age, re-review, size, CI, merge status, and Jira link.

The `THREADS` column only counts review threads *you* opened that are still open (unresolved) — a thread is attributed to whoever left its opening comment, not every participant. It shows `N (A answered)`: `N` is how many of your threads are still open, `A` is how many the PR author has since replied to (e.g. "Fixed") even though the thread is still open — those are the ones worth going back to re-check, so the answered count is highlighted when non-zero. Shows `-` when you have nothing open.

`STATUS` and `APPROVALS` use the same threshold-based logic as `mine` (see below) rather than GitHub's `reviewDecision`: "Changes requested" if any reviewer's latest review requests changes, "Approved" once distinct approvals meet your profile's approval threshold, otherwise "Pending review". `APPROVALS` shows `total (team)` — total distinct approvers, and in parens how many are members of a team you belong to.

The `WAITING` column is color-graded by how long a review has been outstanding on you — dim under a day, plain 1–3 days, yellow 3–7 days, bold red past a week — so the oldest unaddressed reviews stand out by default. `--long`'s `UPDATED` column is different: the PR's raw last-activity time, not specific to your own review.

### `mine` — your own open PRs

```text
gh pr-tools mine [--long]
```

Lists your own open, non-draft PRs with the columns you need to triage them: review status (Approved / Changes requested / Pending review), open review threads, how long it's been waiting (`WAITING`, same color grading as `todo`), number of approvals, CI status, PR URL, and Jira link (same branch-name convention as `todo`). Pass `--long` to add age, size, and merge status.

`STATUS` is driven by your profile's approval threshold, not GitHub's `reviewDecision` field: it's "Changes requested" if any reviewer's latest review requests changes, "Approved" once distinct approvals meet your threshold, otherwise "Pending review". `APPROVALS` shows `total (team)` — total distinct approvers, and in parens how many of those are members of a team you belong to — colored green once the total meets your threshold. Set your threshold via `gh pr-tools init` or check it with `gh pr-tools profile show`.

The `THREADS` column only counts review threads *reviewers* opened that are still open (unresolved) — a thread is attributed to whoever left its opening comment, not every participant. It shows `N (A answered)`: `N` is how many are still open, `A` is how many you've already replied to (those are now waiting on the reviewer next). The unanswered remainder — the ones you haven't replied to yet — is what's highlighted, since that's what still needs you. Shows `-` when there's nothing open.

```bash
gh pr-tools mine
gh pr-tools mine --long
gh pr-tools -p work mine
```

Open review-thread stats aren't exposed by GitHub's `--json` convenience fields, so both `mine` and `todo` make one extra GraphQL call to fetch them — a single batched request covering every listed PR at once, not one call per PR, so it stays fast regardless of how many PRs you have open.

Both commands also only request the PR fields their current column set needs — size, CI, merge status, age, and Jira link all cost an extra per-PR lookup under the hood, so `--long` fetches noticeably more data than the default view.

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
gh pr-tools profile remove <name>
```

- `list` — all profiles; marks a checkout match with `(cwd)`
- `show [name]` — print settings (default: currently resolved profile)
- `remove <name>` — delete a profile

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
  common.jq             shared jq helpers (ANSI colors, relTime, jira link, CI state) — included via `include "common";` from todo.jq/prd.jq/mine.jq
  init.sh               gh pr-tools init
  profile.sh            gh pr-tools profile
  prd.sh / prd.jq       gh pr-tools prd
  todo.sh / todo.jq     gh pr-tools todo
  mine.sh / mine.jq     gh pr-tools mine
  notify.sh / notify.jq gh pr-tools notify
  tg.sh                 gh pr-tools tg
  clear.sh              gh pr-tools clear
```
