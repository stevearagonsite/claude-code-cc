---
name: claude-profiles
description: >
  Multiple Claude Code accounts authenticated in parallel on this machine, switched with
  `cc -p <profile>`, pinned per project with a `.cc-profile` file (like .nvmrc), and inspected
  with `cc -l` to see how much limit is left on each. Use when asked to switch Claude Code
  account or subscription, to tell which account is in use, to pin the account for a repo or
  directory, to check remaining usage (5h session window, weekly, or per model), to diagnose an
  unexpected login prompt, or when one account runs out of limit and work has to move to
  another.
metadata:
  type: reference
  version: "0.1.0"
---

# Claude Code account profiles

Several accounts stay logged in **at the same time**, each in its own Keychain item. Switching
between them never asks for a login. Everything else in `~/.claude` (settings, skills, plugins,
agents, statusline, history, memory) is shared across profiles.

Installed from [claude-code-cc](https://github.com/stevearagonsite/claude-code-cc).

## Where a profile lives

| | |
|---|---|
| Directory | `~/.claude-profiles/<name>` |
| Keychain item | `Claude Code-credentials-<sha256(directory)[0:8]>` |
| `default` profile | no directory — the plain `Claude Code-credentials` item |

The suffix isn't arbitrary: Claude Code derives it from whatever path is in
`CLAUDE_SECURESTORAGE_CONFIG_DIR`. To reproduce the item name for a profile:

```bash
printf 'Claude Code-credentials-%s' \
  "$(printf '%s' "$HOME/.claude-profiles/<name>" | shasum -a 256 | cut -c1-8)"
```

To see which profiles exist: `ls ~/.claude-profiles/` (directories only; `active` is a file).

## Commands

Everything hangs off `cc` (a zsh function). Flags that don't launch Claude stop there.

| Command | What it does | Launches Claude? |
|---|---|---|
| `cc [args…]` | Effective profile, with the configured claude args | yes |
| `cc -p\|--profile <n>` | Switch the global profile and launch (`default` = original slot) | yes |
| `cc -s\|--set <n>` | Write `./.cc-profile` | no |
| `cc -s\|--set` | Remove `./.cc-profile` | no |
| `cc -a\|--add <n>` | Create profile `<n>` by cloning the **active** profile's blob | no |
| `cc -l\|--list` | Profile table with remaining limits | no |
| `cc -h\|--help` | Help, plus active and per-directory profile | no |

After `cc -a <n>` the new profile is a clone of the current session — enter it once with
`cc -p <n>` and run `/login` with the other account.

The command name may differ: it is set by `CC_CMD` at install time (`cc` by default, because
`cc` shadows `/usr/bin/cc`, the C compiler).

## Which profile is actually used

Three layers, highest priority first:

1. **`cc -p <n>`** — explicit. Always wins and **persists**: written to
   `~/.claude-profiles/active` and exported by each new shell, so plain `claude` follows it too.
2. **`.cc-profile`** in the current directory or a parent — override for **that invocation
   only**. Does not touch the active profile and does not affect plain `claude`.
3. **Active profile** — whatever `-p` set last.

An already-open terminal keeps the global profile it started with. When in doubt, `cc -l` marks
the active one with `*` and adds a line for the current directory.

## `.cc-profile` (per-project profile)

Like `.nvmrc` or `.python-version`: one line with the profile name.

```
work
```

Looked up from the cwd **upward** to `$HOME` (or `/` outside the home); the nearest one wins.
Blank lines, whitespace and `#` comments are ignored. When it applies, `cc` announces it:

```
cc: profile 'work' (.cc-profile in ~/src/some-repo)
```

If the file names a profile that does not exist, **`cc` exits 2 and does not launch Claude** —
the point is to avoid burning the wrong account's quota on a typo.

Write it with `cc -s work`; `cc -s` alone removes it.

## Reading `cc -l`

```
  PROFILE   PLAN         5h     7d   MODEL       RESET
  default   max · 20x   100%    71%   Opus 66%   5h 4h52m · 7d 1d5h
* work      team · 5x    99%   100%   Opus 100%  5h 4h32m · 7d 6d21h

  * = active profile · % = available · 5h = session window, 7d = weekly
```

Numbers come from `GET https://api.anthropic.com/api/oauth/usage` (the endpoint `/usage` uses
internally), with each profile's access token as `Authorization: Bearer` plus the
`anthropic-beta: oauth-2025-04-20` header.

Three things to read the table correctly:

- **These are utilization percentages, not absolute tokens.** The column shows what's
  *available* (`100 - utilization`); `/usage` inside a session shows what's *used*. They add
  up to 100.
- **`5h` is not "today"**: it's the rolling session window (`five_hour`, what Claude Code calls
  the *session limit*). `7d` is weekly.
- **`MODEL`** is the weekly limit scoped to a model (`weekly_scoped`). It often runs out before
  the general weekly one, so it's usually the number that actually stops you.

Two profiles show identical numbers while they are the same account (one is a clone of the
other).

States without numbers: `(no session)`, `token expired`, `token rejected`, `offline`. Expiry is
detected by reading `expiresAt` from the blob, without hitting the API.

## Gotcha when running from a tool, not a terminal

`cc` is a **zsh function**: it does not exist in a non-interactive shell, such as an agent's
Bash tool. The listing, however, is an executable on the `PATH`:

```bash
cc-profiles                          # = cc -l, works from a Bash tool
cat ~/.claude-profiles/active        # globally active profile
cat .cc-profile                      # this project's profile, if any

# equivalent of `cc -p <profile>` for a one-off command:
CLAUDE_SECURESTORAGE_CONFIG_DIR="$HOME/.claude-profiles/work" claude -p "…"

zsh -ic 'cc -h'                      # or load the functions explicitly
```

Never set `CLAUDE_SECURESTORAGE_CONFIG_DIR=""`: an empty string means the default and collapses
every profile onto the same Keychain item.

## What is isolated and what isn't

**Per profile** — the whole Keychain blob:

```
claudeAiOauth: accessToken, refreshToken, expiresAt, scopes, subscriptionType, rateLimitTier
mcpOAuth:      one entry per authorized MCP server
```

That's why creating a profile **clones** the blob: otherwise every MCP server would need to be
re-authorized through the browser. A later `/login` overwrites only `claudeAiOauth` and leaves
`mcpOAuth` intact.

**Shared**: all of `~/.claude` — settings, skills, plugins, agents, commands, statusline,
`projects/`, history and memory. Plus `~/.claude.json`.

**Careful with the email shown by `/status` and the statusline**: it comes from `oauthAccount`
in `~/.claude.json`, which is shared, so it reflects whichever profile logged in or refreshed a
token last. It can be stale. Actual API calls do use the right account. Reliable sources:
`cc -l` and `/usage`, both of which read the API's counters.

MCP servers hosted by claude.ai are tied to the account that authorized them: under a different
profile they may return 401 and ask for re-auth. Self-hosted or third-party MCP servers do not
depend on the Claude account and work fine cloned.

## Diagnosing

A profile asks for login unexpectedly → check that its Keychain item exists:

```bash
svc="Claude Code-credentials-$(printf '%s' "$HOME/.claude-profiles/<n>" | shasum -a 256 | cut -c1-8)"
security find-generic-password -a "$USER" -s "$svc" >/dev/null && echo ok
```

If the item is there but it still asks after a Claude Code upgrade:
`CLAUDE_SECURESTORAGE_CONFIG_DIR` **is undocumented** — the naming scheme comes from the
binary. Re-read the function that builds it:

```bash
B=~/.local/share/claude/versions/<version>
grep -a -o -E '.{200}-credentials.{200}' "$B" | grep CLAUDE_SECURESTORAGE_CONFIG_DIR
```

Look for `` `Claude Code${OAUTH_FILE_SUFFIX}${e}${o}` `` with `o = -sha256(dir)[0:8]`. If it
changed, the fallback is a per-profile `CLAUDE_CONFIG_DIR` plus symlinks for `settings.json`,
`skills/`, `plugins/`, `agents/`, `commands/` and `CLAUDE.md` back into `~/.claude`.

`cc -a` refuses to overwrite an existing profile. To re-seed MCP tokens into one that is
already logged in, delete it first — which **also deletes its login**, so another `/login`
follows:

```bash
svc="Claude Code-credentials-$(printf '%s' "$HOME/.claude-profiles/<n>" | shasum -a 256 | cut -c1-8)"
security delete-generic-password -a "$USER" -s "$svc"
rm -rf ~/.claude-profiles/<n>
cc -a <n>          # clones from the active profile again
```

That same pair of commands is how you **delete** a profile.
