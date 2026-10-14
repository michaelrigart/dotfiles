#!/usr/bin/env zsh
# clear-pane.sh — Cmd-k inside Herdr. Ghostty sends Alt-k, and a [[keys.command]] runs this.
# Managed by chezmoi (source: dot_config/herdr/executable_clear-pane.sh).
#
# Herdr's own clear_pane keeps only the cursor's row, which cuts the top line off the
# two-line prompt. So an idle zsh clears itself instead: its SIGURG trap (dot_zshrc) runs
# the Alt-k widget, which clears the screen and scrollback and redraws the whole prompt, as
# in a bare Ghostty tab.
#
# A signal, not a key typed into the pane: this runs detached, so by the time a key arrived
# the shell could have started something else (Cmd-k, then Enter on `nvim`), and LazyVim
# binds <A-k> to "move line up". The signal reaches only the shell, which acts on it only
# while its line editor is active. SIGURG is ignored by default, so it harms nothing else.
emulate -L zsh
setopt local_options no_unset pipe_fail

# Same session threading as layout.sh and tab-goto.sh.
typeset -ga HL_HERDR=(command herdr)
[[ -n "${HERDR_SESSION:-}" ]] && HL_HERDR+=(--session "$HERDR_SESSION")

pane="${HERDR_ACTIVE_PANE_ID:-}"
[[ -n "$pane" ]] || exit 0

# Idle at the prompt: the pane's shell leads the foreground process group, and it is zsh.
# The CLI answers some failures with an error envelope at exit status 0, which has no
# process_info, so jq -e fails on it too.
info="$("${HL_HERDR[@]}" pane process-info --pane "$pane" 2>/dev/null)" || exit 0
shell_pid="$(print -r -- "$info" | jq -er '.result.process_info | .shell_pid as $sh
  | select(.foreground_process_group_id == $sh
      and any(.foreground_processes[]?; .pid == $sh and .name == "zsh"))
  | $sh' 2>/dev/null)" || exit 0
[[ "$shell_pid" == <1-> ]] || exit 0

kill -URG "$shell_pid" 2>/dev/null
