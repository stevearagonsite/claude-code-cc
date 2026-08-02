# claude-code-cc

Switch between multiple authenticated Claude Code accounts from the terminal — without logging
in again every time, and without duplicating your `~/.claude` setup.

```
$ cc -l

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
cc -a work        # create a profile by cloning your current session
cc -p work        # switch to it — then run /login with the other account
cc -l             # see what's left on each account
```

`cc -a` clones the current credential blob rather than starting empty, so the new profile keeps
your MCP server authorizations. `/login` afterwards replaces only the account.

## Commands

| Command | What it does | Launches Claude? |
|---|---|---|
| `cc [args…]` | Runs Claude with the effective profile | yes |
| `cc -p\|--profile <n>` | Switch to profile `<n>` and launch (`default` = the original slot) | yes |
| `cc -s\|--set <n>` | Pin this directory to `<n>` via `./.cc-profile` | no |
| `cc -s\|--set` | Remove `./.cc-profile` | no |
| `cc -a\|--add <n>` | Create profile `<n>` by cloning the active session | no |
| `cc -l\|--list` | List profiles with remaining limits | no |
| `cc -h\|--help` | Help, plus the active and per-directory profile | no |

Any argument that isn't one of these is passed through to `claude`, so `cc -p work --continue`
works.

Profiles aren't hardcoded — they're the subdirectories of `~/.claude-profiles`, so `cc -a`
accepts any name.

## Which profile wins

Three layers, highest priority first:

1. **`cc -p <n>`** — explicit. Always wins, and **persists**: it's written to
   `~/.claude-profiles/active` and exported by every new shell, so plain `claude` picks it up
   too.
2. **`.cc-profile`** in the current directory or any parent — applies to that invocation only.
   It does not change the globally active profile.
3. **The active profile.**

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

Write it with `cc -s work`; remove it with `cc -s`.

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

`cc -l` reads each profile's access token and queries `GET https://api.anthropic.com/api/oauth/usage`
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
or refreshed a token last. API calls still use the correct account. `cc -l` and `/usage` are
the reliable sources.

**MCP OAuth tokens are per profile.** They live in the same Keychain blob as the account, which
is why `cc -a` clones instead of starting empty. Note that claude.ai-hosted MCP connectors are
tied to the account that authorized them and may return 401 under a different profile.

**Percentages are utilization, not tokens.** The API exposes percentage per window; the
`limit_dollars` fields are null on subscription plans. `cc -l` shows what's *available*
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
