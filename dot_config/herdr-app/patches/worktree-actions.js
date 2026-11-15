// What the michael-menu clone does for a space's worktree items: New worktree, Open worktree
// and Retire worktree. Each runs one of ~/.config/herdr-app/bin's scripts in a tab, where its
// prompt and its output stay readable.
//
// Source of truth: ~/.config/herdr-app/patches/worktree-actions.js. bin/respaces copies it
// into the michael-menu clone of Herdr's `menu` mod; edit it here, then run respaces.
//
// The menu closes itself the moment an item is chosen, and an overlay's unfinished tasks end
// with it. So nothing here waits: checkoutPlan() runs while the menu is open, and worktree()
// only reads what the window already knows.

import { run, spaces, agents, notify, exec, appHome } from "herdr";

const bin = (name) => `${appHome()}/bin/${name}`;
const inside = (path, dir) => path === dir || path.startsWith(`${dir.replace(/\/+$/, "")}/`);

// The checkout a space was made at: its top level and the main checkout, the first entry of
// `git worktree list`, as wt's own _wt_primary reads it. `folder`: the space's own `.folder`
// (the menu passes that, not a pane's live folder, which may have wandered into another
// checkout).
export async function checkoutPlan(folder) {
  const top = await exec("git", ["rev-parse", "--show-toplevel"], { cwd: folder });
  const listed = await exec("git", ["worktree", "list", "--porcelain"], { cwd: folder });
  const main = /^worktree (.+)$/m.exec(listed.stdout)?.[1];
  if (top.code !== 0 || listed.code !== 0 || !main) return null;
  return { top: top.stdout.trim(), main };
}

// The worktree's own spaces, the ones retire closes: local, with their folder in the checkout
// or under it. Never a space only because a terminal of it has gone there: retire refuses
// while one is, and names it.
function closing(top) {
  return spaces().filter((s) => !s.machine && s.folder && inside(s.folder, top));
}

// `args`: the item's { space, action }. `plan`: checkoutPlan() of that space.
export function worktree(args, plan) {
  const space = spaces().find((s) => s.id === args.space);
  if (!space || !plan) return;
  if (args.action === "retire") return retire(space, plan);
  // wt-app and open-space work from inside the repository, which the tab starts in. A tab
  // does not bring its space forward, and its prompt is what the person is waiting for.
  const [name, argv] = args.action === "new"
    ? ["new worktree", [bin("wt-app"), "--prompt"]]
    : ["open worktree", [bin("open-space"), "--pick"]];
  run("tab.new", { space: space.id, folder: plan.top, name, argv });
  run("space.select", { id: space.id });
}

function retire(space, { top, main }) {
  const gone = new Set(closing(top).map((s) => s.id));
  gone.add(space.id);
  const busy = agents().filter((a) => gone.has(a.space) && (a.status === "working" || a.status === "blocked"));
  if (busy.length) {
    notify({
      title: "Not retired: an agent is busy",
      body: busy.map((a) => `${a.program?.name || a.app || "agent"} in ${a.space_name} / ${a.tab_name} is ${a.status}`).join("\n"),
      level: "warning",
    });
    return;
  }
  // retire runs in a tab of its own: never in a space it closes, which would take the tab
  // down with it. The main checkout's space if it is open, else the one in front, else a
  // new space at the main checkout.
  const others = spaces().filter((s) => !gone.has(s.id) && !s.machine);
  const target = others.find((s) => s.folder === main) ?? others.find((s) => s.active);
  const argv = [bin("retire"), top];
  if (target) {
    run("tab.new", { space: target.id, folder: main, name: "retire", argv });
    run("space.select", { id: target.id });
  } else {
    run("space.new", { name: main.replace(/\/+$/, "").split("/").pop(), folder: main, tab: "retire", argv, machine: "" });
  }
}
