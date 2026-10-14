#!/usr/bin/env zsh
# clear-pane.sh — Cmd-k inside Herdr. Ghostty sends Alt-k, and a [[keys.command]] runs this.
# Managed by chezmoi (source: dot_config/herdr/executable_clear-pane.sh).
#
# Herdr's own clear_pane keeps only the cursor's row, which cuts the top line off the
# two-line prompt. So at an idle zsh prompt the key goes to zsh instead, whose Alt-k
# widget (dot_zshrc) clears the screen and scrollback and redraws the whole prompt, as in
# a bare Ghostty tab. Anything else in the foreground (Neovim, an agent, ssh) gets
# nothing: LazyVim binds <A-k> to "move line up", so passing the key on would edit a file.
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
print -r -- "$info" | jq -e '.result.process_info | .shell_pid as $sh
  | .foreground_process_group_id == $sh
    and any(.foreground_processes[]?; .pid == $sh and .name == "zsh")' >/dev/null 2>&1 \
  || exit 0

"${HL_HERDR[@]}" pane send-keys "$pane" alt+k >/dev/null 2>&1
