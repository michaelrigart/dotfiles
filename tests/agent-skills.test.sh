#!/usr/bin/env bash
# Third-party agent skills are pinned archive externals in .chezmoiexternal.toml, each with
# a Claude Code symlink in dot_claude/skills/ and a .chezmoiignore re-include.
#
# For every `.agents/skills/<name>` entry this suite checks what the entry DOES, not which
# fields it has:
#   - static checks for what an apply cannot show (type, a 40-hex commit URL, no refresh)
#   - behaviour through real chezmoi: the production entry with only its url swapped for a
#     local fixture tarball (`file://`), applied to a scratch destination with its own
#     config, cache and state. The suite never applies the real https URL, so it needs no
#     network and no warm cache.
# Every check has a negative case that must fail.
#
# Run: ./tests/agent-skills.test.sh   (sandboxed is fine)

set -uo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOML="$SRC/.chezmoiexternal.toml"
[ -f "$TOML" ] || { echo "missing $TOML" >&2; exit 2; }
command -v chezmoi >/dev/null 2>&1 || { echo "chezmoi not on PATH" >&2; exit 2; }

T="$(mktemp -d "${TMPDIR:-/tmp}/agent-skills.XXXXXX")"
trap 'rm -rf "$T"' EXIT
: > "$T/empty.toml"
export COPYFILE_DISABLE=1

pass=0; fail=0

_pass() { echo "  PASS: $1"; pass=$((pass + 1)); }
_fail() { echo "  FAIL: $1"; printf '    | %s\n' "$2"; fail=$((fail + 1)); }

# --- the TOML reader: a narrow parser for this file's shape --------------------------------

# entries <toml> — every skill name with a [".agents/skills/<name>"] header
entries() {
  sed -n 's|^\["\.agents/skills/\([^"]*\)"\][[:space:]]*$|\1|p' "$1"
}

# section <toml> <name> — the entry's lines up to the next [ header, comments dropped
section() {
  awk -v h="[\".agents/skills/$2\"]" '
    $0 == h { on = 1; next }
    on && /^\[/ { exit }
    on && $0 !~ /^[[:space:]]*#/ { print }
  ' "$1"
}

# get <toml> <name> <key> — the raw right-hand side of `key = value`
get() {
  section "$1" "$2" | sed -n "s|^[[:space:]]*$3[[:space:]]*=[[:space:]]*\\(.*\\)\$|\\1|p" | head -n 1
}

# --- static checks -------------------------------------------------------------------------

# static_ok <toml> <name> — 0 if clean, else 1 with the reason on stdout
static_ok() {
  local toml="$1" name="$2" type url refresh
  type=$(get "$toml" "$name" type)
  [ "$type" = '"archive"' ] || { echo "type is ${type:-absent}, not \"archive\""; return 1; }
  url=$(get "$toml" "$name" url | sed 's/^"//; s/"$//')
  printf '%s' "$url" | grep -Eq '^https://github\.com/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+/archive/[0-9a-f]{40}\.tar\.gz$' \
    || { echo "url is not a full-commit archive URL: $url"; return 1; }
  refresh=$(get "$toml" "$name" refreshPeriod)
  case "$refresh" in
    ''|0|'"0"'|'"0s"') ;;
    *) echo "refreshPeriod is set: $refresh"; return 1 ;;
  esac
  return 0
}

# --- the behaviour harness -----------------------------------------------------------------

# fixture <name> <dir> — a tarball of the pinned commit's layout at <dir>/fixture.tar.gz
fixture() {
  local name="$1" dir="$2" top f
  top="$dir/fix/$name-0123456789abcdef0123456789abcdef01234567"
  case "$name" in
    clarity)
      mkdir -p "$top"
      for f in SKILL.md LICENSE README.md DESIGN.md PRODUCT.md netlify.toml skills.sh.json .gitignore \
               .claude/launch.json .github/workflows/validate.yml commands/clarity-review.md \
               evals/e.md references/edit.md references/review.md samples/s.md \
               scripts/prose_stats.py scripts/strip_markdown.py site/index.html; do
        mkdir -p "$top/$(dirname "$f")"
        printf 'fixture %s\n' "$f" > "$top/$f"
      done
      ;;
    *) echo "no fixture for $name: add one"; return 1 ;;
  esac
  tar -C "$dir/fix" -czf "$dir/fixture.tar.gz" "$(basename "$top")"
}

# expected_files <name> — the exact file set an apply must leave in the extracted copy
expected_files() {
  case "$1" in
    clarity)
      printf '%s\n' LICENSE SKILL.md references/edit.md references/review.md \
        scripts/prose_stats.py scripts/strip_markdown.py ;;
  esac
}

# behaviour_ok <toml> <ignore-file> <symlink-src-dir> <name>
# 0 if the entry behaves, else 1 with the first failing check on stdout
behaviour_ok() {
  local toml="$1" ignore="$2" symdir="$3" name="$4" d src home out want got
  d=$(mktemp -d "$T/case.XXXXXX")
  src="$d/src"; home="$d/home"
  mkdir -p "$src/dot_claude/skills" "$home/.agents/skills/basecamp" "$home/.claude/skills/cross-review"

  cp "$ignore" "$src/.chezmoiignore"
  [ -f "$symdir/symlink_$name" ] && cp "$symdir/symlink_$name" "$src/dot_claude/skills/symlink_$name"
  { printf '["%s"]\n' ".agents/skills/$name"
    section "$toml" "$name" | sed "s|^\\([[:space:]]*url[[:space:]]*=[[:space:]]*\\).*|\\1\"file://$d/fixture.tar.gz\"|"
  } > "$src/.chezmoiexternal.toml"

  out=$(fixture "$name" "$d") || { echo "$out"; return 1; }
  printf 'sentinel' > "$home/.agents/skills/basecamp/SKILL.md"
  printf 'sentinel' > "$home/.claude/skills/cross-review/SKILL.md"

  apply() {
    chezmoi --config "$T/empty.toml" --source "$src" --destination "$home" \
      --cache "$d/cache" --persistent-state "$d/state.db" apply --force </dev/null 2>&1
  }

  out=$(apply) || { echo "first apply failed: $(printf '%s' "$out" | head -n 3 | tr '\n' ' ')"; return 1; }

  want=$(expected_files "$name" | LC_ALL=C sort)
  got=$(cd "$home/.agents/skills/$name" 2>/dev/null && find . -type f | sed 's|^\./||' | LC_ALL=C sort)
  [ "$got" = "$want" ] || { echo "file set differs: got [$(echo $got)] want [$(echo $want)]"; return 1; }

  : > "$home/.agents/skills/$name/stale.md"
  out=$(apply) || { echo "second apply failed: $(printf '%s' "$out" | head -n 3 | tr '\n' ' ')"; return 1; }
  [ ! -e "$home/.agents/skills/$name/stale.md" ] || { echo "stale file survived the second apply"; return 1; }

  [ "$(cat "$home/.agents/skills/basecamp/SKILL.md" 2>/dev/null)" = sentinel ] \
    || { echo "unmanaged sibling .agents/skills/basecamp was touched"; return 1; }
  [ "$(cat "$home/.claude/skills/cross-review/SKILL.md" 2>/dev/null)" = sentinel ] \
    || { echo "real .claude/skills/cross-review was touched"; return 1; }

  [ "$(readlink "$home/.claude/skills/$name" 2>/dev/null)" = "../../.agents/skills/$name" ] \
    || { echo "readlink .claude/skills/$name is '$(readlink "$home/.claude/skills/$name" 2>/dev/null)', want ../../.agents/skills/$name"; return 1; }
  [ -r "$home/.claude/skills/$name/SKILL.md" ] \
    || { echo ".claude/skills/$name/SKILL.md is not readable through the link"; return 1; }
  return 0
}

# --- the cases -----------------------------------------------------------------------------

IGNORE="$SRC/.chezmoiignore"
SYMDIR="$SRC/dot_claude/skills"

names=$(entries "$TOML")
if [ -z "$names" ]; then
  _fail "entries in .chezmoiexternal.toml" "no [\".agents/skills/<name>\"] entry found"
fi

# mutate <name> <sed-script> — a copy of the production TOML, edited; prints its path.
# Fails (a FAIL case, not a silent pass) if the edit changed nothing.
mutate() {
  local out
  out=$(mktemp "$T/mut.XXXXXX")
  sed "$2" "$TOML" > "$out"
  if cmp -s "$TOML" "$out"; then echo "mutation changed nothing: $2" >&2; return 1; fi
  echo "$out"
}

# set_key <name> <key> <value> — a copy of the production TOML with <name>'s `key = …`
# replaced by `key = <value>`, including a value that spans several lines (an array
# continued until its closing bracket); prints its path. Fails if nothing changed.
set_key() {
  local out
  out=$(mktemp "$T/mut.XXXXXX")
  awk -v h="[\".agents/skills/$1\"]" -v key="$2" -v val="$3" '
    /^\[/ { sec = ($0 == h); skip = 0 }
    skip { if ($0 ~ /\]/) skip = 0; next }
    sec && $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
      print "    " key " = " val
      if ($0 ~ /\[/ && $0 !~ /\]/) skip = 1
      next
    }
    { print }
  ' "$TOML" > "$out"
  if cmp -s "$TOML" "$out"; then echo "set_key changed nothing: $2" >&2; return 1; fi
  echo "$out"
}

# expect_static <label> <reason-regex> <toml> <name> — static_ok must fail, and its reason
# must match the regex; failing for any other reason is a FAIL.
expect_static() {
  local label="$1" re="$2" r
  if r=$(static_ok "$3" "$4"); then _fail "$label" "static_ok accepted it"
  elif printf '%s' "$r" | grep -Eq "$re"; then _pass "$label"
  else _fail "$label" "failed for the wrong reason: $r"; fi
}

# expect_behaviour <label> <reason-regex> <toml> <ignore> <symdir> <name> — behaviour_ok must
# fail at the named check, not for an incidental reason such as an invalid TOML.
expect_behaviour() {
  local label="$1" re="$2" r
  if r=$(behaviour_ok "$3" "$4" "$5" "$6"); then _fail "$label" "behaviour_ok accepted it"
  elif printf '%s' "$r" | grep -Eq "$re"; then _pass "$label"
  else _fail "$label" "failed for the wrong reason: $r"; fi
}

for name in $names; do
  echo "== $name"

  if r=$(static_ok "$TOML" "$name"); then _pass "$name: static checks on the production entry"
  else _fail "$name: static checks on the production entry" "$r"; fi

  if r=$(behaviour_ok "$TOML" "$IGNORE" "$SYMDIR" "$name"); then
    _pass "$name: behaviour of the production entry"
  else _fail "$name: behaviour of the production entry" "$r"; fi

  # negative, static: each must fail at its own field
  if m=$(set_key "$name" type '"file"'); then
    expect_static "$name: a non-archive type is rejected" '^type is' "$m" "$name"
  else _fail "$name: a non-archive type is rejected" "could not build the mutation"; fi

  if m=$(mutate "$name" 's|\(/archive/\)[0-9a-f]\{40\}\.tar\.gz|\1main.tar.gz|'); then
    expect_static "$name: a branch URL is rejected" '^url is not' "$m" "$name"
  else _fail "$name: a branch URL is rejected" "could not build the mutation"; fi

  if m=$(mutate "$name" '/^[[:space:]]*url[[:space:]]*=/a\
    refreshPeriod = "168h"
'); then
    expect_static "$name: a refreshPeriod is rejected" '^refreshPeriod is set' "$m" "$name"
  else _fail "$name: a refreshPeriod is rejected" "could not build the mutation"; fi

  # negative, behaviour: each must fail at its own check
  if m=$(set_key "$name" include '["*/LICENSE"]'); then
    expect_behaviour "$name: an incomplete include is caught" '^file set differs' "$m" "$IGNORE" "$SYMDIR" "$name"
  else _fail "$name: an incomplete include is caught" "could not build the mutation"; fi

  if m=$(set_key "$name" include '["**"]'); then
    expect_behaviour "$name: an overbroad include is caught" '^file set differs' "$m" "$IGNORE" "$SYMDIR" "$name"
  else _fail "$name: an overbroad include is caught" "could not build the mutation"; fi

  if m=$(mutate "$name" '/^[[:space:]]*exact[[:space:]]*=/d'); then
    expect_behaviour "$name: a missing exact = true is caught" '^stale file survived' "$m" "$IGNORE" "$SYMDIR" "$name"
  else _fail "$name: a missing exact = true is caught" "could not build the mutation"; fi

  nosym=$(mktemp -d "$T/nosym.XXXXXX")
  expect_behaviour "$name: a missing symlink is caught" '^readlink ' "$TOML" "$IGNORE" "$nosym" "$name"

  noreinc=$(mktemp "$T/ignore.XXXXXX")
  grep -vxF "!.claude/skills/$name" "$IGNORE" > "$noreinc"
  if cmp -s "$IGNORE" "$noreinc"; then
    _fail "$name: a missing re-include is caught" "the production .chezmoiignore has no !.claude/skills/$name line to delete"
  else
    expect_behaviour "$name: a missing re-include is caught" '^readlink ' "$TOML" "$noreinc" "$SYMDIR" "$name"
  fi
done

echo; echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
