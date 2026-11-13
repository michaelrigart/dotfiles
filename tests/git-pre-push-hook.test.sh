#!/usr/bin/env bash
# The global pre-push hook and the secret scan beside it (dot_config/git/hooks/, spec
# 2026-11-12-forge-push-protection-design.md, section 5). Every row is a dry-run push through a
# real git with core.hooksPath pointing at copies of the two source files: git runs pre-push for
# --dry-run (the tripwire below pins that), so a judged push never publishes anything.
#
# The rows of the secret scan moved here from tests/git-forge-guard.test.sh with their labels:
# `deny` became `block`, `allow` became `pass`, and the hook names refs by sha, so a needle that
# named a ref now names its sha.
#
#   ./tests/git-pre-push-hook.test.sh   (sandboxed is fine; needs gitleaks)
set -uo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$SRC/dot_config/git/hooks/executable_pre-push"
SCAN="$SRC/dot_config/git/hooks/executable_secret-scan"
for f in "$HOOK" "$SCAN"; do
  [ -f "$f" ] || { echo "missing subject under test: $f" >&2; exit 2; }
done

pass=0; fail=0
ok()  { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; }

# BSD mktemp -d without a template ignores $TMPDIR, so give it one explicitly.
TMP=$(mktemp -d "${TMPDIR:-/tmp}/prepush-hook.XXXXXX") || exit 2
trap 'rm -rf "$TMP"' EXIT

HOOKS="$TMP/hooks"; mkdir -p "$HOOKS"
cp "$HOOK" "$HOOKS/pre-push"; cp "$SCAN" "$HOOKS/secret-scan"
chmod 755 "$HOOKS/pre-push" "$HOOKS/secret-scan"

# git puts its own exec path first on a hook's PATH, so a `git` wrapper on the test's PATH never
# reaches the scan. HOOKS_WRAP is a hooks directory whose pre-push puts $HOOK_EXTRA_PATH first and
# then runs the real hook: a row that needs a wrapper git points core.hooksPath there.
HOOKS_WRAP="$TMP/hooks-wrap"; mkdir -p "$HOOKS_WRAP"
printf '#!/bin/sh\nPATH="${HOOK_EXTRA_PATH:-/nonexistent}:$PATH"; export PATH\nexec "%s/pre-push" "$@"\n' \
  "$HOOKS" > "$HOOKS_WRAP/pre-push"
chmod 755 "$HOOKS_WRAP/pre-push"

# The suite must not inherit Michael's configuration. This is the guard suite's file plus the
# hooks path; its format.pretty once made gitleaks report findings with no commit.
export GIT_CONFIG_GLOBAL="$TMP/gitconfig" GIT_CONFIG_NOSYSTEM=1
cat > "$GIT_CONFIG_GLOBAL" <<EOF
[user]
	name = t
	email = t@t
[commit]
	gpgsign = false
[init]
	defaultBranch = main
[alias]
	st = status
	pom = push origin main
	shp = !git push origin main
[format]
	pretty = format:%h %s
[core]
	hooksPath = $HOOKS
EOF
GITCONFIG_WRAP="$TMP/gitconfig-wrap"
sed "s|hooksPath = $HOOKS|hooksPath = $HOOKS_WRAP|" "$GIT_CONFIG_GLOBAL" > "$GITCONFIG_WRAP"
grep -q "hooksPath = $HOOKS_WRAP" "$GITCONFIG_WRAP" || { echo "wrap config setup failed" >&2; exit 2; }

REALPATH=$PATH
REALGIT=$(command -v git)

# expect_push <pass|block> <label> <repo> <args...>: a dry-run push of <repo>. pass is exit 0;
# block is a non-zero exit with the hook's reason on stderr (every reason starts "Push guard:",
# but UNSUPPORTED), so a push git itself rejects is no block. Its stderr stays in LAST_ERR for needle.
# GOPTS holds options for git itself (-c ...); PUSH_CWD is the directory the push is run from.
# PUSH_BOUND=<seconds> runs the push under bounded.py, which kills its whole process group at the
# limit: a row about a hook that could recurse must fail in seconds, never fork without end.
LAST_ERR=""; GOPTS=()
cat > "$TMP/bounded.py" <<'PY'
import os, signal, subprocess, sys
p = subprocess.Popen(sys.argv[2:], start_new_session=True)
try:
    sys.exit(p.wait(timeout=float(sys.argv[1])))
except subprocess.TimeoutExpired:
    os.killpg(p.pid, signal.SIGKILL)
    p.wait()
    sys.stderr.write("bounded: killed after %ss\n" % sys.argv[1])
    sys.exit(124)
PY
expect_push() {
  local want=$1 label=$2 repo=$3 rc got bound=(); shift 3
  [ -n "${PUSH_BOUND:-}" ] && bound=(/usr/bin/python3 -I "$TMP/bounded.py" "$PUSH_BOUND")
  LAST_ERR=$( cd "${PUSH_CWD:-$TMP}" && ${bound[@]+"${bound[@]}"} git ${GOPTS[@]+"${GOPTS[@]}"} -C "$repo" push --dry-run "$@" 2>&1 >/dev/null ); rc=$?
  if [ "$rc" -eq 0 ]; then got=pass
  elif [ "$rc" -eq 124 ] && printf '%s' "$LAST_ERR" | grep -q '^bounded: killed'; then got="killed at the bound (the hook did not return)"
  elif [ "$want" = refused ]; then got=refused         # any refusal: a hook of the repository's own
  elif printf '%s' "$LAST_ERR" | grep -qE 'Push guard:|^unsupported push configuration'; then got=block
  else got="exit $rc without a reason from the hook"; fi
  if [ "$got" = "$want" ]; then ok "$label"; else bad "$label (want $want, got $got: $LAST_ERR)"; fi
}
# needle <label> <text>: LAST_ERR holds the text
needle() {
  case "$LAST_ERR" in
    *"$2"*) ok "$1" ;;
    *) bad "$1 (reason lacks $2: $LAST_ERR)" ;;
  esac
}
# push_reason <repo> <args...>: the stderr of a dry-run push
push_reason() {
  local repo=$1; shift
  ( cd "$TMP" && git -C "$repo" push --dry-run "$@" 2>&1 >/dev/null )
}
# seed_push <repo> <remote> <ref> [push flags...]: setup, not a judged push. It skips the hook and
# fails the suite loudly when the remote ref is still missing, so no judged row runs unseeded.
seed_push() {
  local repo=$1 remote=$2 ref=$3 url dest; shift 3
  git -C "$repo" push -q --no-verify "$@" "$remote" "$ref" 2>/dev/null
  url=$(git -C "$repo" remote get-url "$remote")
  dest=${ref#*:}; dest=${dest#refs/heads/}
  git -C "$url" rev-parse --verify -q "refs/heads/$dest" >/dev/null 2>&1 \
    || { echo "setup failed: $ref is not on $url" >&2; exit 2; }
}

# ---------------------------------------------------------------- fixtures
# Two bare remotes and a work repo on a pushed feature branch; clone() copies it so a case can
# bend its configuration alone.
REMOTES="$TMP/remotes"; mkdir -p "$REMOTES"
git init -q --bare "$REMOTES/origin.git"
git init -q --bare "$REMOTES/backup.git"
BASE="$TMP/work"
git init -q "$BASE"
git -C "$BASE" commit -q --allow-empty -m init
git -C "$BASE" remote add origin "$REMOTES/origin.git"
seed_push "$BASE" origin main
git -C "$BASE" remote set-head origin main
git -C "$BASE" switch -q -c feat
git -C "$BASE" commit -q --allow-empty -m feature
seed_push "$BASE" origin feat -u
clone() { cp -R "$BASE" "$TMP/$1" && printf '%s' "$TMP/$1"; }

CLEAN=$(clone clean)
printf 'hello\n' > "$CLEAN/notes.txt"
git -C "$CLEAN" add notes.txt && git -C "$CLEAN" commit -q -m "a clean change"
# Feature branches of their own, each carrying one outgoing commit that adds no line: TRIM removes
# a line, RENTRIM renames a file and removes a line from it. gitleaks counts both, since each has
# a hunk.
TRIM=$(clone trim)
git -C "$TRIM" switch -q -c trim
printf 'one\ntwo\nthree\n' > "$TRIM/t.txt"; git -C "$TRIM" add t.txt; git -C "$TRIM" commit -q -m "add t"
seed_push "$TRIM" origin trim -u
printf 'one\nthree\n' > "$TRIM/t.txt"; git -C "$TRIM" commit -q -am "remove a line"
RENTRIM=$(clone rename-trim)
git -C "$RENTRIM" switch -q -c rentrim
printf 'one\ntwo\nthree\nfour\n' > "$RENTRIM/t.txt"; git -C "$RENTRIM" add t.txt; git -C "$RENTRIM" commit -q -m "add t"
seed_push "$RENTRIM" origin rentrim -u
git -C "$RENTRIM" mv t.txt u.txt; printf 'one\ntwo\nthree\n' > "$RENTRIM/u.txt"
git -C "$RENTRIM" commit -q -am "rename t, remove a line"
[ "$(git -C "$RENTRIM" diff --name-status -M HEAD~1 HEAD | cut -c1)" = R ] \
  && [ "$(git -C "$RENTRIM" rev-list --count HEAD --not --remotes=origin)" = 1 ] \
  && [ "$(git -C "$TRIM" rev-list --count HEAD --not --remotes=origin)" = 1 ] \
  || { echo "the removal-only fixtures are not what they claim" >&2; exit 2; }

if ! command -v gitleaks >/dev/null 2>&1; then
  bad "gitleaks is installed (brew install gitleaks); the scan cases cannot run"
else
  # The fixture secret is assembled at runtime from two halves, so no committed file holds a
  # scannable credential: this suite is itself pushed through the scan it tests.
  part_a=AKIA; part_b=QX7T2MZL4KRB6WNP
  SECRET_LINE="aws = \"$part_a$part_b\""
  NEEDLE_RULE="rule aws-access-token in creds.txt"
  LEAKY=$(clone leaky)
  printf '%s\n' "$SECRET_LINE" > "$LEAKY/creds.txt"
  git -C "$LEAKY" add creds.txt && git -C "$LEAKY" commit -q -m "add creds"

  echo "== the hook runs for every push, dry runs included =="
  # Without the hook a dry run exits 0, so a git that stops running pre-push for dry runs fails
  # here instead of turning every row below into a vacuous pass.
  expect_push block "the tripwire: a leaky dry run is blocked" "$LEAKY" origin feat
  needle "and the block names the rule" "$NEEDLE_RULE"
  expect_push pass "the same leaky dry run with --no-verify passes (the block is the hook's)" "$LEAKY" --no-verify origin feat
  RC1="$REMOTES/real-clean.git"; RL1="$REMOTES/real-leaky.git"
  git init -q --bare "$RC1"; git init -q --bare "$RL1"
  REALCLEAN=$(clone real-clean); git -C "$REALCLEAN" remote set-url origin "$RC1"
  if git -C "$REALCLEAN" push -q origin feat:topic 2>/dev/null \
     && git -C "$RC1" rev-parse --verify -q refs/heads/topic >/dev/null 2>&1; then
    ok "a real push of a clean branch to a fresh bare remote creates the ref"
  else bad "a real push of a clean branch to a fresh bare remote creates the ref"; fi
  REALLEAKY=$(clone real-leaky); git -C "$REALLEAKY" remote set-url origin "$RL1"
  printf '%s\n' "$SECRET_LINE" > "$REALLEAKY/creds.txt"
  git -C "$REALLEAKY" add creds.txt && git -C "$REALLEAKY" commit -q -m "add creds"
  if ! git -C "$REALLEAKY" push -q origin feat:topic 2>/dev/null \
     && ! git -C "$RL1" rev-parse --verify -q refs/heads/topic >/dev/null 2>&1; then
    ok "a real push of a leaky branch is blocked and the ref is absent"
  else bad "a real push of a leaky branch is blocked and the ref is absent"; fi

  echo "== rule 4: the secret scan =="
  expect_push pass "a clean feature branch is scanned and passes" "$CLEAN" origin feat
  expect_push block "a secret in the outgoing commits" "$LEAKY" origin feat
  needle "the deny names rule, file and commit" "$NEEDLE_RULE at commit"
  got=$LAST_ERR
  # The suite's gitconfig carries a format.pretty like Michael's, which once made gitleaks report
  # findings with no commit. The fingerprint must be commit-bound.
  if printf '%s\n' "$got" | grep -Eq '\(fingerprint [0-9a-f]{40}:creds\.txt:aws-access-token:1\)'; then
    ok "the fingerprint is bound to the commit, despite format.pretty"
  else bad "the fingerprint is bound to the commit, despite format.pretty ($got)"; fi
  # The directory the push is run from is not the repository that is scanned: the same push, two
  # repositories.
  PUSH_CWD=$CLEAN expect_push block "git -C <leaky repo> is scanned there" "$LEAKY" origin feat
  needle "and it is the leaky repository's rule that is named" "$NEEDLE_RULE"
  PUSH_CWD=$LEAKY expect_push pass "git -C <clean repo> is scanned there" "$CLEAN" origin feat
  case "$got" in
    *"$part_b"*) bad "the deny never shows the secret" ;;
    *)           ok "the deny never shows the secret" ;;
  esac
  INLINE=$(clone inline)
  printf '%s # gitleaks:allow\n' "$SECRET_LINE" > "$INLINE/creds.txt"
  git -C "$INLINE" add creds.txt && git -C "$INLINE" commit -q -m "add creds inline-allowed"
  expect_push block "an inline gitleaks:allow is not an exception" "$INLINE" origin feat
  needle "and the secret is found, not merely refused" "$NEEDLE_RULE"
  # The reviewed way through: the finding's fingerprint in the tracked .gitleaksignore.
  fp=$(printf '%s\n' "$got" | sed -n 's/.*(fingerprint \([^)]*\)).*/\1/p' | head -1)
  printf '%s\n' "$fp" > "$LEAKY/.gitleaksignore"
  git -C "$LEAKY" add .gitleaksignore && git -C "$LEAKY" commit -q -m "ignore a false positive"
  expect_push pass "a fingerprint in .gitleaksignore lets it through" "$LEAKY" origin feat
  # Only the DESTINATION remote's history is excluded. A commit already published on another
  # remote is still scanned before it reaches this one.
  TWO=$(clone two-remotes)
  git -C "$TWO" remote add backup "$REMOTES/backup.git"
  git -C "$TWO" switch -q -c elsewhere
  printf '%s\n' "$SECRET_LINE" > "$TWO/creds.txt"
  git -C "$TWO" add creds.txt && git -C "$TWO" commit -q -m "add creds"
  seed_push "$TWO" backup elsewhere
  expect_push block "a secret reachable only from another remote is still scanned" "$TWO" origin elsewhere
  needle "and it is found, not merely refused" "$NEEDLE_RULE"
  # A new ref name: backup already holds elsewhere, so pushing that ref sends the hook no line at
  # all and would pass with or without the exclusion.
  expect_push pass "the destination remote's own history is excluded" "$TWO" backup elsewhere:copy

  # leaky_clone <name> -> a clone of a branch that adds the secret. fingerprint_of <repo> reads
  # the fingerprint the block reports (it is commit-bound, so it differs per clone).
  leaky_clone() {
    local d; d=$(clone "$1")
    printf '%s\n' "$SECRET_LINE" > "$d/creds.txt"
    git -C "$d" add creds.txt && git -C "$d" commit -q -m "add creds"
    printf '%s' "$d"
  }
  fingerprint_of() {
    push_reason "$1" origin feat | sed -n 's/.*(fingerprint \([^)]*\)).*/\1/p' | head -1
  }
  # The exception must be reviewed: gitleaks reads .gitleaksignore from the working tree, so
  # only a committed copy may decide what the scan skips.
  echo "== rule 4: a gitleaks exception must be committed =="
  UNTRACKED=$(leaky_clone untracked-ignore)
  fp=$(fingerprint_of "$UNTRACKED"); printf '%s\n' "$fp" > "$UNTRACKED/.gitleaksignore"
  expect_push block "an untracked .gitleaksignore is not an exception" "$UNTRACKED" origin feat
  needle "and the deny says to commit it first" "Commit the exception first"
  EXCLUDED=$(leaky_clone excluded-ignore)
  fp=$(fingerprint_of "$EXCLUDED"); printf '%s\n' "$fp" > "$EXCLUDED/.gitleaksignore"
  printf '.gitleaksignore\n' >> "$EXCLUDED/.git/info/exclude"
  expect_push block "a .gitleaksignore in .git/info/exclude is not an exception" "$EXCLUDED" origin feat
  needle "and it says to commit it first" "Commit the exception first"
  CHANGED=$(clone changed-ignore)
  printf '# reviewed\n' > "$CHANGED/.gitleaksignore"
  git -C "$CHANGED" add .gitleaksignore && git -C "$CHANGED" commit -q -m "add ignore file"
  printf '%s\n' "$SECRET_LINE" > "$CHANGED/creds.txt"
  git -C "$CHANGED" add creds.txt && git -C "$CHANGED" commit -q -m "add creds"
  fp=$(fingerprint_of "$CHANGED"); printf '%s\n' "$fp" >> "$CHANGED/.gitleaksignore"
  expect_push block "an uncommitted edit to a tracked .gitleaksignore" "$CHANGED" origin feat
  needle "and it says to commit it first" "Commit the exception first"
  expect_push pass "the committed fingerprint case still passes" "$LEAKY" origin feat

  echo "== rule 4: the scan must cover what it is asked to =="
  # color.diff=always once made gitleaks scan 0 commits and report no leaks. The scan pins the
  # configuration that breaks its parse, and refuses a run that covers fewer commits.
  COLORED=$(leaky_clone colored)
  git -C "$COLORED" config color.diff always
  expect_push block "a secret is still found under color.diff=always" "$COLORED" origin feat
  needle "and the deny names the rule" "rule aws-access-token"
  COLORCLEAN=$(clone colored-clean); git -C "$COLORCLEAN" config color.diff always
  printf 'hello\n' > "$COLORCLEAN/notes.txt"
  git -C "$COLORCLEAN" add notes.txt && git -C "$COLORCLEAN" commit -q -m "a clean change"
  expect_push pass "a clean push under color.diff=always" "$COLORCLEAN" origin feat
  # Commits that add no text are not counted by gitleaks, and must not fail the check.
  MIXED=$(clone mixed)
  git -C "$MIXED" commit -q --allow-empty -m "empty"
  printf 'x\n' > "$MIXED/a.txt"; git -C "$MIXED" add a.txt; git -C "$MIXED" commit -q -m "add a"
  chmod +x "$MIXED/a.txt"; git -C "$MIXED" commit -q -am "mode only"
  git -C "$MIXED" rm -q a.txt; git -C "$MIXED" commit -q -m "delete a"
  printf 'y\n' > "$MIXED/b.txt"; git -C "$MIXED" add b.txt; git -C "$MIXED" commit -q -m "add b"
  expect_push pass "empty, mode-only and deleting commits do not fail the count" "$MIXED" origin feat
  # A secret added only while committing a merge: git log -p shows no diff for a merge.
  MERGED=$(clone merged)
  git -C "$MERGED" switch -q -c side
  printf 'side\n' > "$MERGED/side.txt"; git -C "$MERGED" add side.txt; git -C "$MERGED" commit -q -m "side"
  git -C "$MERGED" switch -q feat
  printf 'main\n' > "$MERGED/other.txt"; git -C "$MERGED" add other.txt; git -C "$MERGED" commit -q -m "other"
  git -C "$MERGED" merge -q --no-ff -m "merge side" side
  expect_push pass "a clean merge is clean" "$MERGED" origin feat
  EVIL=$(clone evil-merge)
  git -C "$EVIL" switch -q -c side
  printf 'side\n' > "$EVIL/side.txt"; git -C "$EVIL" add side.txt; git -C "$EVIL" commit -q -m "side"
  git -C "$EVIL" switch -q feat
  printf 'main\n' > "$EVIL/other.txt"; git -C "$EVIL" add other.txt; git -C "$EVIL" commit -q -m "other"
  git -C "$EVIL" merge -q --no-ff --no-commit side >/dev/null 2>&1
  printf '%s\n' "$SECRET_LINE" > "$EVIL/creds.txt"; git -C "$EVIL" add creds.txt
  git -C "$EVIL" commit -q -m "merge side"
  expect_push block "a secret introduced while committing a merge" "$EVIL" origin feat
  needle "and it is found, not merely refused" "$NEEDLE_RULE"
  # Ways git can be made to show no added text while the secret is there. The scan pins them for
  # its own git log, and never skips gitleaks on an expected count of zero.
  echo "== rule 4: a secret git is told not to show =="
  NODIFF=$(clone nodiff)
  printf '* -diff\n' > "$NODIFF/.gitattributes"
  printf '%s\n' "$SECRET_LINE" > "$NODIFF/creds.txt"
  git -C "$NODIFF" add .gitattributes creds.txt && git -C "$NODIFF" commit -q -m "add creds, marked -diff"
  expect_push block "a secret under -diff in a committed .gitattributes" "$NODIFF" origin feat
  needle "and it is found, not merely refused" "$NEEDLE_RULE"
  INFOATTR=$(leaky_clone info-attributes)
  printf '* binary\n' >> "$INFOATTR/.git/info/attributes"
  expect_push block "a secret under binary in .git/info/attributes" "$INFOATTR" origin feat
  needle "and it is found, not merely refused" "$NEEDLE_RULE"
  BIGFILE=$(leaky_clone bigfile)
  git -C "$BIGFILE" config core.bigFileThreshold 1
  expect_push block "a secret under core.bigFileThreshold=1" "$BIGFILE" origin feat
  needle "and it is found, not merely refused" "$NEEDLE_RULE"
  ORPHAN=$(clone orphan)
  git -C "$ORPHAN" switch -q --orphan orphan
  printf '%s\n' "$SECRET_LINE" > "$ORPHAN/creds.txt"
  git -C "$ORPHAN" add creds.txt && git -C "$ORPHAN" commit -q -m "root with creds"
  git -C "$ORPHAN" config log.showRoot false
  expect_push block "a secret in a root commit under log.showRoot=false" "$ORPHAN" origin orphan
  needle "and it is found, not merely refused" "$NEEDLE_RULE"
  # diff.submodule=diff makes the patch of a bumped gitlink start a child `git diff` inside the
  # submodule, which has no --no-ext-diff of its own: the submodule's diff.external and textconv
  # driver would run, unsandboxed, on every push. The scan keeps the gitlink a one-line patch.
  SMK="$TMP/sm-marks"; SMS="$TMP/sm-src"; mkdir -p "$SMK"
  git init -q "$SMS"; printf 'one\n' > "$SMS/a.txt"; git -C "$SMS" add a.txt; git -C "$SMS" commit -q -m "first"
  SUBM=$(clone submodule)
  git -C "$SUBM" -c protocol.file.allow=always submodule add -q "$SMS" sm 2>/dev/null
  git -C "$SUBM" commit -q -m "add the submodule"
  printf 'changed\n' > "$SUBM/sm/a.txt"; git -C "$SUBM/sm" commit -q -am "move the submodule"
  git -C "$SUBM" add sm; git -C "$SUBM" commit -q -m "bump the gitlink"
  printf '#!/bin/sh\ntouch "%s/external"\nexit 0\n' "$SMK" > "$TMP/sm-external"; chmod +x "$TMP/sm-external"
  printf '#!/bin/sh\ntouch "%s/textconv"\ncat "$1"\n' "$SMK" > "$TMP/sm-textconv"; chmod +x "$TMP/sm-textconv"
  git -C "$SUBM/sm" config diff.external "$TMP/sm-external"
  git -C "$SUBM/sm" config diff.m.textconv "$TMP/sm-textconv"
  printf '*.txt diff=m\n' > "$(git -C "$SUBM/sm" rev-parse --path-format=absolute --git-path info/attributes)"
  git -C "$SUBM" config diff.submodule diff
  rm -f "$SMK"/*
  expect_push pass "a bumped gitlink under diff.submodule=diff is scanned and passes" "$SUBM" origin feat
  is_marks() {
    if [ -z "$(find "$SMK" -type f | tr '\n' ' ')" ]; then ok "$1"
    else bad "$1 (ran: $(find "$SMK" -type f | tr '\n' ' '))"; fi
  }
  is_marks "and neither the submodule's diff.external nor its textconv ran"
  git -C "$SUBM/sm" config --unset diff.external; rm -f "$SMK"/*   # the external driver outranks textconv
  expect_push pass "the same push with the textconv driver alone" "$SUBM" origin feat
  is_marks "nor the textconv driver alone"
  # None of that may cost an ordinary push its silence. gitleaks counts a commit when its patch
  # has a hunk in a file it does not skip (a deleted one), even a hunk that only removes lines,
  # and the expected count follows the same rule.
  expect_push pass "a commit that only removes a line" "$TRIM" origin trim
  expect_push pass "a rename that also removes a line" "$RENTRIM" origin rentrim
  FRESH="$TMP/fresh"; git init -q "$FRESH"
  git init -q --bare "$REMOTES/fresh.git"
  printf 'one\ntwo\n' > "$FRESH/a.txt"; git -C "$FRESH" add a.txt; git -C "$FRESH" commit -q -m "first"
  git -C "$FRESH" remote add origin "$REMOTES/fresh.git"; git -C "$FRESH" switch -q -c topic
  expect_push pass "a first push of a new repository" "$FRESH" origin topic
  EMPTIES=$(clone empties)
  git -C "$EMPTIES" commit -q --allow-empty -m "e1"; git -C "$EMPTIES" commit -q --allow-empty -m "e2"
  expect_push pass "empty commits only" "$EMPTIES" origin feat
  # DELREN and AMENDED publish feat, so each gets a remote of its own: a shared one would leave
  # every other clone behind it, and git would reject their pushes before the hook sees a line.
  git init -q --bare "$REMOTES/delren.git"; git init -q --bare "$REMOTES/amended.git"
  DELREN=$(clone delren); git -C "$DELREN" remote set-url origin "$REMOTES/delren.git"
  seq 1 20 > "$DELREN/a.txt"; seq 21 40 > "$DELREN/b.txt"
  git -C "$DELREN" add a.txt b.txt && git -C "$DELREN" commit -q -m "add a and b"
  seed_push "$DELREN" origin feat
  git -C "$DELREN" rm -q b.txt && git -C "$DELREN" commit -q -m "delete b"
  expect_push pass "deletions only" "$DELREN" origin feat
  git -C "$DELREN" mv a.txt c.txt && git -C "$DELREN" commit -q -m "rename a"
  expect_push pass "a deletion and a rename" "$DELREN" origin feat
  BINARY=$(clone binary)
  printf '\000\001\002\003\n' > "$BINARY/blob.bin"
  git -C "$BINARY" add blob.bin && git -C "$BINARY" commit -q -m "a binary file"
  expect_push pass "a binary-only commit" "$BINARY" origin feat
  # --text puts a binary file's bytes in the patch, and a GIF, PNG or font can hold CR before the
  # 0x01 commit marker or @@. Read in text mode, the listing broke there too and counted phantom
  # commits (598 expected, 573 scanned): git and gitleaks split at LF alone. The gif is added,
  # then deleted: a phantom marker inside a deleted file once counted as well.
  CRBIN=$(clone cr-binary)
  printf 'GIF89a\000\r\001x\r@@ -0,0 +1 @@\r\001y\000\n' > "$CRBIN/cam.gif"
  git -C "$CRBIN" add cam.gif && git -C "$CRBIN" commit -q -m "add a gif"
  git -C "$CRBIN" rm -q cam.gif && git -C "$CRBIN" commit -q -m "delete the gif"
  printf 'hello\n' > "$CRBIN/notes.txt"
  git -C "$CRBIN" add notes.txt && git -C "$CRBIN" commit -q -m "a clean change"
  expect_push pass "a binary holding CR before the commit marker and @@" "$CRBIN" origin feat
  # The count still fails closed when gitleaks really covers less. This git hides the commits
  # that only modify files from gitleaks' own log (a diff filter the scan's listing never gets),
  # so gitleaks scans 2 of the 3 commits with changes: block, with the exact counts. The wrapper
  # git reaches gitleaks through HOOKS_WRAP, since git puts its own exec path first on a hook's PATH.
  CRMOD="$TMP/cr-binary-modified"; cp -R "$CRBIN" "$CRMOD"
  printf 'more\n' >> "$CRMOD/notes.txt"; git -C "$CRMOD" commit -q -am "modify notes"
  HIDEBIN="$TMP/hidebin"; mkdir -p "$HIDEBIN"
  printf '#!/bin/sh\nPATH="%s"; export PATH\ncase " $* " in\n  *" --format=%%x01%%H "*) ;;\n  *" log -p -U0 "*) exec git "$@" --diff-filter=A ;;\nesac\nexec git "$@"\n' \
    "$REALPATH" > "$HIDEBIN/git"
  chmod 755 "$HIDEBIN/git"
  GIT_CONFIG_GLOBAL=$GITCONFIG_WRAP HOOK_EXTRA_PATH=$HIDEBIN \
    expect_push block "a gitleaks log that hides modifying commits is a deny" "$CRMOD" origin feat
  needle "and the deny gives both counts" "scanned 2 commit(s) but this push carries 3"
  expect_push pass "the same branch, its log not filtered" "$CRMOD" origin feat
  # A plain push of an amended branch is rejected non-fast-forward before the hook sees a line.
  AMENDED=$(clone amended); git -C "$AMENDED" remote set-url origin "$REMOTES/amended.git"
  printf 'one\n' > "$AMENDED/n.txt"; git -C "$AMENDED" add n.txt; git -C "$AMENDED" commit -q -m "add n"
  seed_push "$AMENDED" origin feat
  printf 'two\n' >> "$AMENDED/n.txt"; git -C "$AMENDED" commit -q -a --amend -m "add n, amended"
  expect_push pass "after an amend" "$AMENDED" --force-with-lease origin feat
  # The exception files are compared with HEAD byte for byte, so git's own ways of hiding a
  # change (status.showUntrackedFiles, skip-worktree) do not hide it from the scan.
  HIDDEN=$(leaky_clone hidden-untracked)
  fp=$(fingerprint_of "$HIDDEN"); printf '%s\n' "$fp" > "$HIDDEN/.gitleaksignore"
  git -C "$HIDDEN" config status.showUntrackedFiles no
  expect_push block "an untracked .gitleaksignore under status.showUntrackedFiles=no" "$HIDDEN" origin feat
  needle "and it is refused for being uncommitted" "Commit the exception first"
  SKIPWT=$(clone skip-worktree)
  printf '# reviewed\n' > "$SKIPWT/.gitleaksignore"
  git -C "$SKIPWT" add .gitleaksignore && git -C "$SKIPWT" commit -q -m "add ignore file"
  printf '%s\n' "$SECRET_LINE" > "$SKIPWT/creds.txt"
  git -C "$SKIPWT" add creds.txt && git -C "$SKIPWT" commit -q -m "add creds"
  fp=$(fingerprint_of "$SKIPWT"); printf '%s\n' "$fp" >> "$SKIPWT/.gitleaksignore"
  git -C "$SKIPWT" update-index --skip-worktree .gitleaksignore
  expect_push block "a skip-worktree edit to a committed .gitleaksignore" "$SKIPWT" origin feat
  needle "and it is refused for differing from HEAD" "Commit the exception first"
  # A replace ref hides an object from git log, but a push sends the real one.
  REPLBLOB=$(leaky_clone replace-blob)
  secret_blob=$(git -C "$REPLBLOB" rev-parse HEAD:creds.txt)
  clean_blob=$(printf 'hello\n' | git -C "$REPLBLOB" hash-object -w --stdin)
  git -C "$REPLBLOB" replace "$secret_blob" "$clean_blob"
  expect_push block "a secret hidden by a replaced blob" "$REPLBLOB" origin feat
  needle "and it is found, not merely refused" "$NEEDLE_RULE"
  REPLCOMMIT=$(leaky_clone replace-commit)
  git -C "$REPLCOMMIT" replace HEAD HEAD~1
  # With the replacement in place git itself reads feat as the remote's tip and rejects a push of
  # feat as non-fast-forward before any hook; a new branch sends the same commit past that check.
  expect_push block "a secret hidden by a replaced commit" "$REPLCOMMIT" origin feat:replaced
  needle "and it is found, not merely refused" "$NEEDLE_RULE"
  # An exception committed on the branch you stand on reviews nothing for another branch.
  OTHERBR=$(leaky_clone otherbranch)
  fp=$(fingerprint_of "$OTHERBR")
  git -C "$OTHERBR" switch -q -c scratch
  printf '%s\n' "$fp" > "$OTHERBR/.gitleaksignore"
  git -C "$OTHERBR" add .gitleaksignore && git -C "$OTHERBR" commit -q -m "ignore, on scratch only"
  expect_push block "an exception committed on HEAD, not on the pushed branch" "$OTHERBR" origin feat
  needle "and the deny says to commit it on the pushed ref" "on the ref being pushed"
  expect_push pass "the exception on the branch being pushed lets it through" "$OTHERBR" origin scratch
  # --tags pushes refs the hook names only by sha, so with an exception file in the worktree each
  # sha is compared with it: here the secret is tagged v1 on feat, and the exception is committed
  # on scratch only.
  TAGGED=$(leaky_clone tagged)
  fp=$(fingerprint_of "$TAGGED")
  git -C "$TAGGED" tag v1
  git -C "$TAGGED" switch -q -c scratch main
  printf '%s\n' "$fp" > "$TAGGED/.gitleaksignore"
  git -C "$TAGGED" add .gitleaksignore && git -C "$TAGGED" commit -q -m "ignore, on scratch only"
  expect_push block "--tags with an exception file in the worktree" "$TAGGED" origin --tags
  needle "and the deny says to commit the exception first" "Commit the exception first"
  expect_push block "the tag pushed by name, its exception missing" "$TAGGED" origin v1
  needle "and the deny fits a tag" "on the ref being pushed"
  # With no exception file anywhere, --tags is scanned as before: silent when clean.
  TAGCLEAN=$(clone tag-clean)
  printf 'hello\n' > "$TAGCLEAN/notes.txt"
  git -C "$TAGCLEAN" add notes.txt && git -C "$TAGCLEAN" commit -q -m "a clean change"
  git -C "$TAGCLEAN" tag v1
  expect_push pass "--tags with no exception file, clean" "$TAGCLEAN" origin --tags
  TAGLEAK=$(leaky_clone tag-leak)
  git -C "$TAGLEAK" tag v1
  expect_push block "--tags with no exception file, a secret" "$TAGLEAK" origin --tags
  needle "and it is found, not merely refused" "$NEEDLE_RULE"
  # A config named in the environment is as unreviewed as an untracked one.
  printf '[extend]\nuseDefault = true\n[allowlist]\npaths = [%s]\n' "'''.*'''" > "$TMP/allow-all.toml"
  GITLEAKS_CONFIG="$TMP/allow-all.toml" expect_push block "a GITLEAKS_CONFIG in the environment is ignored" "$EVIL" origin feat
  needle "and the deny names the file" "in creds.txt"

  # A gitleaks config decides which rules run and what they allow, and the scan supports none:
  # gitleaks reads .gitleaks.toml from the working tree, lets viper find any .gitleaks.<ext>
  # beside it, and a config can extend a file nobody reviewed. Any such file in the working tree
  # (tracked or not), or committed on a pushed ref, is a block naming it, before gitleaks runs.
  echo "== rule 4: a gitleaks config file is unsupported =="
  ALLOW_ALL=$(printf '[extend]\nuseDefault = true\n[allowlist]\npaths = [%s]\n' "'''.*'''")
  # On a clean branch, so the deny can only come from the file. Every extension and case. The
  # branch carries a clean commit: a push that sends nothing is never scanned.
  n=0
  for name in .gitleaks.toml .gitleaks.json .gitleaks.yaml .gitleaks.yml .GITLEAKS.TOML .Gitleaks.Json; do
    n=$((n + 1)); CFG=$(clone "config-$n")
    printf 'hello\n' > "$CFG/notes.txt"
    git -C "$CFG" add notes.txt && git -C "$CFG" commit -q -m "a clean change"
    printf '%s\n' "$ALLOW_ALL" > "$CFG/$name"
    expect_push block "an untracked $name, on a clean branch" "$CFG" origin feat
    needle "and the deny names $name as unsupported" \
      "unsupported push configuration for the push guard: the gitleaks config file $name in the working tree"
  done
  CFGLEAK=$(leaky_clone config-leak)
  printf '%s\n' "$ALLOW_ALL" > "$CFGLEAK/.gitleaks.toml"
  expect_push block "an untracked .gitleaks.toml that allows everything" "$CFGLEAK" origin feat
  needle "and the deny names the file" "the gitleaks config file .gitleaks.toml in the working tree"
  git -C "$CFGLEAK" add .gitleaks.toml
  expect_push block "a staged, uncommitted .gitleaks.toml" "$CFGLEAK" origin feat
  needle "and the deny names the file" "the gitleaks config file .gitleaks.toml in the working tree"
  git -C "$CFGLEAK" commit -q -m "a gitleaks config"
  expect_push block "a committed .gitleaks.toml" "$CFGLEAK" origin feat
  needle "and the deny names the file" "the gitleaks config file .gitleaks.toml in the working tree"
  # An [extend] path loads another file. The config is no longer read, only refused.
  EXT=$(leaky_clone config-extend)
  printf '[extend]\npath = "local-allow.toml"\n' > "$EXT/.gitleaks.toml"
  printf '%s\n' "$ALLOW_ALL" > "$EXT/local-allow.toml"
  git -C "$EXT" add .gitleaks.toml local-allow.toml && git -C "$EXT" commit -q -m "extend a config"
  expect_push block "a committed .gitleaks.toml that extends another config" "$EXT" origin feat
  needle "and the deny names the file" "the gitleaks config file .gitleaks.toml in the working tree"
  # Committed on the pushed ref, absent from the working tree: the push names another branch.
  TREEONLY=$(clone config-tree-only)
  git -C "$TREEONLY" switch -q -c withcfg
  printf '%s\n' "$ALLOW_ALL" > "$TREEONLY/.GitLeaks.Toml"
  printf 'hello\n' > "$TREEONLY/notes.txt"
  git -C "$TREEONLY" add .GitLeaks.Toml notes.txt && git -C "$TREEONLY" commit -q -m "a config and a change"
  CFGSHA=$(git -C "$TREEONLY" rev-parse withcfg)
  git -C "$TREEONLY" switch -q feat
  expect_push block "a config committed on the pushed ref, not in the working tree" "$TREEONLY" origin withcfg
  needle "and the deny names the file and the ref (the hook names it by sha)" \
    "the gitleaks config file .GitLeaks.Toml committed on $CFGSHA"
  git -C "$TREEONLY" tag cfgtag withcfg
  expect_push block "a config in a tagged tree, pushed with --tags" "$TREEONLY" origin --tags
  needle "and the deny names the file and the tagged commit" \
    "the gitleaks config file .GitLeaks.Toml committed on $CFGSHA"
  # Only what is pushed counts: a config on a branch that stays home is not in play.
  printf 'hello\n' > "$TREEONLY/notes.txt"
  git -C "$TREEONLY" add notes.txt && git -C "$TREEONLY" commit -q -m "a clean change on feat"
  expect_push pass "a config on a branch this push does not send" "$TREEONLY" origin feat

  echo "== the hook scans what a push to a branch, a tag or a URL sends =="
  seed_push "$BASE" origin main:refs/heads/old
  NEWB=$(leaky_clone new-branch)
  expect_push block "a new leaky branch is blocked" "$NEWB" origin feat:brand-new
  needle "and the block names the rule" "$NEEDLE_RULE"
  expect_push pass "a new clean branch passes" "$CLEAN" origin feat:brand-new
  RECORD="$TMP/recordgl"; mkdir -p "$RECORD"
  printf '#!/bin/sh\necho called >> "%s/calls"\nexit 0\n' "$RECORD" > "$RECORD/gitleaks"; chmod 755 "$RECORD/gitleaks"
  PATH="$RECORD:$REALPATH"
  expect_push pass "a delete-only push passes" "$CLEAN" origin :old
  if [ -e "$RECORD/calls" ]; then bad "and a delete-only push runs no gitleaks"
  else ok "and a delete-only push runs no gitleaks"; fi
  PATH=$REALPATH
  expect_push block "a delete beside a leaky branch is blocked" "$NEWB" origin :old feat
  needle "and the block names the rule" "$NEEDLE_RULE"
  TWOREFS=$(leaky_clone two-refs)
  git -C "$TWOREFS" branch other main
  git -C "$TWOREFS" switch -q other; printf 'hello\n' > "$TWOREFS/notes.txt"
  git -C "$TWOREFS" add notes.txt && git -C "$TWOREFS" commit -q -m "a clean change"
  git -C "$TWOREFS" switch -q feat
  expect_push block "two refs, one leaky, are blocked" "$TWOREFS" origin feat other
  needle "and the block names the rule" "$NEEDLE_RULE"
  CLEAN2=$(clone two-clean)
  git -C "$CLEAN2" branch other main
  git -C "$CLEAN2" switch -q other; printf 'hello\n' > "$CLEAN2/notes.txt"
  git -C "$CLEAN2" add notes.txt && git -C "$CLEAN2" commit -q -m "a clean change"
  git -C "$CLEAN2" switch -q feat
  expect_push pass "two clean refs pass" "$CLEAN2" origin feat other
  ANNOT=$(leaky_clone annotated-tag)
  git -C "$ANNOT" tag -a v2 -m "release"
  expect_push block "an annotated tag on a leaky commit is blocked" "$ANNOT" origin v2
  needle "and the block names the rule" "$NEEDLE_RULE"

  echo "== the scan inside an agent's git =="
  # git hands a hook its own GIT_CONFIG_COUNT entries (four safe.directory in an agent session)
  # and the -c options of the push in GIT_CONFIG_PARAMETERS, where a value outranks a pin written
  # after it. The scan keeps the first and drops the second, and still finds the secret.
  COLORARG=$(leaky_clone color-arg)
  GOPTS=(-c color.diff=always)
  expect_push block "git -c color.diff=always push of a leaky branch is blocked naming the rule" "$COLORARG" origin feat
  needle "and it is found, not merely refused" "$NEEDLE_RULE"
  GOPTS=()
  GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=color.diff GIT_CONFIG_VALUE_0=always \
    expect_push block "an inherited GIT_CONFIG_COUNT=1 color.diff=always is blocked naming the rule" "$COLORARG" origin feat
  needle "and it is found, not merely refused" "$NEEDLE_RULE"
  # Inherited entries survive: a recording git first on the scan's PATH logs the configuration
  # every call of the scan sees. Only the scan's calls log (it sets GIT_NO_REPLACE_OBJECTS).
  RECBIN="$TMP/recbin"; mkdir -p "$RECBIN"; RECLOG="$TMP/rec.log"; : > "$RECLOG"
  printf '#!/bin/sh\n[ -n "${GIT_NO_REPLACE_OBJECTS:-}" ] && echo "$GIT_CONFIG_COUNT:$GIT_CONFIG_KEY_0=$GIT_CONFIG_VALUE_0" >> "%s"\nexec "%s" "$@"\n' \
    "$RECLOG" "$REALGIT" > "$RECBIN/git"
  chmod 755 "$RECBIN/git"
  GIT_CONFIG_GLOBAL=$GITCONFIG_WRAP HOOK_EXTRA_PATH=$RECBIN \
  GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=forge.marker GIT_CONFIG_VALUE_0=kept \
    expect_push block "with an inherited GIT_CONFIG_COUNT the leaky push is still blocked naming the rule" "$COLORARG" origin feat
  needle "and it is found, not merely refused" "$NEEDLE_RULE"
  calls=$(wc -l < "$RECLOG" | tr -d ' ')
  if [ "$calls" -gt 3 ] \
     && ! grep -qvE '^[0-9]+:forge\.marker=kept$' "$RECLOG" \
     && ! awk -F: '$1 <= 1 { bad = 1 } END { exit !bad }' "$RECLOG"; then
    ok "every call of the scan has forge.marker=kept at index 0 and the pins after it ($calls calls)"
  else
    bad "every call of the scan has forge.marker=kept at index 0 and the pins after it ($calls calls: $(sort -u "$RECLOG" | tr '\n' ' '))"
  fi

  echo "== pushes from linked worktrees =="
  # git exports GIT_DIR to the hook there: the work tree, the scan and the repository's own hook
  # must all resolve to the worktree.
  WTLEAK=$(leaky_clone wt-leaky-main)
  git -C "$WTLEAK" worktree add -q "$TMP/wt-leaky" -b wt-leaky
  expect_push block "a leaky push from a linked worktree is blocked" "$TMP/wt-leaky" origin wt-leaky
  needle "and the block names the rule" "$NEEDLE_RULE"
  WTCLEAN=$(clone wt-clean-main)
  git -C "$WTCLEAN" worktree add -q "$TMP/wt-clean" -b wt-clean
  printf 'hello\n' > "$TMP/wt-clean/notes.txt"
  git -C "$TMP/wt-clean" add notes.txt && git -C "$TMP/wt-clean" commit -q -m "a clean change"
  expect_push pass "a clean push from a linked worktree passes" "$TMP/wt-clean" origin wt-clean

  echo "== a push to a URL =="
  expect_push pass "a push to the bare remote's path instead of origin passes when clean" "$CLEAN" "$REMOTES/origin.git" feat
  NEWB2=$(leaky_clone url-leaky)
  expect_push block "and is blocked when leaky" "$NEWB2" "$REMOTES/origin.git" feat
  needle "and the block names the rule" "$NEEDLE_RULE"
  # The secret exists only on backup: a push of it to origin's path must be scanned, and a push
  # to backup's path (which already holds it) is not.
  expect_push block "a secret-bearing branch that only backup holds, pushed to origin's path, is blocked" "$TWO" "$REMOTES/origin.git" elsewhere
  needle "and the block names the rule" "$NEEDLE_RULE"
  # A new ref name again: backup holds elsewhere, so a push of that ref has no line to scan.
  expect_push pass "pushed to backup's path it passes: that destination already holds it" "$TWO" "$REMOTES/backup.git" elsewhere:copy
  git init -q --bare "$REMOTES/third.git"
  expect_push block "a URL that matches no configured remote, with a secret in old history, is blocked" "$TWO" "$REMOTES/third.git" elsewhere
  needle "and the block names the rule" "$NEEDLE_RULE"
  # backup fetches from A and pushes to B: B's path attributes no history to a fetch from A.
  git init -q --bare "$REMOTES/dist-a.git"; git init -q --bare "$REMOTES/dist-b.git"
  SRCA=$(leaky_clone dist-source)
  git -C "$SRCA" remote add a "$REMOTES/dist-a.git"
  seed_push "$SRCA" a feat
  DIST=$(clone dist)
  git -C "$DIST" remote add backup "$REMOTES/dist-a.git"
  git -C "$DIST" fetch -q backup 2>/dev/null
  git -C "$DIST" remote set-url --push backup "$REMOTES/dist-b.git"
  git -C "$DIST" branch sec backup/feat
  [ "$(git -C "$DIST" rev-parse sec)" = "$(git -C "$SRCA" rev-parse feat)" ] \
    || { echo "the distinct-URLs fixture is not what it claims" >&2; exit 2; }
  expect_push block "a secret fetched from A and pushed to B's path as a URL is blocked (a pushurl attributes nothing)" "$DIST" "$REMOTES/dist-b.git" sec
  needle "and the block names the rule" "$NEEDLE_RULE"
  expect_push pass "the same branch pushed to A's path passes: A already holds it" "$DIST" "$REMOTES/dist-a.git" sec
  # A pushInsteadOf rewrite: git hands the hook the URL as typed (A) and sends to the rewritten
  # one (B). origin fetches from A, so its tracking ref says what A holds, not what B holds.
  git init -q --bare "$REMOTES/pio-a.git"; git init -q --bare "$REMOTES/pio-b.git"
  PIO=$(leaky_clone pio-rewrite); git -C "$PIO" remote set-url origin "$REMOTES/pio-a.git"
  seed_push "$PIO" origin feat:held
  cp -R "$PIO" "$TMP/pio-control"; PIOCTL="$TMP/pio-control"
  git -C "$PIO" config "url.$REMOTES/pio-b.git.pushInsteadOf" "$REMOTES/pio-a.git"
  expect_push pass "without the rewrite, a push to A's path passes: A already holds the commit" "$PIOCTL" "$REMOTES/pio-a.git" feat:fresh
  expect_push block "a pushInsteadOf rewrite to B never attributes A's history: the secret A holds is scanned" "$PIO" "$REMOTES/pio-a.git" feat:fresh
  needle "and the block names the rule" "$NEEDLE_RULE"
  needle "and says the push is rewritten to B" "rewritten from $REMOTES/pio-a.git"

  echo "== a push to a named remote whose push side differs from its fetch side =="
  # The tracking refs of backup record what A holds. With a pushurl B or a pushInsteadOf rewrite
  # to B, they say nothing about B, so the push by name scans what A holds.
  expect_push block "backup fetching from A with a pushurl B: a secret fetched from A, pushed by name, is blocked" "$DIST" backup sec
  needle "and the block names the rule" "$NEEDLE_RULE"
  DISTEQ=$(clone dist-equal-pushurl)
  git -C "$DISTEQ" remote add backup "$REMOTES/dist-a.git"
  git -C "$DISTEQ" fetch -q backup 2>/dev/null
  git -C "$DISTEQ" remote set-url --push backup "$REMOTES/dist-a.git"
  git -C "$DISTEQ" branch -q sec backup/feat
  expect_push pass "a pushurl equal to the fetch URL still attributes A's history: A already holds it" "$DISTEQ" backup sec
  DISTTWO=$(clone dist-two-pushurls)
  git -C "$DISTTWO" remote add backup "$REMOTES/dist-a.git"
  git -C "$DISTTWO" fetch -q backup 2>/dev/null
  git -C "$DISTTWO" remote set-url --push backup "$REMOTES/dist-a.git"
  git -C "$DISTTWO" remote set-url --add --push backup "$REMOTES/dist-b.git"
  git -C "$DISTTWO" branch -q sec backup/feat
  expect_push block "two pushurls attribute nothing: a secret fetched from A is scanned" "$DISTTWO" backup sec
  needle "and the block names the rule" "$NEEDLE_RULE"
  PIOB=$(clone pio-named)
  git -C "$PIOB" remote add backup "$REMOTES/pio-a.git"
  git -C "$PIOB" fetch -q backup 2>/dev/null
  git -C "$PIOB" branch -q sec backup/held
  git -C "$PIOB" config "url.$REMOTES/pio-b.git.pushInsteadOf" "$REMOTES/pio-a.git"
  [ "$(git -C "$PIOB" rev-parse sec)" = "$(git -C "$PIO" rev-parse feat)" ] \
    || { echo "the named pushInsteadOf fixture is not what it claims" >&2; exit 2; }
  expect_push block "backup with a pushInsteadOf rewrite to B: a secret fetched from A, pushed by name, is blocked" "$PIOB" backup sec
  needle "and the block names the rule" "$NEEDLE_RULE"
  PIOBCTL=$(clone pio-named-control)
  git -C "$PIOBCTL" remote add backup "$REMOTES/pio-a.git"
  git -C "$PIOBCTL" fetch -q backup 2>/dev/null
  git -C "$PIOBCTL" branch -q sec backup/held
  expect_push pass "without the rewrite, fetch and push URL are equal and A's history is excluded" "$PIOBCTL" backup sec

  echo "== the destination is what git sends to, not what the push is named =="
  # origin fetches from A and normally pushes to A, so its tracking refs hold A's secret-bearing
  # commit. A -c pushurl on the command line sends the same push by name to B; the scan drops
  # command-line configuration, so only the hook's destination ($2) can tell that B is not A.
  CMDURL=$(clone cmdline-pushurl)
  git -C "$CMDURL" remote set-url origin "$REMOTES/dist-a.git"
  git -C "$CMDURL" fetch -q origin 2>/dev/null
  git -C "$CMDURL" branch -q sec origin/feat
  [ "$(git -C "$CMDURL" rev-parse sec)" = "$(git -C "$SRCA" rev-parse feat)" ] \
    || { echo "the command-line pushurl fixture is not what it claims" >&2; exit 2; }
  expect_push pass "origin pushed by name to A, which holds the history: excluded, so it passes" "$CMDURL" origin sec
  GOPTS=(-c "remote.origin.pushurl=$REMOTES/dist-b.git")
  expect_push block "origin pushed by name to B through a command-line pushurl: A's history is scanned" "$CMDURL" origin sec
  needle "and the block names the rule" "$NEEDLE_RULE"
  GOPTS=()
  # insteadOf on the fetch side: the remote is configured with a short form that url.<base>.insteadOf
  # expands. The tracking refs were populated through the expanded URL, which is also the
  # destination git hands the hook, so the ordinary push still excludes the remote's history.
  INSTEAD=$(clone instead-of)
  git -C "$INSTEAD" config "url.$REMOTES/.insteadOf" "short:"
  git -C "$INSTEAD" remote set-url origin short:dist-a.git
  [ "$(git -C "$INSTEAD" remote get-url origin)" = "$REMOTES/dist-a.git" ] \
    || { echo "the insteadOf fixture is not what it claims" >&2; exit 2; }
  git -C "$INSTEAD" fetch -q origin 2>/dev/null
  git -C "$INSTEAD" branch -q sec origin/feat
  expect_push pass "a remote written in an insteadOf short form still excludes its own history" "$INSTEAD" origin sec
  # Without a destination the scan attributes nothing, however the push is named.
  rc=0; out=$(/usr/bin/python3 -I "$HOOKS/secret-scan" --repo "$CMDURL" --remote origin -- sec 2>&1) || rc=$?
  if [ "$rc" -eq 1 ]; then ok "secret-scan without --destination scans the whole history"; else bad "secret-scan without --destination scans the whole history (rc $rc: $out)"; fi
  rc=0; out=$(/usr/bin/python3 -I "$HOOKS/secret-scan" --repo "$CMDURL" --remote origin --destination "$REMOTES/dist-a.git" -- sec 2>&1) || rc=$?
  if [ "$rc" -eq 0 ]; then ok "and with --destination A the history A holds is excluded"; else bad "and with --destination A the history A holds is excluded (rc $rc: $out)"; fi

  echo "== the repository's own hook =="
  OWN=$(clone own-hook); OWNLOG="$TMP/own.log"
  mkdir -p "$OWN/.git/hooks"
  printf '#!/bin/bash\necho "$1 $2" >> "%s"\nn=0\nwhile read -r a b c d; do n=$((n + 1)); done\necho "lines $n" >> "%s"\nexit ${OWN_EXIT:-0}\n' \
    "$OWNLOG" "$OWNLOG" > "$OWN/.git/hooks/pre-push"
  chmod 755 "$OWN/.git/hooks/pre-push"
  git -C "$OWN" branch other main
  git -C "$OWN" switch -q other; printf 'hello\n' > "$OWN/notes.txt"
  git -C "$OWN" add notes.txt && git -C "$OWN" commit -q -m "a clean change"
  git -C "$OWN" switch -q feat; printf 'again\n' > "$OWN/notes2.txt"
  git -C "$OWN" add notes2.txt && git -C "$OWN" commit -q -m "a clean change on feat"
  : > "$OWNLOG"
  expect_push pass "a clean two-ref push passes with a repository hook" "$OWN" origin feat other
  if [ "$(sed -n 1p "$OWNLOG")" = "origin $REMOTES/origin.git" ]; then ok "the repository's hook gets the same two arguments"
  else bad "the repository's hook gets the same two arguments ($(sed -n 1p "$OWNLOG"))"; fi
  if [ "$(sed -n 2p "$OWNLOG")" = "lines 2" ]; then ok "and both lines on stdin, the last one included"
  else bad "and both lines on stdin, the last one included ($(sed -n 2p "$OWNLOG"))"; fi
  OWN_EXIT=1 expect_push refused "a repository hook that exits 1 blocks a clean push" "$OWN" origin feat other
  chmod 644 "$OWN/.git/hooks/pre-push"; : > "$OWNLOG"
  expect_push pass "a repository hook that is not executable is not run" "$OWN" origin feat other
  if [ ! -s "$OWNLOG" ]; then ok "and it left no trace"; else bad "and it left no trace"; fi
  OWNWT=$(clone own-hook-wt)
  mkdir -p "$OWNWT/.git/hooks"; cp "$OWN/.git/hooks/pre-push" "$OWNWT/.git/hooks/pre-push"; chmod 755 "$OWNWT/.git/hooks/pre-push"
  git -C "$OWNWT" worktree add -q "$TMP/own-wt" -b own-wt
  : > "$OWNLOG"
  expect_push pass "a clean push from a linked worktree passes" "$TMP/own-wt" origin own-wt
  if [ "$(sed -n 1p "$OWNLOG")" = "origin $REMOTES/origin.git" ]; then ok "and the common directory's hook runs"
  else bad "and the common directory's hook runs ($(sed -n 1p "$OWNLOG"))"; fi
  # The link must meet a push that sends a commit: with nothing outgoing the hook gets no line and
  # a re-entry would end quietly. Here it would run the scan and the link again, without end, so
  # the row is bounded.
  OWNLINK=$(clone own-hook-link)
  mkdir -p "$OWNLINK/.git/hooks"; ln -sf "$HOOKS/pre-push" "$OWNLINK/.git/hooks/pre-push"
  printf 'again\n' > "$OWNLINK/notes2.txt"
  git -C "$OWNLINK" add notes2.txt && git -C "$OWNLINK" commit -q -m "a clean change on feat"
  # A regression here is killed by SIGKILL, so no hook level's EXIT trap runs and its pre-push.*
  # temp file stays: the bounded rows get a TMPDIR of their own, and a normal run must leave it empty.
  BTMP="$TMP/bound-tmp"; mkdir -p "$BTMP"
  TMPDIR=$BTMP PUSH_BOUND=10 expect_push pass "a repository hook that is a link to the global hook is not re-entered (a commit is outgoing)" "$OWNLINK" origin feat
  # Re-entered through a link to the hook file alone, the global hook meets a hooks directory with
  # no scan beside it and refuses, so that row ends without help. A link to the whole hooks
  # directory is the shape that would recurse for as long as it is allowed to.
  OWNDIR=$(clone own-hook-dirlink)
  rm -rf "$OWNDIR/.git/hooks"; ln -s "$HOOKS" "$OWNDIR/.git/hooks"
  printf 'again\n' > "$OWNDIR/notes2.txt"
  git -C "$OWNDIR" add notes2.txt && git -C "$OWNDIR" commit -q -m "a clean change on feat"
  TMPDIR=$BTMP PUSH_BOUND=10 expect_push pass "a hooks directory that is a link to the global one is not re-entered (a commit is outgoing)" "$OWNDIR" origin feat
  if [ -z "$(find "$BTMP" -name 'pre-push.*')" ]; then ok "and the bounded rows leave no hook temp files behind"
  else bad "and the bounded rows leave no hook temp files behind ($(find "$BTMP" -name 'pre-push.*' | tr '\n' ' '))"; fi
  # If git cannot say where the repository's hooks live, its own hook cannot be run, and a push
  # that skips it silently is a push the repository's rules never saw: refuse, scan or no scan.
  NOCOMMON="$TMP/nocommon"; mkdir -p "$NOCOMMON"
  printf '#!/bin/sh\ncase " $* " in\n  *" --git-common-dir "*) exit 1 ;;\nesac\nexec "%s" "$@"\n' "$REALGIT" > "$NOCOMMON/git"
  chmod 755 "$NOCOMMON/git"
  : > "$OWNLOG"; chmod 755 "$OWN/.git/hooks/pre-push"
  GIT_CONFIG_GLOBAL=$GITCONFIG_WRAP HOOK_EXTRA_PATH=$NOCOMMON \
    expect_push block "a git that cannot name the common directory blocks a push the scan passed" "$OWN" origin feat other
  needle "and says why" "cannot find the repository's own hooks"
  GIT_CONFIG_GLOBAL=$GITCONFIG_WRAP HOOK_EXTRA_PATH=$NOCOMMON \
    expect_push block "and so does a delete-only push" "$CLEAN" origin :old
  needle "and says why" "cannot find the repository's own hooks"
  # If the hook cannot save what git wrote on stdin (a full temporary filesystem), it holds no
  # list of refs: going on would scan nothing and pass.
  NOCAT="$TMP/nocat"; mkdir -p "$NOCAT"
  printf '#!/bin/sh\nexit 1\n' > "$NOCAT/cat"; chmod 755 "$NOCAT/cat"
  GIT_CONFIG_GLOBAL=$GITCONFIG_WRAP HOOK_EXTRA_PATH=$NOCAT \
    expect_push block "a hook that cannot save git's list of refs blocks the push" "$OWN" origin feat
  needle "and says why" "cannot save the list of refs"

  echo "== the command line of secret-scan =="
  rc=0; out=$(/usr/bin/python3 -I "$HOOKS/secret-scan" --repo "$CLEAN" --remote origin 2>&1) || rc=$?
  if [ "$rc" -eq 2 ]; then ok "no -- is a usage error (exit 2)"; else bad "no -- is a usage error (exit 2, got $rc)"; fi
  rc=0; out=$(/usr/bin/python3 -I "$HOOKS/secret-scan" --repo "$CLEAN" --remote origin -- 2>&1) || rc=$?
  if [ "$rc" -eq 0 ] && [ -z "$out" ]; then ok "no sources is exit 0 with empty output"; else bad "no sources is exit 0 with empty output (rc $rc: $out)"; fi
  rc=0; out=$(/usr/bin/python3 -I "$HOOKS/secret-scan" --repo "$CLEAN" --remote origin -- HEAD 2>/dev/null) || rc=$?
  if [ "$rc" -eq 0 ] && [ -z "$out" ]; then ok "stdout is empty on a clean scan"; else bad "stdout is empty on a clean scan (rc $rc: $out)"; fi
  rc=0; out=$(/usr/bin/python3 -I "$HOOKS/secret-scan" --repo "$COLORARG" --remote origin -- HEAD 2>/dev/null) || rc=$?
  if [ "$rc" -eq 1 ] && [ -z "$out" ]; then ok "stdout is empty on a refusal too"; else bad "stdout is empty on a refusal too (rc $rc: $out)"; fi
fi

echo "== the scan fails closed =="
NOGL="$TMP/nogl"; mkdir -p "$NOGL"
PATH="$NOGL:/usr/bin:/bin"
expect_push block "a missing gitleaks blocks the push" "$CLEAN" origin feat
needle "and names the remedy" "brew bundle"
BROKEN="$TMP/brokengl"; mkdir -p "$BROKEN"
printf '#!/bin/sh\necho "gitleaks: boom" >&2\nexit 2\n' > "$BROKEN/gitleaks"; chmod 755 "$BROKEN/gitleaks"
PATH="$BROKEN:$REALPATH"
expect_push block "a gitleaks error blocks the push" "$CLEAN" origin feat
needle "and carries the error" "boom"
# A clean exit is not proof of a clean scan: gitleaks exits 0 with "0 commits scanned" when its
# own git log fails or is misparsed. CLEAN carries exactly one commit that adds text.
for spec in "zero|0 commits scanned.|" "noline||" \
            "err|1 commits scanned.|ERR [git] fatal: bad revision" "many|2 commits scanned.|"; do
  name=${spec%%|*}; rest=${spec#*|}; line=${rest%%|*}; errline=${rest#*|}
  STUB2="$TMP/cov-$name"; mkdir -p "$STUB2"
  {
    printf '#!/bin/sh\n'
    [ -n "$errline" ] && printf 'echo "6:00PM %s" >&2\n' "$errline"
    [ -n "$line" ] && printf 'echo "6:00PM INF %s" >&2\n' "$line"
    printf 'exit 0\n'
  } > "$STUB2/gitleaks"; chmod 755 "$STUB2/gitleaks"
  PATH="$STUB2:$REALPATH"
  case $name in
    zero)  expect_push block "a gitleaks that scanned 0 of 1 commits is a deny" "$CLEAN" origin feat
           needle "and the deny says how many it scanned" "scanned 0 commit(s) but this push carries 1"
           # A commit that only removes lines is still one gitleaks must cover.
           expect_push block "a gitleaks that skipped a removal-only commit is a deny" "$TRIM" origin trim
           needle "and the deny says how many it scanned" "scanned 0 commit(s) but this push carries 1" ;;
    noline) expect_push block "a gitleaks that reports no count is a deny" "$CLEAN" origin feat
            needle "and the deny says the count was unknown" "scanned an unknown number of commit(s)" ;;
    err)   expect_push block "a gitleaks that logs an ERR line is a deny" "$CLEAN" origin feat
           needle "and the deny says gitleaks logged an error" "gitleaks logged an error while scanning" ;;
    many)  expect_push block "a count that differs from the outgoing one is a deny" "$CLEAN" origin feat
           needle "and the deny gives both counts" "scanned 2 commit(s) but this push carries 1" ;;
  esac
done
OKGL="$TMP/cov-ok"; mkdir -p "$OKGL"
printf '#!/bin/sh\necho "6:00PM INF 1 commits scanned." >&2\nexit 0\n' > "$OKGL/gitleaks"; chmod 755 "$OKGL/gitleaks"
PATH="$OKGL:$REALPATH"
expect_push pass "a gitleaks that scanned exactly the outgoing commits passes" "$CLEAN" origin feat
expect_push pass "and so does one that scanned the removal-only commit" "$TRIM" origin trim
# A gitleaks that hangs (or a git it spawns) must end in a block within the scan's budget, and
# the whole process group must go: a surviving child would hold the hook open.
HANG="$TMP/hanggl"; mkdir -p "$HANG"
printf '#!/bin/sh\nsleep 30\nexit 0\n' > "$HANG/gitleaks"; chmod 755 "$HANG/gitleaks"
PATH="$HANG:$REALPATH"
export SECRET_SCAN_BUDGET=2
started=$(date +%s)
expect_push block "a gitleaks slower than the budget is a block" "$CLEAN" origin feat
needle "and the deny says the scan timed out" "did not finish"
elapsed=$(( $(date +%s) - started ))
unset SECRET_SCAN_BUDGET
if [ "$elapsed" -le 12 ]; then ok "a hung gitleaks is cut off at the budget (${elapsed}s)"
else bad "a hung gitleaks is cut off at the budget (${elapsed}s)"; fi
PATH=$REALPATH

echo "== a lazy fetch never runs =="
# The outgoing commit's tree names a blob that is not present (git mktree --missing), so reading
# its patch would fetch it from the promisor remote, whose uploadpack writes a marker. The push is
# blocked (the outgoing patches cannot be read: push by hand) and no marker appears.
LAZYB=$(clone lazyblob)
git -C "$LAZYB" switch -q -c work
MISSING_TREE=$(printf '100644 blob 2222222222222222222222222222222222222222\tghost.txt\n' \
  | git -C "$LAZYB" mktree --missing)
MISSING_COMMIT=$(git -C "$LAZYB" commit-tree "$MISSING_TREE" -p "$(git -C "$LAZYB" rev-parse work)" -m "missing blob")
git -C "$LAZYB" update-ref refs/heads/work "$MISSING_COMMIT"
git -C "$LAZYB" config remote.origin.promisor true
git -C "$LAZYB" config remote.origin.partialclonefilter blob:none
git -C "$LAZYB" config remote.origin.uploadpack "touch $TMP/lazyblob-marker; git-upload-pack"
expect_push block "an outgoing commit naming a missing blob, with a promisor remote" "$LAZYB" origin work
needle "and the deny says to push by hand" "Push by hand"
if [ -e "$TMP/lazyblob-marker" ]; then bad "the patch listing lazy-fetched through the promisor remote"
else ok "the patch listing never lazy-fetches"; fi

echo "== the hook without its scan =="
mv "$HOOKS/secret-scan" "$HOOKS/secret-scan.away"
expect_push block "a missing secret-scan blocks the push" "$CLEAN" origin feat
needle "and says it is missing" "is missing"
mv "$HOOKS/secret-scan.away" "$HOOKS/secret-scan"
expect_push pass "with secret-scan restored the same push passes" "$CLEAN" origin feat

echo "== the files deploy =="
# chezmoi must manage both files, or the global hook never reaches ~/.config/git/hooks.
if ! managed=$(chezmoi --source "$SRC" managed 2>"$TMP/managed.err"); then
  printf 'INCONCLUSIVE: chezmoi managed failed: %s\n  a cold external cache does this; warm it outside the sandbox: command chezmoi --source %s managed >/dev/null\n' \
    "$(awk 'NF { print; exit }' "$TMP/managed.err")" "$SRC" >&2
  exit 2
fi
for f in .config/git/hooks/pre-push .config/git/hooks/secret-scan; do
  if printf '%s\n' "$managed" | grep -qx "$f"; then ok "chezmoi manages $f"; else bad "chezmoi manages $f"; fi
done

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
