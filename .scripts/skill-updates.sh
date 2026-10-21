#!/usr/bin/env bash
# Compare each pinned agent skill in .chezmoiexternal.toml with its upstream's latest GitHub
# release, and optionally file deduplicated `skill-update` issues. Read-only without
# --open-issues. Bash 3.2 compatible; uses gh's --jq, so there is no jq dependency.
#
# Usage: skill-updates.sh [--open-issues] [--externals PATH]
#   PATH defaults to <script dir>/../.chezmoiexternal.toml. Only [".agents/skills/<name>"]
#   entries are read; any other header that mentions .agents/skills/ is an unparseable entry.
#   gh runs from the script's own checkout (the script cds to its repository root), so
#   --open-issues acts on the dotfiles remote whatever the caller's cwd, unless GH_REPO says
#   otherwise. Owner, repo and the pinned SHA come from the archive URL; the pinned
#   label is the `# vX` comment directly above `url`, else the first 7 characters of the SHA.
#
# CONTRACT: stdout carries ONLY one line per resolved skill:
#   current: <name> <pinned label>
#   update: <name> <pinned label> → <new label> https://github.com/<o>/<r>/compare/<old>...<new>
# Every diagnostic goes to stderr, prefixed `skill-updates: `. A skill that fails to resolve
# or validate gets neither line; an error is never reported as `current:`.
#
# Latest = releases/latest tag, resolved to its commit (peels annotated tags). A repo with no
# releases (`HTTP 404` on stderr) falls back to the HEAD commit, labelled by its 7-char SHA.
# Every gh answer is validated: a commit is 40 lowercase hex, a tag is non-empty with no
# whitespace.
#
# Exit, default mode:
#   0 -> every pin is current
#   1 -> at least one update exists (and no error)
#   2 -> any error: no gh, a gh failure other than the 404 fallback, an answer that fails
#        validation, an unparseable entry, zero entries, an unknown option
# --open-issues: for each update, create `Skill update: <name> <new label>` (label
#   skill-update) unless an open issue has that exact title. With no updates it makes no
#   label or issue call. If the label or the list call fails it creates nothing, because it
#   cannot dedupe. Exit 0 when every update has an open issue (or there are none), 2 if any
#   lookup, label, list or create call failed. Skills that resolved still get their issue.
set -u

log() { printf 'skill-updates: %s\n' "$*" >&2; }

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EXTERNALS="$REPO_ROOT/.chezmoiexternal.toml"
OPEN_ISSUES=0
while [ $# -gt 0 ]; do
  case "$1" in
    --open-issues) OPEN_ISSUES=1 ;;
    --externals)
      [ $# -ge 2 ] || { log "--externals needs a path"; exit 2; }
      EXTERNALS=$2; shift ;;
    *) log "unknown option: $1"; exit 2 ;;
  esac
  shift
done

command -v gh >/dev/null 2>&1 || { log "gh not found on PATH"; exit 2; }
case $EXTERNALS in /*) ;; *) EXTERNALS="$PWD/$EXTERNALS" ;; esac
[ -f "$EXTERNALS" ] || { log "externals file not found: $EXTERNALS"; exit 2; }
cd "$REPO_ROOT" || { log "cannot enter $REPO_ROOT"; exit 2; }

ERRF=$(mktemp "${TMPDIR:-/tmp}/skill-updates.XXXXXX") || { log "cannot create a temp file"; exit 2; }
trap 'rm -f "$ERRF"' EXIT

# gh_get <gh args...> -> G_OUT (stdout), G_ERR (stderr), G_RC. Stdout and stderr stay apart
# because a 404 prints its JSON body on stdout and the status text on stderr.
gh_get() {
  G_OUT=$(gh "$@" 2>"$ERRF" </dev/null); G_RC=$?
  G_ERR=$(cat "$ERRF")
}

SHA_RE='^[0-9a-f]{40}$'
URL_RE='^https://github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/archive/([0-9a-f]{40})\.tar\.gz$'
valid_sha() { [[ $1 =~ $SHA_RE ]]; }
valid_tag() { [ -n "$1" ] && [ "$1" != "null" ] && [[ $1 =~ ^[^[:space:]|]+$ ]]; }

ERRORS=0
ANY_UPDATE=0
UPDATES=""   # newline-separated name|pinned label|new label|compare URL

check_entry() {  # check_entry <name> <tag label or empty> <url>
  local name=$1 label=$2 url=$3 owner repo pin newsha newlabel tag
  if ! [[ $url =~ $URL_RE ]]; then
    log "$name: not a GitHub archive URL: ${url:-(no url)}"; ERRORS=1; return
  fi
  owner=${BASH_REMATCH[1]}; repo=${BASH_REMATCH[2]}; pin=${BASH_REMATCH[3]}
  [ -n "$label" ] || label=${pin:0:7}

  gh_get api "repos/$owner/$repo/releases/latest" --jq .tag_name
  if [ "$G_RC" -eq 0 ]; then
    tag=$G_OUT
    if ! valid_tag "$tag"; then
      log "$name: invalid release tag from gh: '$tag'"; ERRORS=1; return
    fi
    gh_get api "repos/$owner/$repo/commits/$tag" --jq .sha
    if [ "$G_RC" -ne 0 ]; then
      log "$name: commit lookup for $tag failed: $G_ERR"; ERRORS=1; return
    fi
    newsha=$G_OUT; newlabel=$tag
  else
    case $G_ERR in
      *"HTTP 404"*)
        gh_get api "repos/$owner/$repo/commits/HEAD" --jq .sha
        if [ "$G_RC" -ne 0 ]; then
          log "$name: HEAD lookup failed: $G_ERR"; ERRORS=1; return
        fi
        newsha=$G_OUT; newlabel=${newsha:0:7} ;;
      *)
        log "$name: release lookup failed: $G_ERR"; ERRORS=1; return ;;
    esac
  fi
  if ! valid_sha "$newsha"; then
    log "$name: invalid commit from gh: '$newsha'"; ERRORS=1; return
  fi

  if [ "$newsha" = "$pin" ]; then
    printf 'current: %s %s\n' "$name" "$label"
  else
    local compare="https://github.com/$owner/$repo/compare/$pin...$newsha"
    printf 'update: %s %s → %s %s\n' "$name" "$label" "$newlabel" "$compare"
    ANY_UPDATE=1
    UPDATES="${UPDATES}${name}|${label}|${newlabel}|${compare}
"
  fi
}

# Entry lines: name|tag comment (or empty)|url (or empty when the entry has none).
ENTRIES=$(awk '
  function emit_missing() { if (name != "" && !done) printf "%s||\n", name }
  /^[ \t]*\[/ {
    emit_missing(); name = ""; done = 0; cmt = ""
    if ($0 ~ /^\[".agents\/skills\/[A-Za-z0-9_.-]+"\][ \t]*$/) {
      s = $0
      sub(/^\[".agents\/skills\//, "", s); sub(/"\][ \t]*$/, "", s)
      name = s
    } else if (index($0, ".agents/skills/") > 0) {
      b = $0; gsub(/\|/, "_", b); printf "!bad|%s|\n", b
    }
    next
  }
  name == "" { next }
  /^[ \t]*#/ { c = $0; sub(/^[ \t]*#[ \t]*/, "", c); sub(/[ \t]+$/, "", c); cmt = c; next }
  /^[ \t]*url[ \t]*=/ {
    u = $0; sub(/^[ \t]*url[ \t]*=[ \t]*"/, "", u); sub(/".*$/, "", u)
    l = (cmt ~ /^v[0-9][^ \t|]*$/) ? cmt : ""
    printf "%s|%s|%s\n", name, l, u
    done = 1; cmt = ""; next
  }
  { cmt = "" }
  END { emit_missing() }
' "$EXTERNALS")

if [ -z "$ENTRIES" ]; then
  log "no .agents/skills entries found in $EXTERNALS"; exit 2
fi

while IFS='|' read -r e_name e_label e_url; do
  [ -n "$e_name" ] || continue
  if [ "$e_name" = "!bad" ]; then
    log "unparseable entry header: $e_label"; ERRORS=1; continue
  fi
  check_entry "$e_name" "$e_label" "$e_url"
done <<EOF
$ENTRIES
EOF

issue_body() {  # issue_body <name> <old label> <new label> <compare URL>
  printf '%s has a newer upstream release: %s → %s.\n\n' "$1" "$2" "$3"
  printf 'Compare: %s\n\n' "$4"
  printf '%s\n' '- [ ] Read the diff, especially SKILL.md, references/ and every script.'
  printf '%s\n' '- [ ] On a branch, change the SHA and its tag comment in .chezmoiexternal.toml; put `Closes #<this issue>` in the commit message.'
  printf '%s\n' "- [ ] Warm chezmoi's cache outside the sandbox: \`command chezmoi --source <checkout> managed >/dev/null\`."
  printf '%s\n' "- [ ] Confirm \`command chezmoi --source <checkout> managed\` lists \`.agents/skills/$1/SKILL.md\`."
  printf '%s\n' '- [ ] After merge: `chezmoi apply`.'
}

if [ "$OPEN_ISSUES" -eq 1 ]; then
  if [ -n "$UPDATES" ]; then
    gh_get label create skill-update --color 0E8A16 \
      --description "A pinned agent skill has a newer upstream release" --force
    if [ "$G_RC" -ne 0 ]; then
      log "label create failed, creating no issues: $G_ERR"; ERRORS=1
    else
      gh_get issue list --label skill-update --state open --limit 200 --json title --jq '.[].title'
      if [ "$G_RC" -ne 0 ]; then
        log "issue list failed, creating no issues: $G_ERR"; ERRORS=1
      else
        EXISTING=$G_OUT
        while IFS='|' read -r u_name u_old u_new u_compare; do
          [ -n "$u_name" ] || continue
          title="Skill update: $u_name $u_new"
          if printf '%s\n' "$EXISTING" | grep -Fxq -- "$title"; then
            log "$title: open issue exists"
            continue
          fi
          body=$(issue_body "$u_name" "$u_old" "$u_new" "$u_compare")
          gh_get issue create --title "$title" --label skill-update --body "$body"
          if [ "$G_RC" -ne 0 ]; then
            log "$title: issue create failed: $G_ERR"; ERRORS=1
          else
            log "$title: issue created ${G_OUT}"
          fi
        done <<EOF
$UPDATES
EOF
      fi
    fi
  fi
  [ "$ERRORS" -eq 0 ] && exit 0
  exit 2
fi

[ "$ERRORS" -ne 0 ] && exit 2
[ "$ANY_UPDATE" -eq 1 ] && exit 1
exit 0
