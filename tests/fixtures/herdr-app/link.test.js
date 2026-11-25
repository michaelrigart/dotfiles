// The nav mod's terminal link handler (mods/nav/link.js), run headless under jsc by
// tests/herdr-app-link.test.sh: ./link-stubs.js stands in for "herdr", ./env.js names the folder
// of files the suite made. What the handler decides is asserted here; every Neovim expression it
// would send is printed as a REPLAY line, which the suite sends to a real headless Neovim.
import { handleLink } from "./link.js";
import { world, calls } from "./link-stubs.js";
import { FILES, NAMES } from "./env.js";

const check = (what, ok) => print(`  ${ok ? "PASS" : "FAIL"}: ${what}`);

function reset() {
  calls.length = 0;
  world.spaces = [
    { id: "s1", name: "dots", machine: null, tabs: [{ id: "a1", name: "agents" }, { id: "e1", name: "editor" }] },
    { id: "s2", name: "other", machine: null, tabs: [{ id: "e2", name: "editor" }] },
  ];
  world.panes = [
    { pane: "pa", tab: "a1", terminal: "ta" },
    { pane: "pe", tab: "e1", terminal: "te" },
    { pane: "pf", tab: "e2", terminal: "tf" },
  ];
  world.foreground = { ta: { name: "zsh", pid: 10 }, te: { name: "nvim", pid: 20 }, tf: { name: "nvim", pid: 30 } };
  world.servers = { 20: "/sock/20", 30: "/sock/30" };
  world.nvim = () => ({ code: 0, stdout: "1\n", stderr: "" });
}
const from = (more = {}) => ({ terminal: "ta", machine: null, cwd: "/w", pane: "pa", tab: "a1", space: "s1", ...more });
const file = (path, line, column) => ({ kind: "file", raw: `${path}:${line}`, path, line, column });
const click = (link, source = from()) => handleLink({ link, source });
const nvimCalls = () => calls.filter(([k, c]) => k === "exec" && c === "nvim");
const runs = () => calls.filter(([k]) => k === "run").map(([, n, a]) => `${n} ${JSON.stringify(a)}`).join("; ");

// Every Neovim expression is replayed by the suite: `want` is what Neovim must answer, `check` an
// expression asked afterwards and `expect` its answer; `setup` runs first when given.
let replays = 0;
async function replay(what, link, source, want, check, expect, setup) {
  reset();
  await click(link, source);
  const sent = nvimCalls();
  if (sent.length !== 1) return print(`  FAIL: ${what}: the handler sent Neovim ${sent.length} expressions`);
  replays++;
  print(`REPLAY ${JSON.stringify({ what, setup, expr: sent[0][2][3], want, check, expect })}`);
}
const AT = "luaeval('vim.api.nvim_buf_get_name(0)') .. ' ' .. line('.') .. ':' .. col('.')";

// --- what it opens, and where ---------------------------------------------------------------
reset();
let r = await click(file(`${FILES}/plain.txt`, 3, 4));
let sent = nvimCalls();
check("path:line:col opens in the Neovim of the clicked space's editor tab", r === "handled" && sent.length === 1
  && sent[0][2][0] === "--server" && sent[0][2][1] === "/sock/20" && sent[0][2][2] === "--remote-expr");
check("...then shows that tab and gives its pane the keyboard", runs() === 'tab.select {"id":"e1"}; pane.focus {"pane":"pe"}');
check("...asking only who runs in the editor tab, never acting on a terminal",
  calls.filter(([k]) => k === "hc").every(([, a]) => a.join(" ") === "get te --json"));

reset();
r = await click(file(`${FILES}/plain.txt`, 3), from({ space: "s2", tab: "x", pane: "px", terminal: "tx" }));
check("a click in another space uses that space's editor tab", r === "handled"
  && nvimCalls()[0][2][1] === "/sock/30" && runs() === 'tab.select {"id":"e2"}; pane.focus {"pane":"pf"}');

reset();
world.panes.splice(1, 0, { pane: "pz", tab: "e1", terminal: "tz" });
world.foreground.tz = { name: "zsh", pid: 40 };
r = await click(file(`${FILES}/plain.txt`, 3));
check("a shell beside the Neovim in the editor tab is skipped", r === "handled" && nvimCalls()[0][2][1] === "/sock/20" && runs().endsWith('pane.focus {"pane":"pe"}'));

// --- what passes to Herdr ---------------------------------------------------------------------
const passes = async (what, link, source, prepare) => {
  reset();
  if (prepare) prepare();
  const r = await click(link, source);
  check(`${what} passes`, r === "pass" && nvimCalls().length === 0 && runs() === "");
};
await passes("a path without a line", file(`${FILES}/plain.txt`));
await passes("a line that is not a positive whole number", file(`${FILES}/plain.txt`, 2.5));
await passes("line 0", file(`${FILES}/plain.txt`, 0));
await passes("a URL", { kind: "url", raw: "https://example.com", url: "https://example.com" });
await passes("a terminal on another machine, though its space has a Neovim editor tab", file("/srv/app.rb", 3),
  from({ machine: "hercules", space: "hercules/s9" }), () => {
    world.spaces.push({ id: "hercules/s9", name: "far", machine: "hercules", tabs: [{ id: "hercules/e9", name: "editor" }] });
    world.panes.push({ pane: "hercules/p9", tab: "hercules/e9", terminal: "hercules/t9" });
    world.foreground["hercules/t9"] = { name: "nvim", pid: 90 };
    world.servers[90] = "/sock/90";
  });
await passes("a path Herdr could not resolve", file(null, 3));
await passes("a relative path from a terminal with no folder", file("src/a.rb", 3), from({ cwd: null }));
await passes("a path with a control character", file(`${FILES}/plain.txt\n:!touch x`, 3));
await passes("a space without an editor tab", file(`${FILES}/plain.txt`, 3), from(), () => { world.spaces[0].tabs.pop(); });
await passes("an editor tab running a shell", file(`${FILES}/plain.txt`, 3), from(), () => { world.foreground.te = { name: "zsh", pid: 20 }; });
await passes("a Neovim whose server cannot be found", file(`${FILES}/plain.txt`, 3), from(), () => { delete world.servers[20]; });
await passes("a terminal whose foreground cannot be read", file(`${FILES}/plain.txt`, 3), from(), () => { delete world.foreground.te; });
reset();
world.nvim = () => ({ code: 0, stdout: "0\n", stderr: "" });
r = await click(file(`${FILES}/dir`, 3));
check("a path Neovim finds is not a file passes, and no tab is shown", r === "pass" && nvimCalls().length === 1 && runs() === "");
reset();
world.nvim = () => ({ code: 1, stdout: "", stderr: "E247" });
r = await click(file(`${FILES}/plain.txt`, 3));
check("a Neovim that does not answer passes, and no tab is shown", r === "pass" && runs() === "");

// --- the clicked text runs nowhere ------------------------------------------------------------
reset();
const bad = `${FILES}/${NAMES.find((n) => n.includes("$("))}`;
await click(file(bad, 3));
check("the clicked text reaches no program but Neovim, and only inside its expression",
  calls.filter(([k, c]) => k === "exec" && c !== "nvim").every(([, , a]) => !a.join(" ").includes("touch"))
  && calls.filter(([k]) => k === "hc").every(([, a]) => !a.join(" ").includes("touch")));

// --- replayed against a real Neovim -----------------------------------------------------------
for (const n of NAMES) {
  await replay(`opens ${JSON.stringify(n)} at 3:4`, file(`${FILES}/${n}`, 3, 4), from(), "1", AT, `${FILES}/${n} 3:4`);
}
await replay("a relative path opens from the clicked terminal's folder", file("plain.txt", 3, 5), from({ cwd: `${FILES}/` }), "1", AT, `${FILES}/plain.txt 3:5`);
await replay("no column puts the cursor at the line's start", file(`${FILES}/plain.txt`, 4), from(), "1", AT, `${FILES}/plain.txt 4:1`);
await replay("a line past the end stops at the last line", file(`${FILES}/plain.txt`, 99, 2), from(), "1", AT, `${FILES}/plain.txt 5:2`);
await replay("a symlink to a file opens", file(`${FILES}/link.txt`, 2), from(), "1", "line('.')", "2");
for (const n of ["dir", "missing", "fifo"]) {
  await replay(`${n} is not opened`, file(`${FILES}/${n}`, 1), from(), "0", "&modified", "0");
}
await replay("a device is not opened", file("/dev/null", 1), from(), "0", "&modified", "0");
await replay("a file shown in another window is jumped to, not opened twice", file(`${FILES}/plain.txt`, 2), from(), "1",
  "len(win_findbuf(bufnr('%'))) .. ' ' .. winnr('$')", "1 2", `execute('only | edit ${FILES}/plain.txt | vsplit | enew')`);
await replay("from a special window it opens in a normal one, leaving that window", file(`${FILES}/plain.txt`, 2), from(), "1",
  "&buftype .. '|' .. len(filter(getwininfo(), {_, w -> getbufvar(w.bufnr, '&buftype') ==# 'nofile'}))", "|1",
  "execute('only | enew | vsplit | enew | setlocal buftype=nofile')");
check(`every Neovim case produced an expression to replay (${replays})`, replays === NAMES.length + 10);
