#!/usr/bin/env bash
# Run inside a fresh Claude sandbox. Reads at most one byte to /dev/null and reports only
# status; never emits file contents.
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

exit "$fail"
