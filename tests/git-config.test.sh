#!/usr/bin/env bash
# Verifies the global git config refuses fake git directories (safe.bareRepository =
# explicit) while real repositories, linked worktrees and bare remotes keep working.
# Every git call is isolated: the source config is the only global config, there is no
# system config, and commits never ask a signing agent. Work happens under $TMPDIR.
set -u
SRC="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="$SRC/dot_config/git/config"
APPLE_GIT=/Library/Developer/CommandLineTools/usr/bin/git
pass=0; fail=0

if [ ! -f "$CONFIG" ]; then
  echo "INCONCLUSIVE: $CONFIG is missing; nothing to test"
  exit 2
fi

T=$(mktemp -d "${TMPDIR:-/tmp}/gitconfig.XXXXXX") || exit 2
trap 'rm -rf "$T"' EXIT

export GIT_CONFIG_GLOBAL="$CONFIG" GIT_CONFIG_NOSYSTEM=1
CID=(-c commit.gpgsign=false -c user.name=t -c user.email=t@t)

ok()  { echo "  PASS: $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL: $1"; fail=$((fail + 1)); }
check_equal() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got '$1', want '$2')"; fi; }
check_ok()    { if "${@:2}" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }

mkfake() {
  mkdir -p "$1/objects" "$1/refs"
  echo 'ref: refs/heads/main' >"$1/HEAD"
  printf '[probe]\n\tkey = fake\n' >"$1/config"
}
mkfake "$T/fake"
mkfake "$T/fake2"
mkdir -p "$T/wtree"
printf '[core]\n\tbare = false\n\tworktree = %s\n[probe]\n\tkey = fake\n' "$T/wtree" >"$T/fake2/config"

check_equal "$(git config --file "$CONFIG" --get safe.bareRepository 2>/dev/null)" explicit \
  "safe.bareRepository is explicit"

err=$(git -C "$T/fake" rev-parse --git-dir 2>&1 >/dev/null); rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$err" | grep -q 'safe.bareRepository'; then
  ok "a fake git directory is refused"
else
  bad "a fake git directory is refused (rc=$rc)"
fi

check_equal "$(git -C "$T/fake" config probe.key 2>/dev/null)" "" \
  "a fake git directory's config is not read"

err=$(git -C "$T/fake2" status 2>&1 >/dev/null); rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$err" | grep -q 'safe.bareRepository'; then
  ok "a fake git directory with core.worktree is refused"
else
  bad "a fake git directory with core.worktree is refused (rc=$rc)"
fi

check_equal "$(git -C "$T/fake2" config probe.key 2>/dev/null)" "" \
  "a fake git directory with core.worktree has its config unread"

if [ -x "$APPLE_GIT" ]; then
  rc=0; "$APPLE_GIT" -C "$T/fake" rev-parse --git-dir >/dev/null 2>&1 || rc=$?
  val=$("$APPLE_GIT" -C "$T/fake" config probe.key 2>/dev/null)
  if [ "$rc" -ne 0 ] && [ -z "$val" ]; then ok "Apple git refuses it too"; else bad "Apple git refuses it too (rc=$rc)"; fi
else
  ok "Apple git refuses it too (no Command Line Tools git)"
fi

check_equal "$(git --git-dir="$T/fake" config probe.key 2>/dev/null)" fake \
  "--git-dir still opens it"

repo_ok=1
git -c init.templateDir= init -q "$T/r" >/dev/null 2>&1 || repo_ok=0
git -C "$T/r" "${CID[@]}" commit -q --allow-empty -m init >/dev/null 2>&1 || repo_ok=0
if [ "$repo_ok" -eq 1 ] && [ "$(git -C "$T/r/.git" rev-parse --git-dir 2>/dev/null)" = . ]; then
  ok "a repository works, inside its .git too"
else
  bad "a repository works, inside its .git too (init/commit ok=$repo_ok)"
fi

git -C "$T/r" worktree add -q "$T/wt" -b b1 >/dev/null 2>&1
check_ok "a linked worktree works" git -C "$T/wt" status --short

bare_ok=1
git -c init.templateDir= init -q --bare "$T/o.git" >/dev/null 2>&1 || bare_ok=0
git -C "$T/r" push -q "$T/o.git" HEAD:refs/heads/main >/dev/null 2>&1 || bare_ok=0
git -c init.templateDir= clone -q "$T/o.git" "$T/c" >/dev/null 2>&1 || bare_ok=0
git -C "$T/c" fetch -q >/dev/null 2>&1 || bare_ok=0
git ls-remote "$T/o.git" >/dev/null 2>&1 || bare_ok=0
if [ "$bare_ok" -eq 1 ]; then ok "a bare remote works"; else bad "a bare remote works"; fi

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
