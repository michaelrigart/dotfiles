// What the resume mod decides, with no I/O, so it can be tested: tests/herdr-app-resume.test.sh
// runs this file under macOS's own `jsc -m`. Nothing here may import or touch the app.
//
// A terminal is lost when its root process (the pid `hc get` reports) is not the one its record
// was made under. herdr-core restarting keeps every terminal and its pid, so a restart loses none.
//   Rec  = { app, id, cwd, cmd, fresh, pid?, quit?, sent? }   what is saved per terminal address
//   Seen = { address, pid, shell, other, now }   what a scan saw: the root pid (null when unknown),
//          whether a shell is in front, whether some other program is (neither a shell nor claude or
//          codex; false when unknown), and the agent running now ({app, id, cwd, cmd, fresh}) or null

// Shells the core has just recovered may not read typed input yet.
export const SETTLE = 3000;
// How long a lost terminal whose session runs elsewhere waits before it falls to the button.
export const PATIENCE = 120000;

// Records after this scan, and what to do about each terminal. A record under the same pid with
// another program in front is marked quit without the button: the agent is gone from the front,
// and the next program may have hidden its quit from every scan.
//   button  terminals at a shell that were not lost (an agent quit on purpose, or a failed resume)
//   lost    terminals whose new shell has held its pid for SETTLE
//   again   a new shell has not settled yet: look again soon
//   firstSeen  address -> {pid, at}, for the lost-path terminals only
export function classify(saved, seen, firstSeen, now) {
  const out = { ...saved };
  const next = {};
  const button = [];
  const lost = [];
  let changed = false;
  let again = false;
  for (const { address, pid, shell, other, now: agent } of seen) {
    const rec = out[address];
    if (agent) {
      if (!rec || rec.cmd !== agent.cmd || rec.pid !== pid || rec.quit || rec.sent) {
        out[address] = { ...agent, pid };
        changed = true;
      }
      continue;
    }
    if (other && rec && rec.pid === pid && !rec.quit) {
      out[address] = { ...rec, quit: true };
      changed = true;
      continue;
    }
    if (!shell || !rec) continue;
    if (rec.quit || rec.pid == null || rec.pid === pid) {
      if (!rec.quit) {
        out[address] = { ...rec, quit: true };
        changed = true;
      }
      button.push(address);
      continue;
    }
    if (pid == null) continue; // mid-recovery: cannot tell yet
    const first = firstSeen?.[address];
    if (first && first.pid === pid) {
      next[address] = first;
      if (now - first.at >= SETTLE) {
        lost.push(address);
        continue;
      }
    } else {
      next[address] = { pid, at: now };
    }
    again = true;
  }
  return { saved: out, changed, button, lost, again, firstSeen: next };
}

// Which of `addresses` may be resumed now, one terminal per session and none where it already
// runs. `elsewhere`: ids the helper says run somewhere. A terminal without a record is dropped.
export function reserve(addresses, saved, seen, elsewhere) {
  const go = [];
  const held = [];
  const taking = new Set();
  for (const address of addresses) {
    const rec = saved[address];
    if (!rec) continue;
    const taken = elsewhere.has(rec.id) || taking.has(rec.id)
      || seen.some((s) => s.address !== address && s.now?.id === rec.id)
      || Object.entries(saved).some(([other, r]) => other !== address && r.sent && r.id === rec.id);
    if (taken) {
      held.push(address);
    } else {
      go.push(address);
      taking.add(rec.id);
    }
  }
  return { go, held };
}

// A copy of `saved` with each address's record claimed: the new shell's pid (given `firstSeen`)
// and, with `sent`, the mark that a launch is on its way.
export function claim(saved, addresses, { firstSeen, sent } = {}) {
  const out = { ...saved };
  for (const address of addresses) {
    if (!out[address]) continue;
    const next = { ...out[address] };
    if (firstSeen?.[address]) next.pid = firstSeen[address].pid;
    if (sent) next.sent = true;
    out[address] = next;
  }
  return out;
}
