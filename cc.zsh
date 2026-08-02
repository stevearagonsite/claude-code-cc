# claude-code-cc — switch between authenticated Claude Code accounts.
#
# Source this from your ~/.zshrc:
#     source /path/to/claude-code-cc/cc.zsh
#
# Isolates ONLY the credentials: each profile gets its own Keychain item.
# Everything else in ~/.claude (settings, skills, plugins, history) stays shared.
#
# Configuration (set before sourcing):
#   CC_CMD                name of the command to define        (default: cc)
#   CLAUDE_PROFILES_DIR   where profile directories live       (default: ~/.claude-profiles)
#   CC_PROFILE_FILE       per-directory profile file           (default: .cc-profile)
#   CC_CLAUDE_ARGS        array of args always passed to claude
#                                        (default: --dangerously-skip-permissions)

: ${CC_CMD:=cc}
: ${CLAUDE_PROFILES_DIR:=$HOME/.claude-profiles}
: ${CC_PROFILE_FILE:=.cc-profile}
(( ${+CC_CLAUDE_ARGS} )) || CC_CLAUDE_ARGS=(--dangerously-skip-permissions)

_cc_profile_dir() { printf '%s/%s' "$CLAUDE_PROFILES_DIR" "$1"; }

# The profile list comes from the filesystem, not a hardcoded array.
_cc_profile_names() {
  local d
  for d in "$CLAUDE_PROFILES_DIR"/*(N/); do print -r -- "${d:t}"; done
}

# Same name Claude Code derives: sha256 of the directory, truncated to 8 chars.
_cc_profile_service() {
  printf 'Claude Code-credentials-%s' \
    "$(printf '%s' "$1" | shasum -a 256 | cut -c1-8)"
}

# Set the profile: variable in the current shell + persisted for future ones.
_cc_profile_activate() {
  local name="$1" dir
  if [[ -z "$name" ]]; then
    print -u2 "$CC_CMD: missing profile name"; return 2
  fi
  if [[ "$name" == default ]]; then
    unset CLAUDE_SECURESTORAGE_CONFIG_DIR
    mkdir -p "$CLAUDE_PROFILES_DIR" && print default > "$CLAUDE_PROFILES_DIR/active"
    return 0
  fi
  dir="$(_cc_profile_dir "$name")"
  if [[ ! -d "$dir" ]]; then
    print -u2 "$CC_CMD: unknown profile '$name' ($(_cc_profile_names | tr '\n' ' ')default)"
    print -u2 "    create it with: $CC_CMD add $name"
    return 2
  fi
  export CLAUDE_SECURESTORAGE_CONFIG_DIR="$dir"
  print "$name" > "$CLAUDE_PROFILES_DIR/active"
}

# On shell startup: adopt the active profile.
_cc_profile_restore() {
  local name dir
  [[ -r "$CLAUDE_PROFILES_DIR/active" ]] || return 0
  name="$(<"$CLAUDE_PROFILES_DIR/active")"
  [[ -n "$name" && "$name" != default ]] || return 0
  dir="$(_cc_profile_dir "$name")"
  [[ -d "$dir" ]] && export CLAUDE_SECURESTORAGE_CONFIG_DIR="$dir"
}
_cc_profile_restore

# Create a profile by cloning the active profile's blob (account + MCP tokens).
_cc_profile_add() {
  local name="$1" dir svc src blob
  if [[ ! "$name" =~ '^[A-Za-z0-9._-]+$' ]]; then
    print -u2 "$CC_CMD: invalid name '$name' (letters, digits, . _ - only)"; return 2
  fi
  dir="$(_cc_profile_dir "$name")"
  [[ -d "$dir" ]] && { print -u2 "$CC_CMD: profile '$name' already exists"; return 1; }

  # Source blob: the active profile if there is one, otherwise the default item.
  if [[ -n "$CLAUDE_SECURESTORAGE_CONFIG_DIR" ]]; then
    src="$(_cc_profile_service "$CLAUDE_SECURESTORAGE_CONFIG_DIR")"
  else
    src='Claude Code-credentials'
  fi
  blob="$(security find-generic-password -a "$USER" -w -s "$src" 2>/dev/null)" \
    || { print -u2 "$CC_CMD: no session in the active profile to clone from"; return 1; }

  mkdir -p "$dir" && chmod 700 "$dir"
  svc="$(_cc_profile_service "$dir")"
  if security add-generic-password -U -a "$USER" -s "$svc" \
       -X "$(printf '%s' "$blob" | xxd -p | tr -d '\n')"; then
    print "profile '$name' created (clone of the current session, with its MCP tokens)"
    print "next:  $CC_CMD use $name   then run  /login  with the other account"
  else
    rmdir "$dir" 2>/dev/null
    return 1
  fi
}

# --- per-directory profile (.cc-profile, .nvmrc style) ----------------------

# Find the nearest profile file, walking up from the cwd (stops at $HOME or /).
_cc_profile_find_file() {
  local dir="$PWD"
  while [[ -n "$dir" && "$dir" != "/" ]]; do
    [[ -f "$dir/$CC_PROFILE_FILE" ]] && { print -r -- "$dir/$CC_PROFILE_FILE"; return 0; }
    [[ "$dir" == "$HOME" ]] && break
    dir="${dir:h}"
  done
  return 1
}

# First meaningful line: comments and whitespace stripped.
_cc_profile_read_file() {
  local line
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%\#*}"; line="${line//[[:space:]]/}"
    [[ -n "$line" ]] && { print -r -- "$line"; return 0; }
  done < "$1"
  return 1
}

# Write (or remove) ./$CC_PROFILE_FILE.
_cc_profile_set() {
  local name="$1"
  if [[ -z "$name" ]]; then
    if [[ -f "$CC_PROFILE_FILE" ]]; then
      rm -f "$CC_PROFILE_FILE" && print "removed $PWD/$CC_PROFILE_FILE"
    else
      print -u2 "$CC_CMD: no $CC_PROFILE_FILE in this directory"; return 1
    fi
    return 0
  fi
  if [[ "$name" != default && ! -d "$(_cc_profile_dir "$name")" ]]; then
    print -u2 "$CC_CMD: unknown profile '$name' ($(_cc_profile_names | tr '\n' ' ')default)"
    print -u2 "    create it with: $CC_CMD add $name"
    return 2
  fi
  print "$name" > "$CC_PROFILE_FILE" \
    && print "$PWD/$CC_PROFILE_FILE -> $name"
}

# --- switching profiles without losing the conversation ---------------------

# A running process never re-reads its credentials, so switching means
# relaunching with --resume. History lives in ~/.claude, which is shared.
_cc_profile_switch() {
  local name="$1" pending="$CLAUDE_PROFILES_DIR/pending-switch" sid

  # Inside a Claude Code session we cannot replace the running process. The
  # recording lives in cc-profiles (an executable) because this function does
  # not exist in Claude Code's `!` prompt or Bash tool — those run in a
  # non-interactive shell where `cc` would resolve to /usr/bin/cc, the C
  # compiler. Use `cc-profiles switch <profile>` from there.
  if [[ -n "$CLAUDECODE" ]]; then
    cc-profiles switch "$name"
    return $?
  fi

  # Outside a session: consume the pending request, if any.
  if [[ -r "$pending" ]]; then
    if [[ -n "$(find "$pending" -mmin +60 2>/dev/null)" ]]; then
      rm -f "$pending"                     # stale, don't revive an old switch
    else
      local pname psid
      read -r pname psid < "$pending"
      [[ -n "$name" ]] || name="$pname"
      sid="$psid"
      rm -f "$pending"
    fi
  fi

  if [[ -z "$name" ]]; then
    print -u2 "$CC_CMD: nothing pending. Run '$CC_CMD switch <profile>' inside a session,"
    print -u2 "    or '$CC_CMD use <profile> --continue' to switch and pick up the last chat."
    return 2
  fi
  _cc_profile_activate "$name" || return $?

  # With no session id, --continue resumes the most recent chat in this
  # directory, which is the one just left.
  if [[ -n "$sid" ]]; then
    _cc_launch "" --resume "$sid"
  else
    _cc_launch "" --continue
  fi
}

_cc_help() {
  print "usage: $CC_CMD [claude args...]"
  print
  print "  $CC_CMD use <n> [args...]   switch to profile <n> and launch Claude"
  print "  $CC_CMD switch [<n>]        switch profile, keeping the conversation"
  print "  $CC_CMD list                list profiles with their remaining limits"
  print "  $CC_CMD add <n>             create profile <n> by cloning the active session"
  print "  $CC_CMD set [<n>]           pin this directory in ./$CC_PROFILE_FILE (no arg: remove)"
  print "  $CC_CMD help                this help"
  print
  print "Anything else is passed straight to claude, so '$CC_CMD -p \"…\"' and"
  print "'$CC_CMD --resume <id>' work as usual. Use '$CC_CMD -- <args>' to force it."
  print
  print "profiles: $(_cc_profile_names | tr '\n' ' ')default"
  print "active:   $(cat "$CLAUDE_PROFILES_DIR/active" 2>/dev/null || print default)"
  local f
  f="$(_cc_profile_find_file)" \
    && print "here:     $(_cc_profile_read_file "$f")  (${f/#$HOME/~})"
}

# One run of claude, optionally overriding the profile for this invocation only.
_cc_exec() {
  local name="$1"; shift
  if [[ -z "$name" ]]; then
    command claude $CC_CLAUDE_ARGS "$@"
  elif [[ "$name" == default ]]; then
    # Subshell: the unset stays here, and the child does not inherit it.
    ( unset CLAUDE_SECURESTORAGE_CONFIG_DIR
      command claude $CC_CLAUDE_ARGS "$@" )
  else
    CLAUDE_SECURESTORAGE_CONFIG_DIR="$(_cc_profile_dir "$name")" \
      command claude $CC_CLAUDE_ARGS "$@"
  fi
}

# Launch claude, and relaunch it if the session asked for a profile switch on
# the way out. This function is claude's parent, so when the child exits we are
# still alive and can start it again with --resume: same conversation, other
# account. A running process can't change its own credentials — the token is
# memoized in memory and only re-read on refresh or a 401 — so relaunching is
# the only reliable way.
_cc_launch() {
  local name="$1"; shift
  local -a args=("$@")
  local pending="$CLAUDE_PROFILES_DIR/pending-switch"
  local rc pname psid

  while true; do
    _cc_exec "$name" "${args[@]}"
    rc=$?

    [[ -r "$pending" ]] || return $rc
    if [[ -n "$(find "$pending" -mmin +60 2>/dev/null)" ]]; then
      rm -f "$pending"; return $rc            # stale, don't revive an old switch
    fi

    pname=""; psid=""
    read -r pname psid < "$pending"
    rm -f "$pending"                          # consume BEFORE relaunching
    [[ -n "$pname" && -n "$psid" ]] || return $rc

    _cc_profile_activate "$pname" || return $?   # bad profile: stop, don't loop
    name="$pname"; args=(--resume "$psid")
    print "$CC_CMD: switching to '$name'…"
  done
}

# Default path: the directory's profile file wins, but only for this
# invocation — it never touches the globally active profile.
_cc_launch_effective() {
  local file name
  if file="$(_cc_profile_find_file)"; then
    name="$(_cc_profile_read_file "$file")"
    if [[ -n "$name" ]]; then
      if [[ "$name" != default && ! -d "$(_cc_profile_dir "$name")" ]]; then
        print -u2 "$CC_CMD: ${file/#$HOME/~} points at '$name', which does not exist"
        print -u2 "    profiles: $(_cc_profile_names | tr '\n' ' ')default"
        print -u2 "    create it with: $CC_CMD add $name"
        return 2
      fi
      print "$CC_CMD: profile '$name' ($CC_PROFILE_FILE in ${${file:h}/#$HOME/~})"
      _cc_launch "$name" "$@"
      return $?
    fi
  fi
  _cc_launch "" "$@"
}

# The first argument decides: a known verb is ours, anything else goes to
# claude untouched. That way a new claude flag can never collide with us.
_cc_main() {
  case "$1" in
    use)
      shift
      _cc_profile_activate "$1" || return $?
      shift
      _cc_launch "" "$@"
      ;;
    switch) shift; _cc_profile_switch "$1" ;;
    list)   cc-profiles ;;
    add)    _cc_profile_add "$2" ;;
    set)    _cc_profile_set "$2" ;;
    help)   _cc_help ;;
    --)     shift; command claude $CC_CLAUDE_ARGS "$@" ;;
    --profile|-l|--list|-a|--add|-s|--set)
      # Pre-0.2 flags. None of these exist in claude, so catching them is safe
      # and clearer than letting claude fail. `-p` is deliberately absent: it
      # is claude's --print, and freeing it is the point of this release.
      print -u2 "$CC_CMD: flags were replaced by subcommands in 0.2.0 — see '$CC_CMD help'"
      print -u2 "    '$1' is now: $CC_CMD use|list|add|set"
      return 2
      ;;
    *)      _cc_launch_effective "$@" ;;
  esac
}

# Define the command only where it is wanted. `cc` shadows /usr/bin/cc, the C
# compiler, so it must NOT exist in plain script shells — a build that runs
# `cc foo.c` under zsh has to reach the real compiler.
#
# Interactive shells: yes, that's the whole point.
# Claude Code's `!` prompt and Bash tool: yes — they are non-interactive but
#   set CLAUDECODE=1, and that's exactly where you want `cc switch` to work.
# Everything else (build scripts, CI, `zsh -c` from another program): no.
#
# For the second case to work, source this file from ~/.zshenv, which zsh reads
# for every shell. From ~/.zshrc it only reaches interactive ones.
if [[ -o interactive || -n "$CLAUDECODE" ]]; then
  eval "${CC_CMD}() { _cc_main \"\$@\" }"
fi
