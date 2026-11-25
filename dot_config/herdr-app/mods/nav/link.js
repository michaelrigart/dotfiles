// Cmd-click on path:line or path:line:col in a terminal: the file opens at that line in the
// Neovim of the space's editor tab, and that tab is shown; a space with no editor tab gets one, as
// Alt-E makes it, with Neovim started on the file at that line. Everything else passes to Herdr's
// own handling: a URL, a path without a line, a terminal on another machine, an editor tab with
// no Neovim, a path that is not a regular file.
//
// The clicked text is untrusted. It reaches a running Neovim only as a Vim string literal that
// Lua gets as data (_A), and a new one only as the file argument after "--", which Herdr's
// launcher passes whole ("$@"): never through an Ex command, which expands backticks and splits
// on spaces, nor a shell.

import { spaces, panes, run, exec } from "herdr";
import { vimIn, serverOf, editorStarting, makeEditor } from "./nvim.js";

// 1 when it opened the file, 0 when the path is not a readable regular file or the request came
// after its deadline. It opens in a normal window (not a float, a file tree or a terminal): the
// one already showing the file, else the current one, else the tab page's first. Then Neovim
// goes to normal mode, so the next keys do not edit the file or run a half-typed command there;
// that happens once this call returns, and leaving insert mode moves the cursor, so the keys set
// it again.
const OPEN = `(function(p, l, c, by)
  if os.time() > by then return 0 end
  local st = vim.uv.fs_stat(p)
  if not st or st.type ~= "file" or vim.fn.filereadable(p) ~= 1 then return 0 end
  local function normal(w)
    return vim.bo[vim.api.nvim_win_get_buf(w)].buftype == "" and vim.api.nvim_win_get_config(w).relative == ""
  end
  local buf = vim.fn.bufadd(p)
  vim.bo[buf].buflisted = true
  local win = vim.iter(vim.fn.win_findbuf(buf)):find(normal)
  if not win and not normal(0) then win = vim.iter(vim.api.nvim_tabpage_list_wins(0)):find(normal) end
  if win then vim.api.nvim_set_current_win(win) end
  if vim.api.nvim_get_current_buf() ~= buf then vim.api.nvim_win_set_buf(0, buf) end
  vim.fn.cursor(l, c)
  vim.api.nvim_feedkeys(vim.keycode(("<C-\\\\><C-N><Cmd>call cursor(%d, %d)<CR>"):format(l, c)), "n", false)
  return 1
end)(_A[1], _A[2], _A[3], _A[4])`;

// A single-quoted Vim string takes everything literally but its own quote, doubled.
const vimString = (s) => `'${s.replaceAll("'", "''")}'`;
// Exact, so it prints as digits alone: a new tab's Neovim gets it in an Ex command.
const count = (n) => (Number.isSafeInteger(n) && n > 0 ? n : null);
// A regular file (a link to one too), asked of a program, not a shell: a new Neovim on a folder,
// a FIFO or a device would show it or hang where Herdr's own handling does better.
const regular = async (p) => (await exec("test", ["-f", p], { timeout: 2000 }).catch(() => null))?.code === 0;

// Herdr gives the path it resolved; a relative one is taken from the clicked terminal's folder.
function absolute(path, cwd) {
  const p = path?.startsWith("/") ? path : path && cwd?.startsWith("/") ? `${cwd.replace(/\/+$/, "")}/${path}` : null;
  return p && !/[\x00-\x1f\x7f]/.test(p) ? p : null;
}

export async function handleLink({ link, source }) {
  const line = link.kind === "file" ? count(link.line) : null;
  const path = line && !source.machine ? absolute(link.path, source.cwd) : null;
  if (!path) return "pass";
  const space = spaces().find((s) => s.id === source.space);
  const column = count(link.column) ?? 1;
  const tab = space?.tabs?.find((t) => t.name === "editor");
  for (const p of tab ? panes().filter((x) => x.tab === tab.id && x.terminal) : []) {
    const pid = await vimIn(p.terminal);
    const server = pid ? await serverOf(pid) : null;
    if (!server) continue;
    // A busy Neovim (a prompt, a long command) still runs the request once it is free, after exec
    // has given up and Herdr has opened the file its own way: past the deadline it opens nothing.
    const by = Math.floor(Date.now() / 1000) + 3;
    const expr = `luaeval(${vimString(OPEN)}, [${vimString(path)}, ${line}, ${column}, ${by}])`;
    const r = await exec("nvim", ["--server", server, "--remote-expr", expr], { timeout: 10000 }).catch(() => null);
    if (r?.code !== 0 || r.stdout.trim() !== "1") return "pass";
    run("tab.select", { id: tab.id });
    run("pane.focus", { pane: p.pane });
    return "handled";
  }
  // No Neovim answered. An editor tab asked for moments ago (by this handler or Alt-E) is still
  // starting: the click is taken and dropped, so it neither makes a second tab nor goes to Herdr.
  // An older editor tab with no Neovim passes.
  if (!space || (tab && !editorStarting(space.id))) return "pass";
  if (!(await regular(path))) return "pass";
  if (!tab) makeEditor(space.id, space.folder || source.cwd, ["nvim", `+call cursor(${line}, ${column})`, "--", path]);
  return "handled";
}
