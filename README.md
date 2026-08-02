# claude-code-cc

Switch between multiple authenticated Claude Code accounts from the terminal — without logging
in again every time, and without duplicating your `~/.claude` setup.

```
$ cc list

  PROFILE   PLAN         5h     7d   MODEL       RESET
  default   max · 20x   100%    71%   Opus 66%   5h 4h52m · 7d 1d5h
  personal  max · 20x   100%    71%   Opus 66%   5h 4h52m · 7d 1d5h
* work      team · 5x    99%   100%   Opus 100%  5h 4h32m · 7d 6d21h

  * = active profile · % = available · 5h = session window, 7d = weekly
```

## Why

Claude Code stores one session at a time. If you have a personal subscription and a work/team
seat, using both means logging out and back in — losing your MCP server authorizations in the
process. This gives each account its own credential slot so both stay logged in, and lets a
repository pin which one it uses via a `.cc-profile` file (like `.nvmrc`).

Your settings, skills, plugins, agents, statusline, session history and memory are **shared**.
Only credentials are isolated.

## Install

**Homebrew**

```sh
brew tap stevearagonsite/tap
brew install claude-code-cc
```

Then add to your `~/.zshrc`:

```sh
source "$(brew --prefix)/share/claude-code-cc/cc.zsh"
```

**Manual**

```sh
git clone https://github.com/stevearagonsite/claude-code-cc.git
cd claude-code-cc && ./install.sh          # add --with-skill for the Claude Code skill
```

## Getting started

```sh
cc add work        # create a profile by cloning your current session
cc use work        # switch to it — then run /login with the other account
cc list            # see what's left on each account
```

`cc add` clones the current credential blob rather than starting empty, so the new profile keeps
your MCP server authorizations. `/login` afterwards replaces only the account.

## Commands

`cc` uses subcommands. **The first argument decides**: a known verb belongs to `cc`, anything
else is passed straight to `claude`, untouched.

| Command | What it does | Launches Claude? |
|---|---|---|
| `cc [args…]` | Runs Claude with the effective profile | yes |
| `cc use <n> [args…]` | Switch to profile `<n>` and launch (`default` = the original slot) | yes |
| `cc switch [<n>]` | Switch profile, keeping the current conversation | yes |
| `cc list` | List profiles with remaining limits | no |
| `cc add <n>` | Create profile `<n>` by cloning the active session | no |
| `cc set [<n>]` | Pin this directory via `./.cc-profile` (no argument removes it) | no |
| `cc help` | Help, plus the active and per-directory profile | no |

Because everything else is delegated, `claude`'s own flags keep working — including the ones
that would otherwise collide:

```sh
cc -p "explain this file"      # claude's --print, not a profile
cc --resume <session-id>       # passed through
cc use work --resume <id>      # profile AND resume
cc -- list                     # escape hatch: send "list" to claude
```

Profiles aren't hardcoded — they're the subdirectories of `~/.claude-profiles`, so `cc add`
accepts any name.

## Which profile wins

Four layers. The first one that applies wins:

| # | Layer | Scope | Persists? |
|---|---|---|---|
| 1 | `cc use <n>` / `cc switch <n>` | Sets the global profile, then launches | **Yes** — writes `~/.claude-profiles/active` |
| 2 | `./.cc-profile` (nearest, walking up to `$HOME`) | That invocation of `cc` only | No |
| 3 | `CLAUDE_SECURESTORAGE_CONFIG_DIR` in the environment | That shell and its children | Per shell |
| 4 | Nothing set → the `default` Keychain item | — | — |

In practice:

```sh
cc use personal        # 1 beats everything, and is remembered from now on
cc                     # 2 if the directory has a .cc-profile, else 3, else 4
cc -p "hi"             # same resolution — delegation doesn't skip it
```

Two consequences worth knowing:

- **Layer 1 is global.** `~/.claude-profiles/active` is re-exported by every new shell, so
  plain `claude` and Claude Code sessions launched from other tools follow it too — not just
  `cc`. A terminal that is already open keeps whatever it started with.
- **Layer 2 never persists.** Running `cc` inside a directory with a `.cc-profile` does not
  change the active profile: leaving the directory is enough to go back. If the file names a
  profile that doesn't exist, `cc` exits 2 without launching Claude rather than silently
  falling through to layer 3.

`cc list` shows both: `*` marks the globally active profile, and a footer line reports what the
current directory resolves to.

## `.cc-profile`

One line naming the profile, like `.nvmrc`:

```
work
```

Looked up from the current directory upward, stopping at `$HOME`. The nearest one wins, so a
subdirectory can override the repository. Blank lines, surrounding whitespace and `#` comments
are ignored.

When it applies, `cc` says so before launching:

```
cc: profile 'work' (.cc-profile in ~/src/some-repo)
```

If it names a profile that doesn't exist, **`cc` exits 2 without launching Claude** — better
than silently burning the wrong account's quota.

Write it with `cc set work`; remove it with `cc set`.

## Switching mid-conversation

A running process never re-reads its credentials, so switching accounts means relaunching. The
conversation survives, because history lives in `~/.claude`, which is shared across profiles.

From inside a Claude Code session, run `!cc switch personal`. It records the request and prints
what to do next:

```
cc: to switch to 'personal', exit this session (Ctrl+D) and run:

    cc switch

  or, from any terminal:
    cc use personal --resume aadee50a-3864-4a5d-8f7c-905d7187e28f
```

Exit, run `cc switch`, and you're back in the same conversation on the other account. The
pending request is consumed once and ignored after an hour.

If you didn't record anything first, `cc switch <profile>` falls back to `--continue`, which
resumes the most recent conversation in the current directory.

## How it works

Claude Code derives the name of its Keychain item from the credentials directory:

```js
// from the Claude Code binary
`Claude Code${OAUTH_FILE_SUFFIX}-credentials${configDir ? "-" + sha256(configDir).slice(0, 8) : ""}`
```

So pointing `CLAUDE_SECURESTORAGE_CONFIG_DIR` at a per-profile directory gives each account its
own Keychain item, while `CLAUDE_CONFIG_DIR` stays at `~/.claude` and everything else remains
shared. You can reproduce a profile's item name with:

```sh
printf 'Claude Code-credentials-%s' \
  "$(printf '%s' "$HOME/.claude-profiles/work" | shasum -a 256 | cut -c1-8)"
```

`cc list` reads each profile's access token and queries `GET https://api.anthropic.com/api/oauth/usage`
— the same endpoint `/usage` uses internally.

This does not bypass anything: each profile consumes its own account's quota.

## Configuration

Set before sourcing `cc.zsh`:

| Variable | Default | Purpose |
|---|---|---|
| `CC_CMD` | `cc` | Name of the command to define |
| `CLAUDE_PROFILES_DIR` | `~/.claude-profiles` | Where profile directories live |
| `CC_PROFILE_FILE` | `.cc-profile` | Per-directory profile file |
| `CC_CLAUDE_ARGS` | `(--dangerously-skip-permissions)` | Args always passed to `claude` |

## Caveats

**`CLAUDE_SECURESTORAGE_CONFIG_DIR` is undocumented.** It was found by reading the Claude Code
binary; Anthropic can change it in any release. If a profile suddenly asks you to log in after
an update, that's the likely cause. To re-check the naming scheme:

```sh
grep -a -o -E '.{200}-credentials.{200}' ~/.local/share/claude/versions/<version> \
  | grep CLAUDE_SECURESTORAGE_CONFIG_DIR
```

**macOS only.** Credentials are read and written with `security` (Keychain). On Linux, Claude
Code falls back to `<dir>/.credentials.json` and the same variable applies, so a port means
replacing `_cc_profile_add` in `cc.zsh` and `read_blob` in `bin/cc-profiles` — not implemented
or tested here. PRs welcome.

**`cc` shadows `/usr/bin/cc`,** the C compiler. Harmless unless you invoke it directly; if you
do, install with a different name: `CC_CMD=ccx source .../cc.zsh`.

**`/status` may show the wrong email.** The account shown comes from `oauthAccount` in
`~/.claude.json`, which is shared across profiles, so it reflects whichever profile logged in
or refreshed a token last. API calls still use the correct account. `cc list` and `/usage` are
the reliable sources.

**MCP OAuth tokens are per profile.** They live in the same Keychain blob as the account, which
is why `cc add` clones instead of starting empty. Note that claude.ai-hosted MCP connectors are
tied to the account that authorized them and may return 401 under a different profile.

**Percentages are utilization, not tokens.** The API exposes percentage per window; the
`limit_dollars` fields are null on subscription plans. `cc list` shows what's *available*
(`100 - utilization`) while `/usage` shows what's *used* — they add up to 100. And `5h` is the
rolling session window, not a calendar day.

## Removing a profile

```sh
svc="Claude Code-credentials-$(printf '%s' "$HOME/.claude-profiles/work" | shasum -a 256 | cut -c1-8)"
security delete-generic-password -a "$USER" -s "$svc"
rm -rf ~/.claude-profiles/work
```

## License

MIT
