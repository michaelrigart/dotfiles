// The Neovim in a terminal and its server, for the movement keys (main.js) and the link
// handler (link.js); and the space's editor tab, which Alt-E (main.js) and a click make.

import { hc, exec, run } from "herdr";

// The process names vim-tmux-navigator and smart-splits treat as Vim.
const VIM = /^g?(view|l?n?vim?x?)(diff)?$/;
// Neovim 0.10+ runs its UI and its server as two processes: the server is the UI's child,
// and its socket is named after the server's pid.
const FIND = 'for k in "$1" $(pgrep -P "$1"); do for s in "${TMPDIR%/}"/nvim.$(id -un)/*/nvim."$k".0; do ' +
  '[ -S "$s" ] && { printf %s "$s"; exit 0; }; done; done; exit 1';

// The pid of the terminal's foreground program when it is Vim, else null.
export async function vimIn(terminal) {
  let t;
  try { t = JSON.parse((await hc(["get", terminal, "--json"])).stdout); } catch { return null; }
  const fg = t?.foreground;
  return fg && VIM.test(fg.name ?? "") ? fg.pid : null;
}

// The server socket of the Neovim whose UI has that pid, or null.
export async function serverOf(pid) {
  const r = await exec("sh", ["-c", FIND, "nav", String(pid)], { timeout: 2000 }).catch(() => null);
  return r?.code === 0 ? r.stdout : null;
}

// An editor tab asked for in a space less than 3 s ago may not show yet, nor its Neovim answer:
// asking again, by Alt-E or a click, must not make a second one. Kept in localStorage, which the
// link handler and this mod's view share.
const asked = (space) => `editor.asked.${space}`;
export function editorStarting(space) {
  let at = 0;
  try { at = Number(localStorage.getItem(asked(space))) || 0; } catch {}
  return Date.now() - at < 3000;
}

// Makes the space's editor tab, running argv in folder; false when one is still starting.
export function makeEditor(space, folder, argv) {
  if (editorStarting(space)) return false;
  try { localStorage.setItem(asked(space), String(Date.now())); } catch {}
  run("tab.new", { name: "editor", space, folder: folder || undefined, argv });
  return true;
}
