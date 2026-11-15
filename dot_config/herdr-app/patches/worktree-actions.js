// What the michael-menu clone does for a space's worktree items: New worktree, Open worktree
// and Retire worktree. New worktree opens mods/popup's wt prompt; Open and Retire run one of
// ~/.config/herdr-app/bin's scripts in a tab, where its prompt and its output stay readable.
//
// Source of truth: ~/.config/herdr-app/patches/worktree-actions.js. bin/respaces copies it
// into the michael-menu clone of Herdr's `menu` mod; edit it here, then run respaces.
//
// The menu closes itself the moment an item is chosen, and an overlay's unfinished tasks end
// with it. So nothing here waits: checkoutPlan() runs while the menu is open, and worktree()
// only reads what the window already knows.

import { run, spaces, exec, appHome, openOverlay } from "herdr";

const bin = (name) => `${appHome()}/bin/${name}`;

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

// `args`: the item's { space, action }. `plan`: checkoutPlan() of that space.
export function worktree(args, plan) {
  const space = spaces().find((s) => s.id === args.space);
  if (!space || !plan) return;
  if (args.action === "retire") return retire(space, plan);
  // The wt popup is shown by an invisible copy of mods/popup, opened here with the folder as
  // its props: the menu's tasks end with it, and the selection below is not yet visible to the
  // layout's copy, which would run wt in the space that was active before. 2 px, since up to 1
  // is a share of the window.
  if (args.action === "new") {
    openOverlay({ mod: "popup", kind: "popup", frame: "none", width: 2, height: 2, props: { wt: plan.top } });
    run("space.select", { id: space.id });
    return;
  }
  // open-space works from inside the repository, which the tab starts in. A tab does not bring
  // its space forward, and its prompt is what the person is waiting for.
  run("tab.new", { space: space.id, folder: plan.top, name: "open worktree", argv: [bin("open-space"), "--pick"] });
  run("space.select", { id: space.id });
}

// The retire tab goes in the main checkout's space, else in a new space at the main checkout:
// never in a space that may close (wt puts every worktree beside the main checkout, and retire
// refuses any other folder). What closes, and whether it may, is checkout-spaces' to decide.
function retire(space, { top, main }) {
  const target = spaces().find((s) => !s.machine && s.folder === main);
  const argv = [bin("retire"), top];
  if (target) {
    run("tab.new", { space: target.id, folder: main, name: "retire", argv });
    run("space.select", { id: target.id });
  } else {
    run("space.new", { name: main.replace(/\/+$/, "").split("/").pop(), folder: main, tab: "retire", argv, machine: "" });
  }
}
