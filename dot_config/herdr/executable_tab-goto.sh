#!/usr/bin/env zsh
# tab-goto.sh <label> — focus a managed tab in the active workspace.
# Managed by chezmoi (source: dot_config/herdr/executable_tab-goto.sh).
#
# By LABEL, never by index. herdr 0.8.2 has no `tab move`, so repair can only append
# and a repaired workspace's managed tabs can end up in any order; the user's own
# alt+t tab also shifts every position after it. An index would silently land on the
# wrong tab, which is worse than not moving at all.
emulate -L zsh
setopt local_options no_unset pipe_fail

label="${1:-}"
[[ -n "$label" ]] || { print -ru2 -- "tab-goto: usage: tab-goto.sh <label>"; exit 1 }

# Resolving through the globally-focused workspace is racy: persistence is a shared
# session view, so another attached client can change focus between the keypress and
# the query. Herdr documents active-context variables for [[keys.command]]; if none
# is present, say so rather than guessing at a workspace.
ws="${HERDR_ACTIVE_WORKSPACE_ID:-${HERDR_WORKSPACE_ID:-}}"
[[ -n "$ws" ]] || {
  print -ru2 -- "tab-goto: no active workspace in the environment."
  print -ru2 -- "    Expected HERDR_ACTIVE_WORKSPACE_ID from the keybinding context."
  exit 1 }

tabs="$(command herdr tab list --workspace "$ws" 2>&1)" || {
  print -ru2 -- "tab-goto: tab list failed: $tabs"; exit 1 }

# Same boundary discipline as layout.sh: an empty or malformed response must not
# become a jump. jq exits 0 on empty input, so without this an empty response reads
# as "no tab labelled X" — a misleading message for what is really an API failure.
[[ -n "$tabs" ]] || { print -ru2 -- "tab-goto: herdr returned an empty response"; exit 1 }
print -r -- "$tabs" | jq -e . >/dev/null 2>&1 \
  || { print -ru2 -- "tab-goto: herdr returned invalid JSON"; exit 1 }
print -r -- "$tabs" | jq -e 'type == "object" and has("error")' >/dev/null 2>&1 \
  && { print -ru2 -- "tab-goto: herdr returned an error: $tabs"; exit 1 }

matched="$(print -r -- "$tabs" | jq -r --arg l "$label" \
            '.result.tabs[] | select(.label == $l) | .tab_id')" \
  || { print -ru2 -- "tab-goto: could not read tab ids"; exit 1 }

ids=( ${(f)matched} )
ids=( ${ids:#} )

(( ${#ids} == 0 )) && { print -ru2 -- "tab-goto: no tab labelled '$label'"; exit 1 }
(( ${#ids} > 1 ))  && {
  print -ru2 -- "tab-goto: ${#ids} tabs labelled '$label' — refusing to guess"; exit 1 }

command herdr tab focus "${ids[1]}" >/dev/null
