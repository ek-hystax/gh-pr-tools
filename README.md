# gh-pr-tools

A `gh` extension for PR review triage: who still needs to approve, who already
did, and a table of PRs waiting on you — with optional Telegram links so you
can go ping people.

## Install

```
gh extension install <owner>/gh-pr-tools
gh pr-tools init
```

`init` asks for:
- **repo** (`owner/name`) — defaults to the repo of your current checkout if run inside one
- **org** — used to expand team review requests (e.g. a PR requesting review from the `ui` team) into individual members
- **Jira ticket prefix** (e.g. `KF`) — leave blank to match any `PROJECT-123`-style ticket
- **Jira base browse URL** (e.g. `https://yourorg.atlassian.net/browse`) — leave blank to skip Jira links entirely

Settings are written to `~/.config/gh-pr-tools/config.sh`. Re-run `gh pr-tools init`
anytime to point the same install at a different project.

Team-review expansion additionally needs the `read:org` scope:
```
gh auth refresh -s read:org
```

## Commands

### `gh pr-tools prd <pr-number | TICKET-123 | jira-link | branch-name>`

Shows one PR's approvers and who's still pending, expanding any team review
requests to their members:

```
gh pr-tools prd 886
gh pr-tools prd KF-1309
gh pr-tools prd https://yourorg.atlassian.net/browse/KF-1309
gh pr-tools prd bug/KF-1309
```

### `gh pr-tools todo`

Lists open PRs where you're a pending reviewer, as a table with CI/merge
status, size, and age.

### `gh pr-tools tg add|remove|list|import`

Manage your local GitHub-login → Telegram-handle map (`~/.config/gh-pr-tools/tg-map.json`),
used to render `https://t.me/<handle>` links next to reviewer names in `prd`.

```
gh pr-tools tg add octocat octocat_tg
gh pr-tools tg list
gh pr-tools tg remove octocat
```

To add several people at once, `import` reads a file (or stdin) of `login handle`
or `login,handle` lines — blank lines and `#` comments are skipped:

```
gh pr-tools tg import team.txt
pbpaste | gh pr-tools tg import          # from clipboard
```

Or merge in a raw `{"login": "handle"}` JSON map — handy for copying someone else's
exported map wholesale:

```
gh pr-tools tg import --json team-tg-map.json
```

This map is per-machine, not shared — each person adds the handles they care about.

## Layout

```
gh-pr-tools          entry point — dispatches subcommands, required filename for gh extensions
lib/
  common.sh           config/tg-map loading shared by all subcommands
  init.sh              gh pr-tools init
  prd.sh / prd.jq       gh pr-tools prd
  todo.sh / todo.jq     gh pr-tools todo
  tg.sh                 gh pr-tools tg
```
