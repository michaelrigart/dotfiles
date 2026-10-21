#!/usr/bin/env bash
# Mocked test for .scripts/skill-updates.sh: stubs gh on PATH (served from per-case
# environment variables, every call appended to $CALLS) and asserts the stdout lines, the
# exit codes, the 404 fallback, the validation of every gh answer, and the --open-issues
# dedupe and ordering. The script runs under /bin/bash to pin Bash 3.2 compatibility.
# Run: ./tests/skill-updates.test.sh
set -u
SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/.scripts/skill-updates.sh"
[ -f "$SCRIPT" ] || { echo "missing script under test: $SCRIPT" >&2; exit 2; }
T=$(mktemp -d "${TMPDIR:-/tmp}/skill-updates.XXXXXX") || { echo "cannot create a temp dir" >&2; exit 2; }
BIN="$T/bin"; NOGH="$T/nogh"; CALLS="$T/calls.log"
mkdir -p "$BIN" "$NOGH"
trap 'rm -rf "$T"' EXIT
PWDLOG="$T/gh-pwd.log"; export PWDLOG
pass=0; fail=0; OUT=""; ERR=""; RC=0

P=e27ceeff60368cf6966b4ea00a5b9b36418ee9a0
B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
C=cccccccccccccccccccccccccccccccccccccccc
Q=1111111111111111111111111111111111111111   # the second repo's pin
D=dddddddddddddddddddddddddddddddddddddddd   # the second repo's newer commit

# gh is stubbed on PATH. Responses come from variables keyed on the repo (and ref):
#   REL_{OUT,RC,ERR}_<REPO>          api repos/<o>/<r>/releases/latest --jq .tag_name
#   COM_{OUT,RC,ERR}_<REPO>_<REF>    api repos/<o>/<r>/commits/<ref> --jq .sha
#   LABEL_{RC,ERR}, LIST_{OUT,RC,ERR}, CREATE_{RC,ERR}
# An unconfigured call fails loudly (rc 99), so a missing fixture never reads as a pass.
cat > "$BIN/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$CALLS"; pwd > "$PWDLOG"
key() { printf '%s' "$1" | tr 'a-z' 'A-Z' | tr -c 'A-Z0-9' '_'; }
emit() {  # emit <OUT var> <RC var> <ERR var>
  local o=${!1-} r=${!2-99} e=${!3-stub: unconfigured call}
  [ -z "$o" ] || printf '%s\n' "$o"
  [ -z "$e" ] || [ "$r" = 0 ] || printf '%s\n' "$e" >&2
  exit "$r"
}
case "$*" in
  "api repos/"*"/releases/latest --jq .tag_name")
    p=${2#repos/}; r=$(key "$(basename "${p%/releases/latest}")")
    emit "REL_OUT_$r" "REL_RC_$r" "REL_ERR_$r" ;;
  "api repos/"*"/commits/"*" --jq .sha")
    p=${2#repos/}; repo=$(key "$(basename "$(dirname "$(dirname "$p")")")")
    ref=$(key "$(basename "$p")")
    emit "COM_OUT_${repo}_$ref" "COM_RC_${repo}_$ref" "COM_ERR_${repo}_$ref" ;;
  "label create"*)  r=${LABEL_RC-0}; [ "$r" = 0 ] || printf '%s\n' "${LABEL_ERR-}" >&2; exit "$r" ;;
  "issue list"*)    emit LIST_OUT LIST_RC LIST_ERR ;;
  "issue create"*)  r=${CREATE_RC-0}; [ "$r" = 0 ] || printf '%s\n' "${CREATE_ERR-}" >&2; exit "$r" ;;
  *) echo "stub gh: unexpected call: $*" >&2; exit 98 ;;
esac
STUB
chmod +x "$BIN/gh"

key() { printf '%s' "$1" | tr 'a-z' 'A-Z' | tr -c 'A-Z0-9' '_'; }
# rel <repo> <out> [rc] [err]   com <repo> <ref> <out> [rc] [err]
rel() { local r; r=$(key "$1"); export "REL_OUT_$r=$2" "REL_RC_$r=${3:-0}" "REL_ERR_$r=${4:-}"; }
com() { local k; k="$(key "$1")_$(key "$2")"; export "COM_OUT_$k=$3" "COM_RC_$k=${4:-0}" "COM_ERR_$k=${5:-}"; }
reset() {
  local v
  for v in $(compgen -v | grep -E '^(REL|COM|LABEL|LIST|CREATE)_'); do unset "$v"; done
  export LABEL_RC=0 LIST_OUT= LIST_RC=0 CREATE_RC=0
  rel clarity v0.2.1; com clarity v0.2.1 "$P"
  : > "$CALLS"
}
# entry <name> <owner/repo> <sha> [tag comment]
entry() {
  printf '[".agents/skills/%s"]\n    type = "archive"\n' "$1"
  [ -z "${4:-}" ] || printf '    # %s\n' "$4"
  printf '    url = "https://github.com/%s/archive/%s.tar.gz"\n    exact = true\n    stripComponents = 1\n' "$2" "$3"
  printf '    include = ["*/SKILL.md", "*/LICENSE"]\n\n'
}
clarity() { entry clarity addyosmani/clarity "$P" "${1-v0.2.1}"; }
# run <externals content> [script args...] ; sets OUT (stdout), ERR (stderr), RC
run() {
  printf '%s\n' "$1" > "$T/externals.toml"; shift
  : > "$CALLS"
  OUT=$(CALLS="$CALLS" PATH="$BIN:$PATH" /bin/bash "$SCRIPT" --externals "$T/externals.toml" "$@" 2>"$T/err"); RC=$?
  ERR=$(cat "$T/err")
}
_pass() { echo "  PASS: $1"; pass=$((pass + 1)); }
_fail() {
  echo "  FAIL: $1"
  printf '%s\n' "$OUT" | sed 's/^/    out| /'; printf '%s\n' "$ERR" | sed 's/^/    err| /'
  [ ! -s "$CALLS" ] || sed 's/^/    call| /' "$CALLS"
  fail=$((fail + 1))
}
out_is()    { if [ "$OUT" = "$1" ]; then _pass "$2"; else _fail "$2"; fi; }
out_has()   { case "$OUT" in *"$1"*) _pass "$2" ;; *) _fail "$2" ;; esac; }
out_hasnt() { case "$OUT" in *"$1"*) _fail "$2" ;; *) _pass "$2" ;; esac; }
err_has()   { case "$ERR" in *"$1"*) _pass "$2" ;; *) _fail "$2" ;; esac; }
rc_is()     { if [ "$RC" -eq "$1" ]; then _pass "$2"; else _fail "$2"; fi; }
called()     { if grep -qF -- "$1" "$CALLS"; then _pass "$2"; else _fail "$2"; fi; }
not_called() { if grep -qF -- "$1" "$CALLS"; then _fail "$2"; else _pass "$2"; fi; }
line_of() { grep -nF -- "$1" "$CALLS" | head -n 1 | cut -d: -f1; }

echo "A. default mode"
reset
run "$(clarity)"
out_is "current: clarity v0.2.1" "pin equals the release commit: current line"
rc_is 0 "current: exit 0"

reset; rel clarity v0.3.0; com clarity v0.3.0 "$B"
run "$(clarity)"
out_is "update: clarity v0.2.1 → v0.3.0 https://github.com/addyosmani/clarity/compare/$P...$B" "newer release: update line with compare URL"
rc_is 1 "update: exit 1"

reset; rel clarity '{"message":"Not Found","status":"404"}' 1 "gh: Not Found (HTTP 404)"
com clarity HEAD "$C"
run "$(clarity)"
out_is "update: clarity v0.2.1 → ccccccc https://github.com/addyosmani/clarity/compare/$P...$C" "no releases: falls back to HEAD with a short-SHA label"
rc_is 1 "404 fallback: exit 1"
called "api repos/addyosmani/clarity/commits/HEAD --jq .sha" "404 fallback asked for HEAD"

reset; rel clarity '' 1 "gh: Bad Gateway (HTTP 502)"
run "$(clarity)"
rc_is 2 "releases HTTP 502: exit 2"
out_hasnt "current:" "releases HTTP 502: no current line"
out_hasnt "update:" "releases HTTP 502: no update line"
not_called "commits/HEAD" "releases HTTP 502: no HEAD fallback"

reset; rel clarity '' 0
run "$(clarity)"
rc_is 2 "empty release answer with exit 0: exit 2"
out_hasnt "current:" "empty release answer: no current line"

reset; rel clarity null 0
run "$(clarity)"
rc_is 2 "release lookup returns null: exit 2"
out_is "" "release null: no stdout"

reset; rel clarity 'v1 beta' 0
run "$(clarity)"
rc_is 2 "release tag with whitespace: exit 2"

reset; rel clarity 'v1|x' 0; com clarity 'v1|x' "$B"
run "$(clarity)"
rc_is 2 "release tag with a pipe: exit 2"
out_is "" "release tag with a pipe: no stdout"

reset; com clarity v0.2.1 null 0
run "$(clarity)"
rc_is 2 "commit lookup returns null: exit 2"
out_is "" "commit null: no current or update line"

reset; com clarity v0.2.1 not-a-sha 0
run "$(clarity)"
rc_is 2 "commit lookup returns not-a-sha: exit 2"
out_is "" "not-a-sha: no current or update line"

reset; com clarity v0.2.1 "${P%?}" 0
run "$(clarity)"
rc_is 2 "39-character commit: exit 2"

reset; com clarity v0.2.1 '' 0
run "$(clarity)"
rc_is 2 "empty commit answer with exit 0: exit 2"

reset; com clarity v0.2.1 '' 1 "gh: Not Found (HTTP 404)"
run "$(clarity)"
rc_is 2 "commit lookup HTTP 404 does not fall back: exit 2"
not_called "commits/HEAD" "commit 404 made no HEAD call"

reset
printf '%s\n' "$(clarity)" > "$T/externals.toml"
OUT=$(CALLS="$CALLS" PATH="$NOGH:/usr/bin:/bin" /bin/bash "$SCRIPT" --externals "$T/externals.toml" 2>"$T/err"); RC=$?; ERR=$(cat "$T/err")
rc_is 2 "gh absent from PATH: exit 2"
err_has "skill-updates: " "gh absent: diagnostic is prefixed"

reset
run '[".agents/skills/clarity"]
    type = "archive"
    url = "https://example.com/clarity.tar.gz"'
rc_is 2 "non-GitHub URL: exit 2"
out_is "" "non-GitHub URL: no stdout"

reset
run '[".agents/skills/clarity"]
    type = "archive"
    exact = true'
rc_is 2 "entry without a url: exit 2"

reset
run "$(clarity '')"
out_is "current: clarity e27ceef" "no tag comment: the pinned label is the 7-character SHA"

reset
run "$(clarity 'v1|x')"
out_is "current: clarity e27ceef" "a tag comment containing a pipe is ignored, not a corrupt record"
rc_is 0 "pipe in tag comment: exit 0"

reset
run "$(clarity 'some prose')"
out_is "current: clarity e27ceef" "a comment that is not a tag is ignored"

reset
run '[".agents/skills/clarity"]
    type = "archive"
    # v0.2.1

    url = "https://github.com/addyosmani/clarity/archive/'"$P"'.tar.gz"'
out_is "current: clarity e27ceef" "a blank line between the tag comment and url resets the label"

reset
run '[".agents/skills/clarity"]
    type = "archive"
    # v0.2.1
    exact = true
    url = "https://github.com/addyosmani/clarity/archive/'"$P"'.tar.gz"'
out_is "current: clarity e27ceef" "a tag comment must sit directly above url"

reset; rel other v1.0.0; com other v1.0.0 "$D"
run "$(clarity)
$(entry other someone/other "$Q" v0.9.0)"
out_is "current: clarity v0.2.1
update: other v0.9.0 → v1.0.0 https://github.com/someone/other/compare/$Q...$D" "two entries: only the stale one has update"
rc_is 1 "two entries, one stale: exit 1"

reset
run "$(printf '[".claude/other"]\n    url = "https://example.com/x"\n\n')
$(clarity)"
out_is "current: clarity v0.2.1" "entries outside .agents/skills are not read"
rc_is 0 "foreign entry skipped: exit 0"

reset
run "$(clarity)
[ \".agents/skills/spaced\" ]
    url = \"https://github.com/o/spaced/archive/$P.tar.gz\""
rc_is 2 "header with inner spaces is not silently dropped: exit 2"
err_has "unparseable entry header" "spaced header: diagnostic"
out_has "current: clarity" "spaced header: other entries are still checked"

reset
run "$(clarity)
[\".agents/skills/noted\"] # note
    url = \"https://github.com/o/noted/archive/$P.tar.gz\""
rc_is 2 "header with a trailing comment is not silently dropped: exit 2"
err_has "unparseable entry header" "commented header: diagnostic"

reset
run "# only a comment"
rc_is 2 "zero entries: exit 2"

reset
run "$(clarity)" --frobnicate
rc_is 2 "unknown option: exit 2"
not_called "api" "unknown option made no gh call"

reset
OUT=$(CALLS="$CALLS" PATH="$BIN:$PATH" /bin/bash "$SCRIPT" --externals "$T/missing.toml" 2>"$T/err"); RC=$?; ERR=$(cat "$T/err")
rc_is 2 "missing externals file: exit 2"

echo "B0. working directory"
reset
mkdir -p "$T/elsewhere"; REPO_ROOT="$(cd "$(dirname "$SCRIPT")/.." && pwd)"
printf '%s\n' "$(clarity)" > "$T/elsewhere/ext.toml"
rm -f "$PWDLOG"; : > "$CALLS"
OUT=$(cd "$T/elsewhere" && CALLS="$CALLS" PATH="$BIN:$PATH" /bin/bash "$SCRIPT" --externals ext.toml 2>"$T/err"); RC=$?; ERR=$(cat "$T/err")
out_is "current: clarity v0.2.1" "relative --externals resolves against the caller's cwd"
rc_is 0 "run from another directory: exit 0"
if [ "$(cat "$PWDLOG" 2>/dev/null)" = "$REPO_ROOT" ]; then _pass "gh runs from the script's repository root"; else _fail "gh runs from the script's repository root"; fi

echo "B. --open-issues"
reset; rel clarity v0.3.0; com clarity v0.3.0 "$B"
run "$(clarity)" --open-issues
rc_is 0 "update with no open issue: exit 0"
called "label create skill-update --color 0E8A16 --description A pinned agent skill has a newer upstream release --force" "label create with its colour, description and --force"
called "issue list --label skill-update --state open --limit 200 --json title --jq .[].title" "open issues listed"
called "issue create --title Skill update: clarity v0.3.0 --label skill-update --body clarity has a newer upstream release: v0.2.1 → v0.3.0." "issue created with title, label and body"
called "Compare: https://github.com/addyosmani/clarity/compare/$P...$B" "body carries the compare URL"
called 'lists `.agents/skills/clarity/SKILL.md`' "body names the SKILL.md check"
called 'put `Closes #<this issue>` in the commit message.' "body keeps the Closes placeholder"
called 'After merge: `chezmoi apply`.' "body ends with the apply step"
l=$(line_of "label create"); i=$(line_of "issue create")
if [ -n "$l" ] && [ -n "$i" ] && [ "$l" -lt "$i" ]; then _pass "label create is recorded before issue create"; else _fail "label create is recorded before issue create"; fi
out_has "update: clarity v0.2.1 → v0.3.0" "--open-issues still prints the update line"

reset; rel clarity v0.3.0; com clarity v0.3.0 "$B"
export LIST_OUT='Skill update: clarity v0.3.0'
run "$(clarity)" --open-issues
not_called "issue create" "open issue with the same title: no issue create"
rc_is 0 "deduped: exit 0"

reset; rel clarity v0.3.0; com clarity v0.3.0 "$B"
export LIST_OUT='Skill update: clarity v0.2.9
Unrelated issue'
run "$(clarity)" --open-issues
called "issue create --title Skill update: clarity v0.3.0" "open issue for another version: issue create is called"
rc_is 0 "other version open: exit 0"

reset; rel clarity v0.3.0; com clarity v0.3.0 "$B"
export LIST_OUT='Skill update: clarity v0.3.0 extra'
run "$(clarity)" --open-issues
called "issue create --title Skill update: clarity v0.3.0" "dedupe is an exact title match"

reset; rel clarity v0.3.0; com clarity v0.3.0 "$B"
export LABEL_RC=1 LABEL_ERR="gh: Forbidden (HTTP 403)"
run "$(clarity)" --open-issues
rc_is 2 "label create fails: exit 2"
not_called "issue create" "label create fails: no issue create"
not_called "issue list" "label create fails: no issue list"

reset; rel clarity v0.3.0; com clarity v0.3.0 "$B"
export LIST_RC=1 LIST_ERR="gh: Bad Gateway (HTTP 502)"
run "$(clarity)" --open-issues
rc_is 2 "issue list fails: exit 2"
not_called "issue create" "issue list fails: no issue create"

reset; rel clarity v0.3.0; com clarity v0.3.0 "$B"
export CREATE_RC=1 CREATE_ERR="gh: Forbidden (HTTP 403)"
run "$(clarity)" --open-issues
rc_is 2 "issue create fails: exit 2"
called "issue create" "issue create was attempted"

reset; rel clarity v0.3.0; com clarity v0.3.0 "$B"; rel other v1.0.0; com other v1.0.0 not-a-sha
run "$(entry other someone/other "$Q" v0.9.0)
$(clarity)" --open-issues
rc_is 2 "one update, one invalid answer: exit 2"
called "issue create --title Skill update: clarity v0.3.0" "the resolved update still gets its issue"
not_called "Skill update: other" "the unresolved skill gets no issue"
out_hasnt "update: other" "the unresolved skill has no update line"

reset
run "$(clarity)" --open-issues
rc_is 0 "every pin current: exit 0"
not_called "label" "every pin current: no label call"
not_called "issue" "every pin current: no issue call"

reset; rel clarity '' 1 "gh: Bad Gateway (HTTP 502)"
run "$(clarity)" --open-issues
rc_is 2 "only a failed lookup: exit 2"
not_called "label" "failed lookup, no updates: no label call"

echo; echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
