#!/usr/bin/env bash
# reconcile-agents.sh — declare + install Claude Code and Codex marketplaces/plugins.
#
# Source of truth: ~/.config/agents/plugins.conf (deployed by chezmoi).
# Idempotent and add-only: queries current state, installs only what is missing,
# never uninstalls, and respects deliberately-disabled plugins.
# MCP servers (claude_mcp) are the exception: a server whose entry differs from the
# declaration is replaced, because the declaration is the whole definition and a
# hand-made entry is what carries the token.
#
# Bash 3.2 compatible (macOS /bin/bash): no associative arrays, mapfile, or ${x,,}.
# Exit status: 0 = every declared item is present/added; 1 = something could not be
# reconciled (tool/jq absent, list query failed or returned an unexpected shape,
# add/install failed, MCP remove/add failed, manifest error). A failed query never means
# "none installed": only a valid empty response ([]) does.
# provision.sh wraps the call with `|| log_warn`, so a non-zero exit stays non-fatal
# there while remaining truthful for manual/automated callers.

set -f  # no pathname expansion — manifest values are never globs

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; NC=$'\033[0m'
log_info() { echo "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo "${RED}[ERROR]${NC} $1"; }

status=0
MANIFEST="${XDG_CONFIG_HOME:-$HOME/.config}/agents/plugins.conf"

# Codex marketplaces whose plugins are provided by Codex itself — never flagged as drift.
CODEX_SYSTEM_MKTS="openai-bundled openai-primary-runtime openai-curated"

# Deduplicated declaration lists.
claude_mkts=(); claude_plugins=(); claude_mcps=(); codex_mkts=(); codex_plugins=()

# in_list <needle> <item>...  -> 0 if needle is among the items
in_list() {
  local needle=$1; shift
  local x
  for x in "$@"; do [ "$x" = "$needle" ] && return 0; done
  return 1
}

# valid_mcp_name <name> -> 0 if the name is ASCII [A-Za-z0-9._-]+ and starts with neither
# "." nor "-" (a leading "-" would reach `claude mcp` as an option). The C locale keeps
# the character ranges ASCII-only whatever the caller's LC_ALL.
valid_mcp_name() {
  ( LC_ALL=C
    re='^[A-Za-z0-9._-]+$'
    [[ $1 =~ $re ]] && case "$1" in .*|-*) false ;; *) true ;; esac )
}

# normalize_gh <source> -> echoes owner/repo for a GitHub URL, empty otherwise
normalize_gh() {
  local s=$1
  case "$s" in
    https://github.com/*)   s=${s#https://github.com/} ;;
    http://github.com/*)    s=${s#http://github.com/} ;;
    ssh://git@github.com/*) s=${s#ssh://git@github.com/} ;;
    git@github.com:*)       s=${s#git@github.com:} ;;
    *) echo ""; return ;;
  esac
  echo "${s%.git}"
}

# ---------------------------------------------------------------------------
# Parse the manifest into deduplicated lists.
# ---------------------------------------------------------------------------
parse_manifest() {
  if [ ! -r "$MANIFEST" ]; then
    log_warn "manifest not readable: $MANIFEST"
    status=1
    return
  fi
  local lineno=0 raw line kind value
  while IFS= read -r raw || [ -n "$raw" ]; do
    lineno=$((lineno + 1))
    line=${raw%%#*}            # strip inline/full-line comment
    # shellcheck disable=SC2086  # intentional field split; set -f above prevents globbing
    set -- $line               # word-split; ignores leading/trailing whitespace
    [ $# -eq 0 ] && continue   # blank or comment-only
    if [ $# -ne 2 ]; then
      log_warn "manifest line $lineno: expected 2 fields, got $# — skipped"
      status=1; continue
    fi
    kind=$1; value=$2
    case "$kind" in
      claude_marketplace)
        in_list "$value" "${claude_mkts[@]}" && { log_warn "duplicate: $kind $value"; continue; }
        claude_mkts+=("$value") ;;
      claude_plugin)
        in_list "$value" "${claude_plugins[@]}" && { log_warn "duplicate: $kind $value"; continue; }
        claude_plugins+=("$value") ;;
      claude_mcp)
        if ! valid_mcp_name "$value"; then
          log_warn "manifest line $lineno: invalid claude_mcp name '$value' — skipped"
          status=1; continue
        fi
        in_list "$value" "${claude_mcps[@]}" && { log_warn "duplicate: $kind $value"; continue; }
        claude_mcps+=("$value") ;;
      codex_marketplace)
        in_list "$value" "${codex_mkts[@]}" && { log_warn "duplicate: $kind $value"; continue; }
        codex_mkts+=("$value") ;;
      codex_plugin)
        in_list "$value" "${codex_plugins[@]}" && { log_warn "duplicate: $kind $value"; continue; }
        codex_plugins+=("$value") ;;
      *)
        log_warn "manifest line $lineno: unknown kind '$kind' — skipped"
        status=1 ;;
    esac
  done < "$MANIFEST"
}

# run_json <outvar> <errmsg-prefix> <cmd...>  -> capture stdout JSON (stderr kept out of
# it). On failure, re-run to surface a concise stderr line (these are read-only list
# commands, safe to call twice) and set status=1. Returns non-zero on failure.
run_json() {
  local __out=$1 __prefix=$2; shift 2
  local __data __rc __err
  __data=$("$@" 2>/dev/null); __rc=$?
  if [ $__rc -ne 0 ]; then
    __err=$("$@" 2>&1 1>/dev/null | head -n 1)
    log_warn "$__prefix failed: $__err"
    status=1; return 1
  fi
  printf -v "$__out" '%s' "$__data"
  return 0
}

# project <json> <schema-check> <jq-filter> <outvar> <label>  -> validate the response
# against an explicit schema (container type + required field types) BEFORE projecting,
# then set outvar to the projection. Returns non-zero (warns, status=1) on schema failure
# so the caller skips that block instead of re-adding everything.
#
# jq's exit status alone is NOT enough: empty stdout, {}, and [{}] all let a projection
# exit 0 with an empty result, which would make the reconciler treat every declared item
# as missing. The schema check rejects those while still passing a valid-but-empty
# response ([] or {"installed":[]}), which reconciles normally.
project() {
  local __json=$1 __schema=$2 __filter=$3 __outvar=$4 __label=$5 __data
  # Exactly one top-level JSON value first: given several, jq -e reports only the LAST
  # result's truthiness, so "{}\n[]" would pass a schema that rejects {}.
  if ! printf '%s' "$__json" | jq -e -s 'length == 1' >/dev/null 2>&1 \
     || ! printf '%s' "$__json" | jq -e "$__schema" >/dev/null 2>&1; then
    log_warn "$__label: unexpected JSON shape — skipping"
    status=1; return 1
  fi
  __data=$(printf '%s' "$__json" | jq -r "$__filter" 2>/dev/null) || {
    log_warn "$__label: projection failed — skipping"; status=1; return 1
  }
  printf -v "$__outvar" '%s' "$__data"
  return 0
}

# ---------------------------------------------------------------------------
# Claude
# ---------------------------------------------------------------------------

# MCP servers, user scope. Each name is a launcher at $HOME/.local/bin/<name> that
# holds its own credentials, so the registered definition never carries any. An
# existing entry is read only to compare; its content is never printed.
reconcile_claude_mcp() {
  [ "${#claude_mcps[@]}" -eq 0 ] && return
  local cfg="$HOME/.claude.json" name cmd json state
  if [ -e "$cfg" ] && ! jq -e 'type == "object"' "$cfg" >/dev/null 2>&1; then
    log_warn "claude mcp: $cfg is not a JSON object — skipping MCP reconcile"
    status=1; return
  fi
  for name in "${claude_mcps[@]}"; do
    cmd="$HOME/.local/bin/$name"
    [ -x "$cmd" ] || log_warn "launcher not found: $cmd"
    json=$(jq -nc --arg c "$cmd" '{type:"stdio",command:$c,args:[],env:{}}') || {
      log_warn "claude mcp: could not build definition for $name"; status=1; continue
    }
    state=absent
    if [ -e "$cfg" ]; then
      state=$(jq -r --arg n "$name" --arg c "$cmd" '
        (.mcpServers // {}) as $m
        | if ($m | type) != "object" or ($m | has($n) | not) then "absent"
          elif ($m[$n] | type == "object"
                and (.type // "stdio") == "stdio" and .command == $c
                and (.args // []) == [] and (.env // {}) == {}) then "match"
          else "differs" end' "$cfg" 2>/dev/null) || {
        log_warn "claude mcp: could not read $cfg — skipping $name"; status=1; continue
      }
    fi
    case "$state" in
      match)
        log_info "claude mcp present: $name"; continue ;;
      differs)
        log_info "claude mcp replace: $name"
        claude mcp remove "$name" --scope user || {
          log_warn "failed to remove claude mcp: $name"; status=1; continue
        } ;;
      *) log_info "claude mcp add: $name" ;;
    esac
    claude mcp add-json "$name" "$json" --scope user || { log_warn "failed to add claude mcp: $name"; status=1; }
  done
}

reconcile_claude() {
  if ! command -v claude >/dev/null 2>&1; then
    log_warn "claude not found — skipping Claude reconcile (re-run after install/login)"
    status=1; return
  fi

  # Marketplaces (query once, add missing) — must precede plugin install.
  local json have repo
  # Entries without a .repo (non-GitHub sources) are valid and simply project to nothing.
  if run_json json "claude plugin marketplace list" claude plugin marketplace list --json \
     && project "$json" \
          '(type=="array") and all(.[]; type=="object" and has("name") and (.name|type=="string") and ((has("repo")|not) or .repo == null or (.repo|type=="string")))' \
          '.[] | .repo // empty' have "claude marketplace list"; then
    for repo in "${claude_mkts[@]}"; do
      if printf '%s\n' "$have" | grep -qxF "$repo"; then
        log_info "claude marketplace present: $repo"
      else
        log_info "claude marketplace add: $repo"
        claude plugin marketplace add "$repo" || { log_warn "failed to add claude marketplace: $repo"; status=1; }
      fi
    done
  fi

  # Plugins (query once, AFTER marketplace adds). Projection: "<id>\t<enabled>", user scope.
  local proj id enabled line
  if run_json json "claude plugin list" claude plugin list --json \
     && project "$json" \
          '(type=="array") and all(.[]; type=="object" and (.id|type=="string") and (.scope|type=="string") and (.enabled|type=="boolean"))' \
          '.[] | select(.scope=="user") | "\(.id)\t\(.enabled)"' proj "claude plugin list"; then
    # Install missing / report disabled. Exact match on field 1 (an id can be a substring
    # of another, e.g. code-review vs xcode-review), so awk on the tab-delimited field.
    for id in "${claude_plugins[@]}"; do
      line=$(printf '%s\n' "$proj" | awk -F '\t' -v id="$id" '$1 == id { print; exit }')
      if [ -n "$line" ]; then
        enabled=${line#*	}
        if [ "$enabled" = "false" ]; then
          log_info "claude plugin disabled (left as-is): $id"
        else
          log_info "claude plugin present: $id"
        fi
      else
        log_info "claude plugin install: $id"
        claude plugin install "$id" --scope user || { log_warn "failed to install claude plugin: $id"; status=1; }
      fi
    done
    # Drift: installed user-scope plugins not declared.
    while IFS=$'\t' read -r id enabled; do
      [ -z "$id" ] && continue
      in_list "$id" "${claude_plugins[@]}" || log_info "claude drift (undeclared, left as-is): $id"
    done <<EOF
$proj
EOF
  fi

  reconcile_claude_mcp
}

# ---------------------------------------------------------------------------
# Codex
# ---------------------------------------------------------------------------
reconcile_codex() {
  if ! command -v codex >/dev/null 2>&1; then
    log_warn "codex not found — skipping Codex reconcile (re-run after install/login)"
    status=1; return
  fi

  # Marketplaces (query once, add missing) — normalized exact match on GitHub source.
  local json src norm repo srcs
  local have_norm=()
  if run_json json "codex plugin marketplace list" codex plugin marketplace list --json \
     && project "$json" \
          '(type=="object") and has("marketplaces") and (.marketplaces|type=="array")' \
          '.marketplaces[].marketplaceSource.source // empty' srcs "codex marketplace list"; then
    while IFS= read -r src; do
      [ -z "$src" ] && continue
      norm=$(normalize_gh "$src")
      [ -n "$norm" ] && have_norm+=("$norm")
    done <<EOF
$srcs
EOF
    for repo in "${codex_mkts[@]}"; do
      if in_list "$repo" "${have_norm[@]}"; then
        log_info "codex marketplace present: $repo"
      else
        log_info "codex marketplace add: $repo"
        codex plugin marketplace add "$repo" || { log_warn "failed to add codex marketplace: $repo"; status=1; }
      fi
    done
  fi

  # Plugins (query once, AFTER marketplace adds). Projection: "<pluginId>\t<enabled>\t<marketplace>".
  local proj pid enabled mkt line
  if run_json json "codex plugin list" codex plugin list --json \
     && project "$json" \
          '(type=="object") and has("installed") and (.installed|type=="array") and all(.installed[]; has("pluginId") and (.pluginId|type=="string"))' \
          '.installed[] | "\(.pluginId)\t\(.enabled)\t\(.marketplaceName)"' proj "codex plugin list"; then
    for pid in "${codex_plugins[@]}"; do
      line=$(printf '%s\n' "$proj" | awk -F '\t' -v id="$pid" '$1 == id { print; exit }')
      if [ -n "$line" ]; then
        enabled=${line#*	}; enabled=${enabled%%	*}
        if [ "$enabled" = "false" ]; then
          log_info "codex plugin disabled (left as-is): $pid"
        else
          log_info "codex plugin present: $pid"
        fi
      else
        log_info "codex plugin add: $pid"
        codex plugin add "$pid" || { log_warn "failed to add codex plugin: $pid"; status=1; }
      fi
    done
    # Drift: installed plugins not declared, excluding Codex system marketplaces.
    while IFS=$'\t' read -r pid enabled mkt; do
      [ -z "$pid" ] && continue
      # shellcheck disable=SC2086  # intentional split of the space-separated system-mkt list
      in_list "$mkt" $CODEX_SYSTEM_MKTS && continue
      in_list "$pid" "${codex_plugins[@]}" || log_info "codex drift (undeclared, left as-is): $pid"
    done <<EOF
$proj
EOF
  fi
}

# ---------------------------------------------------------------------------
main() {
  if ! command -v jq >/dev/null 2>&1; then
    log_error "jq not found — cannot parse plugin state. Install jq and re-run."
    exit 1
  fi
  log_info "Reconciling AI agent plugins from $MANIFEST"
  parse_manifest
  reconcile_claude
  reconcile_codex
  if [ "$status" -eq 0 ]; then
    log_info "Agent plugin reconcile complete — all declared items present."
  else
    log_warn "Agent plugin reconcile finished with issues (see warnings above)."
  fi
  exit "$status"
}

main "$@"
