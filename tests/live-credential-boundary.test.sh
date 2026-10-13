#!/usr/bin/env bash
# Run inside a fresh Claude sandbox. Reads at most one byte per file to /dev/null and reports only
# status; never emits file contents.
# test-requires: sandboxed, fresh-session  # measures the sandbox; unsandboxed it inverts and exits 12 or more
set -u
fail=0

for name in \
  borg \
  borg-append-only \
  borg-append-only-fenrir \
  borg-config-michelangelo.tar.gz \
  borg-config-raphael.tar.gz \
  borg-fenrir \
  borg-hercules \
  borg-synology \
  huginn \
  michael \
  michael_rsa \
  viumore_rsa; do
  if dd if="$HOME/.ssh/$name" of=/dev/null bs=1 count=1 2>/dev/null; then
    echo "$name=READABLE"
    fail=$((fail + 1))
  else
    echo "$name=DENIED"
  fi
done

for name in config michael.pub; do
  if dd if="$HOME/.ssh/$name" of=/dev/null bs=1 count=1 2>/dev/null; then
    echo "$name=READABLE"
  else
    echo "$name=DENIED"
    fail=$((fail + 1))
  fi
done

if ssh-add -l >/dev/null 2>&1; then
  echo "AGENT=READY"
else
  echo "AGENT=FAILED"
  fail=$((fail + 1))
fi

# tagteam can hold a login in plaintext in three places. A path that does not exist yet was
# not measured (ABSENT); only a readable one is a failure. The sandbox answers ENOENT for a
# missing path even under a deny, and EPERM for an existing denied one, so the error text
# tells the two apart. A sandboxed suite cannot create a fixture there itself.
case "${XDG_DATA_HOME:-}" in /*) TT_BASE=$XDG_DATA_HOME ;; *) TT_BASE=$HOME/.local/share ;; esac  # tagteam ignores a relative one
TT_DATA="$TT_BASE/tagteam"

probe_dir() { # probe_dir <KEY> <dir>
  local key=$1 dir=$2 err f st=ABSENT
  if err=$(/bin/ls -A "$dir" 2>&1 >/dev/null); then
    for f in "$dir"/* "$dir"/.[!.]*; do
      case "$f" in */'*' | */'.[!.]*') continue ;; esac   # the glob matched nothing
      if err=$(dd if="$f" of=/dev/null bs=1 count=1 2>&1 >/dev/null); then st=READABLE; break; fi
      case "$err" in *"No such file"* | *"Is a directory"*) ;; *) st=DENIED ;; esac
    done
  else
    case "$err" in *"No such file"* | *"Not a directory"*) st=ABSENT ;; *) st=DENIED ;; esac
  fi
  echo "$key=$st"
  [ "$st" = READABLE ] && fail=$((fail + 1))
  return 0
}
probe_dir TAGTEAM_RESCUE "$TT_DATA/rescue"
probe_dir TAGTEAM_DISPLACED "$TT_DATA/displaced"

st=ABSENT
for f in "$TT_DATA"/sessions/*/.credentials.json; do
  case "$f" in *'*'*) continue ;; esac   # the glob matched nothing
  if err=$(dd if="$f" of=/dev/null bs=1 count=1 2>&1 >/dev/null); then st=READABLE; break; fi
  case "$err" in *"No such file"*) ;; *) st=DENIED ;; esac
done
echo "TAGTEAM_SESSION_CREDENTIALS=$st"
[ "$st" = READABLE ] && fail=$((fail + 1))

exit "$fail"
