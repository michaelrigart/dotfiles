#!/bin/bash
# Loads the be.netronix.* LaunchAgents chezmoi wrote, safe to re-run: a job is bootstrapped
# when it is not loaded, and a loaded one is reloaded only when its plist differs from the
# copy recorded at its last load. be.netronix.codex-app-server is never reloaded: a reload
# disconnects every Codex session. macOS /bin/bash is 3.2: no associative arrays, no ${x,,}.
set -u

uid=$(id -u)
state="${XDG_STATE_HOME:-$HOME/.local/state}/launchagents"
failed=0

for plist in "$HOME/Library/LaunchAgents"/be.netronix.*.plist; do
  [ -f "$plist" ] || continue
  label=$(basename "$plist" .plist)
  record="$state/$label.plist"

  if launchctl print "gui/$uid/$label" >/dev/null 2>&1; then
    if [ "$label" = be.netronix.codex-app-server ]; then
      echo "  unchanged $label (never reloaded here: a reload disconnects every Codex session)"
      continue
    fi
    if cmp -s "$plist" "$record"; then
      echo "  unchanged $label"
      continue
    fi
    launchctl bootout "gui/$uid/$label" >/dev/null 2>&1 || true
    verb=reloaded
  else
    verb=loaded
  fi

  if launchctl bootstrap "gui/$uid" "$plist" >/dev/null 2>&1; then
    mkdir -p "$state" && cp "$plist" "$record"
    echo "  $verb $label"
  else
    echo "  could not load $label — run: launchctl bootstrap gui/$uid $plist"
    failed=1
  fi
done

exit "$failed"
