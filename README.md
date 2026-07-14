# gh-pr-tools

A `gh` extension for PR review triage: who still needs to approve, who already
did, and a table of PRs waiting on you — with optional Telegram links so you
can go ping people.

## Install

```
gh extension install <owner>/gh-pr-tools
gh pr-tools init
```

`init` creates a **named profile** and asks for:

- **profile name** — defaults to the short repo name (the part after `/`)
- **repo** (`owner/name`) — defaults to the repo of your current checkout if run inside one
- **org** — used to expand team review requests (e.g. a PR requesting review from the `ui` team) into individual members
- **your GitHub username** — defaults to your `gh` login; required
- **Jira ticket prefix** (e.g. `KF`) — leave blank to match any `PROJECT-123`-style ticket
- **Jira base browse URL** (e.g. `https://yourorg.atlassian.net/browse`) — leave blank to skip Jira links entirely

Settings are written to `~/.config/gh-pr-tools/profiles/<name>.sh`. Re-run
`gh pr-tools init` anytime to add another profile or overwrite an existing one.

### Profiles (multi-repo)

You can keep one install and several profiles (one per repo). Resolution for
`prd` / `todo`:

1. `gh pr-tools --profile NAME …` / `-p NAME` (always wins)
2. Else, you must be inside a git checkout with a profile whose `REPO`
   matches that checkout's `owner/name` (exactly one match):
   - Not inside a git checkout at all → error, run `gh pr-tools init`
   - No profile matches this repo (or `gh` can't resolve it) → error, run
     `gh pr-tools init`
   - More than one profile matches → error naming the conflicting profiles,
     suggesting `--profile NAME`

The Telegram map (`tg-map.json`) is **shared** across all profiles.

```
gh pr-tools profile list
gh pr-tools --profile side todo
gh pr-tools profile show
gh pr-tools profile remove side
```

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
gh pr-tools -p work prd 886
```

### `gh pr-tools todo`

Lists open PRs where you're a pending reviewer, as a table with CI/merge
status, size, and age.

### `gh pr-tools notify <pr-number | TICKET-123 | jira-link | branch-name>`

Polls a PR's CI checks every 5 seconds (accepting the same PR arguments as
`prd`) and stops once every check reaches a terminal state, printing a live
status line in the meantime:

```
gh pr-tools notify 886
gh pr-tools notify KF-1309
gh pr-tools notify bug/KF-1309
```

Exits `0` when all checks pass, `1` if any check failed — so it composes with
`&&`/`||` (e.g. `gh pr-tools notify 886 && git checkout main`). Runs until the
checks finish or you `Ctrl-C`.

On macOS it additionally fires a native desktop notification when the checks
finish ("CI passed" on pass, "CI failed" on failure), so you can tab away.
On other platforms (e.g. Linux) the command still polls and prints the same
terminal status/result — it just doesn't pop a notification.

### `gh pr-tools profile list|show|remove`

Manage named profiles:

- **`list`** — list all profiles, marking a checkout match with `(cwd)`
- **`show [name]`** — print a profile's settings (default: the currently
  resolved profile)
- **`remove <name>`** — delete a profile

```
gh pr-tools profile list
gh pr-tools profile show [name]
gh pr-tools profile remove work
```

### `gh pr-tools tg add|remove|list|import`

Manage your local GitHub-login → Telegram-handle map (`~/.config/gh-pr-tools/tg-map.json`),
used to render `https://t.me/<handle>` links next to reviewer names in `prd`.
Shared across profiles.

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

### `gh pr-tools clear [-y|--yes]`

Removes all per-machine config created by `init`/`tg` (`~/.config/gh-pr-tools`,
profiles and tg-map included). Prompts for confirmation unless `-y`/`--yes` is
passed. Combine with removing the extension itself for a full uninstall:

```
gh pr-tools clear -y
gh extension remove pr-tools
```

## Layout

```
gh-pr-tools          entry point — dispatches subcommands, required filename for gh extensions
lib/
  common.sh           profile resolution + tg-map loading shared by all subcommands
  init.sh              gh pr-tools init
  profile.sh           gh pr-tools profile
  prd.sh / prd.jq       gh pr-tools prd
  todo.sh / todo.jq     gh pr-tools todo
  notify.sh / notify.jq gh pr-tools notify
  tg.sh                 gh pr-tools tg
  clear.sh              gh pr-tools clear
```
