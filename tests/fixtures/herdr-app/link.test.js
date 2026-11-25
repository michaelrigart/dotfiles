// The nav mod's terminal link handler (mods/nav/link.js), run headless under jsc by
// tests/herdr-app-link.test.sh: ./link-stubs.js stands in for "herdr", ./env.js names the folder
// of files the suite made. What the handler decides is asserted here; every Neovim expression it
// would send is printed as a REPLAY line, which the suite sends to a real headless Neovim; every
// editor tab it would make is printed as a LAUNCH line, whose Neovim the suite starts with that
// argv; every file check it would run is printed as a TEST line, which the suite runs.
import { handleLink } from "./link.js";
import { makeEditor } from "./nvim.js";
import { world, calls } from "./link-stubs.js";
import { FILES, NAMES } from "./env.js";

const check = (what, ok) => print(`  ${ok ? "PASS" : "FAIL"}: ${what}`);

function reset() {
  calls.length = 0;
  localStorage.clear();
  world.regular = () => 0;
  world.spaces = [
    { id: "s1", name: "dots", machine: null, folder: null, tabs: [{ id: "a1", name: "agents" }, { id: "e1", name: "editor" }] },
    { id: "s2", name: "other", machine: null, folder: null, tabs: [{ id: "e2", name: "editor" }] },
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
// expression asked afterwards and `expect` its answer; `setup` runs first when given. `when` is
// the click's time in ms: an hour ahead by default, since the suite sends the expressions only
// after this test has ended, and in the past for a click Neovim gets too late.
let replays = 0;
const LATER = Date.now() + 3600000;
async function replay(what, link, source, want, check, expect, setup, when = LATER) {
  reset();
  const now = Date.now;
  Date.now = () => when;
  try { await click(link, source); } finally { Date.now = now; }
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
await passes("a line too large to be exact", file(`${FILES}/plain.txt`, 1e21));
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
reset();
world.nvim = () => { throw new Error("timed out"); }; // exec rejects on its timeout
r = await click(file(`${FILES}/plain.txt`, 3));
check("a Neovim that is too busy to answer in time passes, and no tab is shown", r === "pass" && runs() === "");
await passes("a socket lookup that cannot run", file(`${FILES}/plain.txt`, 3), from(), () => { world.servers[20] = "reject"; });

// --- a space with no editor tab gets one, as Alt-E makes it -----------------------------------
const made = () => calls.filter(([k, n]) => k === "run" && n === "tab.new").map(([, , a]) => a);
const tested = () => calls.filter(([k, c]) => k === "exec" && c === "test").map(([, , a]) => a);
const noEditor = (id = "s1") => { const s = world.spaces.find((x) => x.id === id); s.tabs = s.tabs.filter((t) => t.name !== "editor"); };
const json = (x) => JSON.stringify(x);
const later = async (ms, f) => { const now = Date.now, t = now(); Date.now = () => t + ms; try { return await f(); } finally { Date.now = now; } };
const starting = () => { world.spaces[0].tabs.push({ id: "e1", name: "editor" }); world.foreground.te = { name: "zsh", pid: 20 }; calls.length = 0; };

reset(); noEditor();
r = await click(file(`${FILES}/plain.txt`, 3, 4));
let m = made();
check("a space without an editor tab gets one, running Neovim on the file at its line and column", r === "handled"
  && m.length === 1 && m[0].name === "editor" && m[0].space === "s1"
  && json(m[0].argv) === json(["nvim", "+call cursor(3, 4)", "--", `${FILES}/plain.txt`]));
check("...in the clicked terminal's folder when the space has none", m[0]?.folder === "/w");
check("...after asking only whether the path is a regular file, and nothing of any terminal",
  json(tested()) === json([["-f", `${FILES}/plain.txt`]]) && nvimCalls().length === 0
  && calls.every(([k]) => k !== "hc") && calls.filter(([k]) => k === "run").length === 1);
reset(); noEditor();
world.spaces[0].folder = "/repo";
await click(file(`${FILES}/plain.txt`, 3));
check("...in the space's folder when it has one", made()[0]?.folder === "/repo");

reset(); noEditor();
await click(file(`${FILES}/plain.txt`, 3));
r = await click(file(`${FILES}/a b.lua`, 2));
check("a second click before the new tab shows is taken, and makes no second tab", r === "handled" && made().length === 1);
reset(); noEditor();
await click(file(`${FILES}/plain.txt`, 3));
starting();
r = await click(file(`${FILES}/plain.txt`, 2));
check("a click while the new tab's Neovim is still starting is taken, and does nothing", r === "handled" && runs() === "" && nvimCalls().length === 0);
reset(); noEditor();
await click(file(`${FILES}/plain.txt`, 3));
r = await later(3001, () => click(file(`${FILES}/plain.txt`, 3)));
check("3 s on, a space still without an editor tab gets another", r === "handled" && made().length === 2);
reset(); noEditor();
await click(file(`${FILES}/plain.txt`, 3));
starting();
r = await later(3001, () => click(file(`${FILES}/plain.txt`, 3)));
check("3 s on, an editor tab with no Neovim passes again", r === "pass" && runs() === "");
reset(); noEditor("s1"); noEditor("s2");
await click(file(`${FILES}/plain.txt`, 3));
r = await click(file(`${FILES}/plain.txt`, 3), from({ space: "s2" }));
check("a new tab in one space holds back no other space", r === "handled" && made().length === 2 && made()[1].space === "s2");

reset(); noEditor();
check("Alt-E's tab runs nvim . in the folder it is given", makeEditor("s1", "/w", ["nvim", "."]) === true
  && json(made()) === json([{ name: "editor", space: "s1", folder: "/w", argv: ["nvim", "."] }]));
r = await click(file(`${FILES}/plain.txt`, 3));
check("a click just after Alt-E asked for the tab is taken, and makes no second one", r === "handled" && made().length === 1);
reset(); noEditor();
await click(file(`${FILES}/plain.txt`, 3));
check("Alt-E just after a click made the tab makes no second one", makeEditor("s1", "/w", ["nvim", "."]) === false && made().length === 1);

await passes("with no editor tab, a check that cannot run", file(`${FILES}/plain.txt`, 3), from(), () => { noEditor(); world.regular = () => "reject"; });
await passes("with no editor tab, a terminal on another machine", file("/srv/app.rb", 3), from({ machine: "hercules", space: "hercules/s9" }),
  () => { world.spaces.push({ id: "hercules/s9", name: "far", machine: "hercules", folder: "/srv", tabs: [] }); });
await passes("a space Herdr does not list", file(`${FILES}/plain.txt`, 3), from({ space: "gone" }));

// Whether it is a regular file is asked of `test -f`, which the suite runs: `code` is the exit
// the handler is told here, and the one the real `test` must give.
let probes = 0;
async function probe(what, path, code) {
  reset(); noEditor();
  world.regular = () => code;
  const r = await click(file(path, 1));
  const t = tested();
  const ok = t.length === 1 && r === (code === 0 ? "handled" : "pass") && made().length === (code === 0 ? 1 : 0);
  check(`with no editor tab, ${what}: ${code === 0 ? "a tab is made" : "passes"}`, ok);
  if (ok) { probes++; print(`TEST ${json({ what, argv: ["test", ...t[0]], code })}`); }
}
for (const [n, code] of [["plain.txt", 0], ["link.txt", 0], ["dir", 1], ["fifo", 1], ["missing", 1]]) {
  await probe(`${n} ${code ? "is not" : "is"} a regular file`, `${FILES}/${n}`, code);
}
await probe("a device is not a regular file", "/dev/null", 1);
check(`every file check produced a command to run (${probes})`, probes === 6);

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
await replay("a click Neovim gets too late opens nothing", file(`${FILES}/late.txt`, 2), from(), "0",
  `bufexists('${FILES}/late.txt')`, "0", undefined, Date.now() - 60000);
// A Neovim left in another mode is put in normal mode, so the next keys do not edit the file or
// run a half-typed command there, and the cursor stays on the clicked column.
const MODE = "mode() .. ' ' .. line('.') .. ':' .. col('.') .. ' ' .. &modified";
for (const [what, keys] of [["insert", "i"], ["replace", "R"], ["command-line", ":echo 1"], ["visual", "v"]]) {
  await replay(`from ${what} mode it ends in normal mode at the clicked column`, file(`${FILES}/plain.txt`, 3, 6), from(), "1",
    MODE, "n 3:6 0", `execute('only | enew!') .. feedkeys('${keys}', 'n')`);
}
await replay("a float showing the file is not where it opens, nor is the current float", file(`${FILES}/plain.txt`, 2), from(), "1",
  "win_gettype() .. '|' .. luaeval('vim.api.nvim_buf_get_name(0)')", `|${FILES}/plain.txt`,
  `execute('only | enew!') .. luaeval('vim.api.nvim_open_win(vim.fn.bufadd(_A), true, {relative = "editor", row = 1, col = 1, width = 20, height = 3}) * 0', '${FILES}/plain.txt')`);
check(`every Neovim case produced an expression to replay (${replays})`, replays === NAMES.length + 16);

// --- each new tab's Neovim, started by the suite ------------------------------------------------
// Herdr runs a tab's argv as "$@" in the login shell, so each element reaches Neovim whole. Only
// whole numbers reach its Ex command; the path comes after "--". `expect` is the buffer, the
// cursor and the mode once Neovim has started.
let launches = 0;
async function launch(what, link, source, expect) {
  reset(); noEditor();
  await click(link, source);
  const m = made(), argv = m[0]?.argv ?? [];
  if (m.length !== 1 || argv.length !== 4 || argv[0] !== "nvim" || !/^\+call cursor\(\d+, \d+\)$/.test(argv[1]) || argv[2] !== "--") {
    return print(`  FAIL: ${what}: the handler made ${m.length} tabs, argv ${json(argv)}`);
  }
  launches++;
  print(`LAUNCH ${json({ what, args: argv.slice(1), expect })}`);
}
for (const n of NAMES) await launch(`a new tab opens ${json(n)} at 3:4`, file(`${FILES}/${n}`, 3, 4), from(), `${FILES}/${n} 3:4 n`);
await launch("a new tab opens a relative path from the clicked terminal's folder", file("plain.txt", 3, 5), from({ cwd: `${FILES}/` }), `${FILES}/plain.txt 3:5 n`);
await launch("a new tab with no column starts at the line's start", file(`${FILES}/plain.txt`, 4), from(), `${FILES}/plain.txt 4:1 n`);
await launch("a new tab with a line past the end starts at the last line", file(`${FILES}/plain.txt`, 99, 2), from(), `${FILES}/plain.txt 5:2 n`);
check(`every new tab produced a Neovim to start (${launches})`, launches === NAMES.length + 3);
