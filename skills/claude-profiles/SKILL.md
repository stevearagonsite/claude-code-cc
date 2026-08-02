---
name: claude-profiles
description: >
  Multiple Claude Code accounts authenticated in parallel on this machine, switched with
  `cc use <profile>`, pinned per project with a `.cc-profile` file (like .nvmrc), and inspected
  with `cc list` to see how much limit is left on each. Use when asked to switch Claude Code
  account or subscription, to tell which account is in use, to pin the account for a repo or
  directory, to check remaining usage (5h session window, weekly, or per model), to diagnose an
  unexpected login prompt, or when one account runs out of limit and work has to move to
  another.
metadata:
  type: reference
  version: "0.4.0"
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

Everything hangs off `cc` (a zsh function), which uses **subcommands**. The first argument
decides: a known verb belongs to `cc`, anything else is passed straight to `claude` untouched —
so `claude`'s own flags never collide.

| Command | What it does | Launches Claude? |
|---|---|---|
| `cc [args…]` | Effective profile, with the configured claude args | yes |
| `cc use <n> [args…]` | Switch the global profile and launch (`default` = original slot) | yes |
| `cc switch [<n>]` | Switch profile keeping the current conversation | yes |
| `cc list` | Profile table with remaining limits | no |
| `cc add <n>` | Create profile `<n>` by cloning the **active** profile's blob | no |
| `cc set [<n>]` | Write `./.cc-profile` (no argument removes it) | no |
| `cc help` | Help, plus active and per-directory profile | no |

Delegation examples — all of these reach `claude` as-is:

```bash
cc -p "explain this"        # claude's --print, NOT a profile flag
cc --resume <session-id>
cc use work --resume <id>   # profile AND resume
cc -- list                  # escape hatch: send "list" to claude
```

After `cc add <n>` the new profile is a clone of the current session — enter it once with
`cc use <n>` and run `/login` with the other account.

The command name may differ: it is set by `CC_CMD` at install time (`cc` by default, because
`cc` shadows `/usr/bin/cc`, the C compiler).

## Which profile is actually used

Four layers; the first that applies wins:

| # | Layer | Scope | Persists? |
|---|---|---|---|
| 1 | `cc use <n>` / `cc switch <n>` | Sets the global profile, then launches | **Yes** — writes `~/.claude-profiles/active` |
| 2 | `./.cc-profile` (nearest, walking up to `$HOME`) | That invocation of `cc` only | No |
| 3 | `CLAUDE_SECURESTORAGE_CONFIG_DIR` in the environment | That shell and its children | Per shell |
| 4 | Nothing set → the `default` Keychain item | — | — |

Layer 1 is global: `~/.claude-profiles/active` is re-exported by every new shell, so plain
`claude` follows it too, not only `cc`. Layer 2 never persists — leaving the directory is enough
to go back — and if the file names a profile that doesn't exist, `cc` exits 2 without launching
Claude rather than falling through to layer 3.

An already-open terminal keeps the global profile it started with. When in doubt, `cc list`
marks the active one with `*` and adds a line for the current directory.

## Switching mid-conversation

A running process never re-reads its credentials, so switching accounts means relaunching. The
conversation survives because history lives in `~/.claude`, shared across profiles.

Inside a session, `cc switch <profile>` (from the `!` prompt or the Bash tool) records the
request — profile + `$CLAUDE_CODE_SESSION_ID` in `~/.claude-profiles/pending-switch` — and
prints the exact command to run after exiting. Outside a session, `cc switch` consumes that
pending request and relaunches with `--resume <id>` under the new profile. The pending request
is used once and ignored after an hour; without one, `cc switch <profile>` falls back to
`--continue`.

`cc-profiles switch <profile>` does the same recording and is a real executable, so it works
from bash or any shell that never sources `cc.zsh`.

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

Write it with `cc set work`; `cc set` alone removes it.

## Reading `cc list`

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

## Where `cc` exists, and where it doesn't

`cc` is a zsh function, sourced from **`~/.zshenv`** — which zsh reads for *every* shell, not
just interactive ones. `cc.zsh` then defines the command only when the shell is interactive or
`CLAUDECODE` is set:

| Context | `cc` resolves to |
|---|---|
| A terminal | the profile switcher |
| Claude Code's `!` prompt / Bash tool (`CLAUDECODE=1`) | the profile switcher |
| Build scripts, CI, `zsh -c` from another program | `/usr/bin/cc`, the **C compiler** |

That last row is deliberate: `cc` is the C compiler's name, and a `Makefile` compiling under
zsh must reach the real one. If `cc switch` ever fails with `clang: no such file or directory`,
the file is being sourced from `~/.zshrc` instead of `~/.zshenv`.

`cc-profiles` is a real executable on the `PATH`, so it works in every context, including
bash:

```bash
cc-profiles                          # = cc list
cc-profiles switch <profile>         # = cc switch, records the pending switch
cat ~/.claude-profiles/active        # globally active profile
cat .cc-profile                      # this project's profile, if any

# equivalent of `cc use <profile>` for a one-off command:
CLAUDE_SECURESTORAGE_CONFIG_DIR="$HOME/.claude-profiles/work" claude -p "…"

zsh -ic 'cc help'                    # or load the functions explicitly
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
`cc list` and `/usage`, both of which read the API's counters.

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

`cc add` refuses to overwrite an existing profile. To re-seed MCP tokens into one that is
already logged in, delete it first — which **also deletes its login**, so another `/login`
follows:

```bash
svc="Claude Code-credentials-$(printf '%s' "$HOME/.claude-profiles/<n>" | shasum -a 256 | cut -c1-8)"
security delete-generic-password -a "$USER" -s "$svc"
rm -rf ~/.claude-profiles/<n>
cc add <n>          # clones from the active profile again
```

That same pair of commands is how you **delete** a profile.
