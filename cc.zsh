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
    print -u2 "    create it with: $CC_CMD -a $name"
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
    print "next:  $CC_CMD -p $name   then run  /login  with the other account"
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
    print -u2 "    create it with: $CC_CMD -a $name"
    return 2
  fi
  print "$name" > "$CC_PROFILE_FILE" \
    && print "$PWD/$CC_PROFILE_FILE -> $name"
}

_cc_help() {
  print "usage: $CC_CMD [options] [claude args...]"
  print
  print "  -p, --profile <n>  use profile <n> and launch Claude (becomes the active one)"
  print "  -s, --set <n>      pin this directory to profile <n> in ./$CC_PROFILE_FILE"
  print "  -s, --set          remove ./$CC_PROFILE_FILE"
  print "  -a, --add <n>      create profile <n> by cloning the active session"
  print "  -l, --list         list profiles with their remaining limits"
  print "  -h, --help         this help"
  print
  print "profiles: $(_cc_profile_names | tr '\n' ' ')default"
  print "active:   $(cat "$CLAUDE_PROFILES_DIR/active" 2>/dev/null || print default)"
  local f
  f="$(_cc_profile_find_file)" \
    && print "here:     $(_cc_profile_read_file "$f")  (${f/#$HOME/~})"
}

_cc_main() {
  local explicit=0
  while (( $# )); do
    case "$1" in
      -p|--profile) _cc_profile_activate "$2" || return $?; explicit=1; shift 2 ;;
      -s|--set)     _cc_profile_set "$2"; return $? ;;
      -a|--add)     _cc_profile_add "$2"; return $? ;;
      -l|--list)    cc-profiles; return $? ;;
      -h|--help)    _cc_help; return 0 ;;
      *) break ;;
    esac
  done

  # Without an explicit -p, the directory's profile file wins — but only for
  # this invocation: it never touches the globally active profile.
  local file name
  if (( ! explicit )) && file="$(_cc_profile_find_file)"; then
    name="$(_cc_profile_read_file "$file")"
    if [[ -n "$name" ]]; then
      if [[ "$name" != default && ! -d "$(_cc_profile_dir "$name")" ]]; then
        print -u2 "$CC_CMD: ${file/#$HOME/~} points at '$name', which does not exist"
        print -u2 "    profiles: $(_cc_profile_names | tr '\n' ' ')default"
        print -u2 "    create it with: $CC_CMD -a $name"
        return 2
      fi
      print "$CC_CMD: profile '$name' ($CC_PROFILE_FILE in ${${file:h}/#$HOME/~})"
      if [[ "$name" == default ]]; then
        # Subshell: the unset stays here, and the child does not inherit it.
        ( unset CLAUDE_SECURESTORAGE_CONFIG_DIR
          command claude $CC_CLAUDE_ARGS "$@" )
      else
        CLAUDE_SECURESTORAGE_CONFIG_DIR="$(_cc_profile_dir "$name")" \
          command claude $CC_CLAUDE_ARGS "$@"
      fi
      return $?
    fi
  fi

  command claude $CC_CLAUDE_ARGS "$@"
}

eval "${CC_CMD}() { _cc_main \"\$@\" }"
