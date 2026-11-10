#!/bin/bash
# Installs the Claude Code managed mods lock (claude-managed-settings.json, beside this
# script) as /Library/Application Support/ClaudeCode/managed-settings.json.
#   install-claude-managed-settings.sh [--replace]
# A correct target is left alone, an incorrect one is refused unless --replace is given,
# and an unsafe directory above it is never fixed. Writes use sudo.
# Tests: CLAUDE_MANAGED_SETTINGS_TEST_ROOT=<absolute directory> redirects the target to
# <root>/ClaudeCode/managed-settings.json, expects the invoking user as owner, stops the
# directory walk at <root> and uses no sudo; CLAUDE_MANAGED_SETTINGS_TEST_STAGE=truncate
# (test mode only) cuts the staged copy short before it is checked.
# Runs under macOS's bash 3.2, and calls every tool by absolute path so PATH cannot fake a check.
set -u

REPLACE=0
for arg in "$@"; do
  case "$arg" in
    --replace) REPLACE=1 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P) || exit 2
SOURCE="$SCRIPT_DIR/claude-managed-settings.json"

TEST_MODE=0
if [ "${CLAUDE_MANAGED_SETTINGS_TEST_ROOT+set}" = set ]; then
  TEST_MODE=1
  ROOT=$CLAUDE_MANAGED_SETTINGS_TEST_ROOT
  case "$ROOT" in /*) ;; *) echo "test root must be an absolute directory: $ROOT" >&2; exit 2 ;; esac
  while [ "$ROOT" != / ] && [ "${ROOT%/}" != "$ROOT" ]; do ROOT=${ROOT%/}; done
  [ -d "$ROOT" ] || { echo "test root is not a directory: $ROOT" >&2; exit 2; }
  DIR="$ROOT/ClaudeCode"
  EXPECT_UID=$(/usr/bin/id -u)
else
  if [ "${CLAUDE_MANAGED_SETTINGS_TEST_STAGE+set}" = set ]; then
    echo "test variable set outside test mode" >&2; exit 2
  fi
  ROOT=/
  DIR="/Library/Application Support/ClaudeCode"
  EXPECT_UID=0
fi
TARGET="$DIR/managed-settings.json"
if [ "$TEST_MODE" = 1 ] && [ "${CLAUDE_MANAGED_SETTINGS_TEST_STAGE+set}" = set ] \
   && [ "$CLAUDE_MANAGED_SETTINGS_TEST_STAGE" != truncate ]; then
  echo "unknown CLAUDE_MANAGED_SETTINGS_TEST_STAGE: $CLAUDE_MANAGED_SETTINGS_TEST_STAGE" >&2; exit 2
fi

# The only place sudo appears: every write goes through here.
priv() { if [ "$TEST_MODE" = 1 ]; then "$@"; else /usr/bin/sudo "$@"; fi; }

STAGED=""
cleanup() { [ -n "$STAGED" ] && priv /bin/rm -f "$STAGED"; }
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

valid_policy() {
  /usr/bin/jq -e -s 'length == 1 and (.[0] | type == "object") and (.[0].pluginConfigs["cc-plugin-sec-default@builtin"].options.allowManagedModsOnly == true)' "$1" >/dev/null 2>&1
}

# True when `ls -lde` lists an ACL entry that allows anything. The first line is the file
# itself; entry lines look like " 0: group:everyone inherited allow write". An ls failure
# counts as allow: erring towards "allow" is the safe direction.
has_allow_acl() {
  local out line first=1
  out=$(/bin/ls -lde "$1" 2>/dev/null) || return 0
  while IFS= read -r line; do
    if [ "$first" = 1 ]; then first=0; continue; fi
    if [[ $line =~ ^[[:space:]]*[0-9]+: ]] && [[ " $line " == *" allow "* ]]; then return 0; fi
  done <<<"$out"
  return 1
}

# Sets DIR_REASON and returns 1 when $1 is not a safe directory.
check_dir() {
  local d=$1 st uid mode
  if [ -L "$d" ]; then DIR_REASON="symbolic link"; return 1; fi
  if [ ! -d "$d" ]; then DIR_REASON="not a directory"; return 1; fi
  st=$(/usr/bin/stat -f '%u %Lp' "$d") || { DIR_REASON="unreadable"; return 1; }
  uid=${st% *}; mode=${st#* }
  if [ "$uid" != "$EXPECT_UID" ]; then DIR_REASON="owner uid $uid, expected $EXPECT_UID"; return 1; fi
  if [ $(( 8#$mode & 8#022 )) -ne 0 ]; then DIR_REASON="writable by group or others"; return 1; fi
  if has_allow_acl "$d"; then DIR_REASON="allow ACL entry"; return 1; fi
  return 0
}

# Walks from the target's directory (its parent when it does not exist yet) up to the
# root. Sets BAD_DIR and DIR_REASON on the first unsafe one.
walk_dirs() {
  local d=$DIR
  if [ ! -e "$d" ] && [ ! -L "$d" ]; then d=${d%/*}; [ -n "$d" ] || d=/; fi
  while :; do
    if ! check_dir "$d"; then BAD_DIR=$d; return 1; fi
    if [ "$d" = "$ROOT" ] || [ "$d" = / ]; then return 0; fi
    d=${d%/*}; [ -n "$d" ] || d=/
  done
}

# Sets REASONS (one per line) and DIFFERS for the installed target. Returns 1 when it is
# not a regular file, which no flag overrides.
check_target() {
  local st uid mode
  REASONS=""; DIFFERS=0
  if [ -L "$TARGET" ] || [ ! -f "$TARGET" ]; then REASONS="not a regular file"; return 1; fi
  st=$(/usr/bin/stat -f '%u %Lp' "$TARGET") || { REASONS="unreadable"; return 0; }
  uid=${st% *}; mode=${st#* }
  add_reason() { REASONS="$REASONS${REASONS:+
}$1"; }
  [ "$uid" = "$EXPECT_UID" ] || add_reason "owner uid $uid, expected $EXPECT_UID"
  [ $(( 8#$mode & 8#022 )) -eq 0 ] || add_reason "writable by group or others"
  [ $(( 8#$mode & 8#444 )) -eq $(( 8#444 )) ] || add_reason "not readable by everyone"
  if has_allow_acl "$TARGET"; then add_reason "allow ACL entry"; fi
  if [ ! -r "$TARGET" ]; then
    add_reason "unreadable"
  elif ! /usr/bin/cmp -s "$TARGET" "$SOURCE"; then
    add_reason "content differs from $SOURCE"; DIFFERS=1
  fi
  return 0
}

# Sets STAGE_REASON and returns 1 when the staged copy is not exactly the source.
check_staged() {
  local st uid mode
  st=$(/usr/bin/stat -f '%u %Lp' "$1") || { STAGE_REASON="unreadable"; return 1; }
  uid=${st% *}; mode=${st#* }
  if [ "$uid" != "$EXPECT_UID" ]; then STAGE_REASON="owner uid $uid, expected $EXPECT_UID"; return 1; fi
  if [ "$mode" != 644 ]; then STAGE_REASON="mode $mode, expected 644"; return 1; fi
  if has_allow_acl "$1"; then STAGE_REASON="allow ACL entry"; return 1; fi
  if ! valid_policy "$1" || ! /usr/bin/cmp -s "$1" "$SOURCE"; then
    STAGE_REASON="content differs from $SOURCE"; return 1
  fi
  return 0
}

if ! valid_policy "$SOURCE"; then
  echo "invalid policy source: $SOURCE"; exit 1
fi

if ! walk_dirs; then
  echo "unsafe directory: $BAD_DIR: $DIR_REASON"; exit 1
fi

if [ -e "$TARGET" ] || [ -L "$TARGET" ]; then
  if ! check_target; then
    echo "refused: $TARGET: $REASONS"; exit 1
  fi
  if [ -z "$REASONS" ]; then
    echo "unchanged: $TARGET"; exit 0
  fi
  if [ "$REPLACE" = 0 ]; then
    while IFS= read -r reason; do echo "refused: $TARGET: $reason"; done <<<"$REASONS"
    if [ "$DIFFERS" = 1 ]; then /usr/bin/diff -u "$TARGET" "$SOURCE"; fi
    echo "re-run with --replace to install the repo's policy over it"
    exit 1
  fi
fi

if [ ! -d "$DIR" ]; then
  if ! priv /bin/mkdir -m 0755 "$DIR"; then
    echo "staged copy failed: cannot create $DIR; target left as it was"; exit 1
  fi
fi

if ! STAGED=$(priv /usr/bin/mktemp "$DIR/.managed-settings.json.XXXXXX"); then
  STAGED=""; echo "staged copy failed: cannot create a temporary file in $DIR; target left as it was"; exit 1
fi
if ! priv /bin/cp "$SOURCE" "$STAGED" || ! priv /bin/chmod 0644 "$STAGED"; then
  echo "staged copy failed: cannot write $STAGED; target left as it was"; exit 1
fi
if [ "$TEST_MODE" = 1 ] && [ "${CLAUDE_MANAGED_SETTINGS_TEST_STAGE:-}" = truncate ]; then
  IFS= read -r -n 10 chunk < "$SOURCE"
  printf '%s' "$chunk" > "$STAGED"
fi
if ! check_staged "$STAGED"; then
  echo "staged copy failed: $STAGE_REASON; target left as it was"; exit 1
fi
if ! priv /bin/mv -f "$STAGED" "$TARGET"; then
  echo "staged copy failed: cannot move it into place; target left as it was"; exit 1
fi
STAGED=""

if ! walk_dirs; then
  echo "verify failed: $TARGET: unsafe directory $BAD_DIR: $DIR_REASON"; exit 1
fi
check_target
if [ -n "$REASONS" ]; then
  while IFS= read -r reason; do echo "verify failed: $TARGET: $reason"; done <<<"$REASONS"
  exit 1
fi

echo "installed: $TARGET"
echo "Restart Claude Code sessions, then check /status (Enterprise managed settings (file)) and /plugin → Installed (cc-plugin-sec-default)."
