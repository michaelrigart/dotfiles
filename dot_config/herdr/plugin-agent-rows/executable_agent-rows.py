#!/usr/bin/python3 -I
"""dev.agent-rows: a spinner and "needs you" wording on herdr's agent rows.

`start` (the plugin's startup hook) detaches `worker` and returns. The worker keeps one
event subscription on the herdr socket and, while any agent pane is `working`, reports a
`spin` pane token (one braille frame, short TTL) to each working pane; every agent pane also
gets a state label that words `blocked` as "needs you". See spec
docs/superpowers/specs/2026-11-05-herdr-ui-refresh-design.md section 3.
"""
from __future__ import annotations

import fcntl
import json
import os
import select
import signal
import socket
import subprocess
import sys
import threading
import time

SOURCE = "dev.agent-rows"
TOKEN = "spin"
FRAMES = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"
FRAME_S = 0.14
TTL_MS = 1500
LABELS = {"blocked": "needs you"}

RECONNECT_S = 0.5
GIVE_UP_S = 10.0
LOG_MAX = 256 * 1024
LIFECYCLE = [{"type": "pane.agent_detected"}, {"type": "pane.closed"}, {"type": "pane.moved"}]


class RpcError(Exception):
    pass


class Stopping(BaseException):
    """Raised by the signal handler so a blocking select is interrupted."""


class Effects:
    def __init__(self, reports=None, resubscribe=False):
        self.reports = reports if reports is not None else []
        self.resubscribe = resubscribe


def _report(pane_id, **fields):
    params = {"pane_id": pane_id, "source": SOURCE}
    params.update(fields)
    return params


class Rows:
    """Pure state: which agent panes exist, what they are doing, and what is shown."""

    def __init__(self):
        self.status = {}          # pane_id -> agent_status, for every known agent pane
        self.labelled = set()     # agent panes whose label was reported on this connection
        self.shown = set()        # panes currently carrying a spin frame
        self.covered = frozenset()  # agent panes the live subscription has status entries for

    def agent_panes(self):
        return frozenset(self.status)

    def mark_covered(self, panes):
        self.covered = frozenset(panes)

    def reset_connection(self):
        self.labelled.clear()
        self.covered = frozenset()

    def working(self):
        return any(s == "working" for s in self.status.values())

    def subscriptions(self):
        subs = [dict(s) for s in LIFECYCLE]
        subs.extend({"type": "pane.agent_status_changed", "pane_id": p} for p in sorted(self.status))
        return subs

    def _effects(self, reports):
        return Effects(reports, self.agent_panes() != self.covered)

    def _label(self, pane_id, reports):
        if pane_id not in self.labelled:
            self.labelled.add(pane_id)
            reports.append(_report(pane_id, state_labels=dict(LABELS)))

    def _clear_if_shown(self, pane_id, reports):
        if pane_id in self.shown:
            self.shown.discard(pane_id)
            reports.append(_report(pane_id, tokens={TOKEN: None}))

    def apply_snapshot(self, snapshot):
        found = {}
        for pane in snapshot.get("panes") or []:
            if pane.get("agent") is not None:
                found[pane["pane_id"]] = pane.get("agent_status") or "unknown"
        for pane_id in set(self.status) - set(found):
            del self.status[pane_id]
            self.labelled.discard(pane_id)
            self.shown.discard(pane_id)
        reports = []
        for pane_id, status in found.items():
            self.status[pane_id] = status
            if status != "working":
                self._clear_if_shown(pane_id, reports)
            self._label(pane_id, reports)
        return self._effects(reports)

    def apply_event(self, event):
        data = event.get("data") or {}
        kind = (data.get("type") or event.get("event") or "").replace(".", "_")
        reports = []
        if kind == "pane_agent_status_changed":
            pane_id = data.get("pane_id")
            if pane_id in self.status:
                self.status[pane_id] = data.get("agent_status") or "unknown"
                if self.status[pane_id] != "working":
                    self._clear_if_shown(pane_id, reports)
        elif kind == "pane_agent_detected":
            pane_id = data.get("pane_id")
            if pane_id and pane_id not in self.status:
                self.status[pane_id] = "unknown"
                self._label(pane_id, reports)
        elif kind == "pane_closed":
            pane_id = data.get("pane_id")
            self.status.pop(pane_id, None)
            self.labelled.discard(pane_id)
            self.shown.discard(pane_id)
        elif kind == "pane_moved":
            previous = data.get("previous_pane_id")
            pane = data.get("pane") or {}
            new_id = pane.get("pane_id")
            if new_id and previous in self.status:
                status = self.status.pop(previous)
                self.status[new_id] = pane.get("agent_status") or status
                self.labelled.discard(previous)
                self._clear_if_shown(previous, reports)
                self._label(new_id, reports)
            elif new_id and new_id not in self.status and pane.get("agent"):
                self.status[new_id] = pane.get("agent_status") or "unknown"
                self._label(new_id, reports)
        return self._effects(reports)

    def frame_effects(self, frame):
        reports = []
        for pane_id, status in self.status.items():
            if status == "working":
                self.shown.add(pane_id)
                reports.append(_report(pane_id, tokens={TOKEN: frame}, ttl_ms=TTL_MS))
        return Effects(reports, False)

    def clear_all(self):
        reports = [_report(p, tokens={TOKEN: None}) for p in sorted(self.shown)]
        self.shown.clear()
        return Effects(reports, False)


def _read_line(sock):
    """One newline-terminated line, consuming nothing past it."""
    acc = b""
    while True:
        peek = sock.recv(65536, socket.MSG_PEEK)
        if not peek:
            raise EOFError("connection closed before a full line")
        idx = peek.find(b"\n")
        if idx >= 0:
            return acc + sock.recv(idx + 1)[:-1]
        acc += sock.recv(len(peek))


class Subscription:
    def __init__(self, sock):
        self._sock = sock
        self._buf = b""

    def fileno(self):
        return self._sock.fileno()

    def read_events(self):
        data = self._sock.recv(65536)
        if not data:
            raise EOFError("subscription closed")
        self._buf += data
        events = []
        while b"\n" in self._buf:
            line, self._buf = self._buf.split(b"\n", 1)
            if not line.strip():
                continue
            msg = json.loads(line)
            body = msg.get("data") or {}
            if "error" in msg or (body.get("type") or msg.get("event")) == "events_lost":
                raise EOFError("subscription error: %s" % json.dumps(msg.get("error") or msg)[:200])
            events.append(msg)
        return events

    def close(self):
        try:
            self._sock.close()
        except OSError:
            pass


class Transport:
    """The herdr socket: one request per connection, plus the long-lived subscription."""

    def __init__(self, path, connect=None, timeout=5.0):
        self._path = path
        self._connect = connect or self._unix
        self._timeout = timeout
        self._n = 0

    def _unix(self):
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            sock.settimeout(self._timeout)
            sock.connect(self._path)
        except BaseException:
            sock.close()
            raise
        return sock

    def _call(self, sock, method, params):
        self._n += 1
        line = json.dumps({"id": "agent-rows-%d" % self._n, "method": method, "params": params},
                          separators=(",", ":"))
        sock.settimeout(self._timeout)
        sock.sendall(line.encode("utf-8") + b"\n")
        return json.loads(_read_line(sock))

    def request(self, method, params):
        sock = self._connect()
        try:
            return self._call(sock, method, params)
        finally:
            sock.close()

    def subscribe(self, subscriptions):
        sock = self._connect()
        try:
            resp = self._call(sock, "events.subscribe", {"subscriptions": subscriptions})
            if "error" in resp or (resp.get("result") or {}).get("type") != "subscription_started":
                raise RpcError("events.subscribe refused: %s" % json.dumps(resp)[:200])
            sock.settimeout(None)
            return Subscription(sock)
        except BaseException:
            sock.close()
            raise


def _send(transport, log, effects):
    for params in effects.reports:
        try:
            resp = transport.request("pane.report_metadata", params)
            if resp.get("error"):
                log("report for %s refused: %s" % (params["pane_id"], json.dumps(resp["error"])[:200]))
        except Exception as exc:
            log("report for %s failed: %r" % (params["pane_id"], exc))


def _snapshot(transport):
    resp = transport.request("session.snapshot", {})
    if "error" in resp:
        raise RpcError("session.snapshot refused: %s" % json.dumps(resp["error"])[:200])
    return resp["result"]["snapshot"]


def _resync(transport, rows, live, send):
    """Replace `live` by a subscription covering every known agent pane, snapshotting after
    each new one opens so nothing between is lost. Closes `live` (and any half-open
    replacement) on failure too."""
    try:
        while True:
            covered = rows.agent_panes()
            new = transport.subscribe(rows.subscriptions())
            old, live = live, new
            try:
                rows.mark_covered(covered)
                effects = rows.apply_snapshot(_snapshot(transport))
                send(effects)
            finally:
                old.close()
            if not effects.resubscribe:
                return live
    except BaseException:
        live.close()
        raise


def _bootstrap(transport, rows, send):
    rows.reset_connection()
    live = transport.subscribe([dict(s) for s in LIFECYCLE])
    try:
        effects = rows.apply_snapshot(_snapshot(transport))
        send(effects)
    except BaseException:
        live.close()
        raise
    return _resync(transport, rows, live, send) if effects.resubscribe else live


def _connect(transport, rows, send, stop, clock, sleep, log, since):
    """Bootstrap, retrying until it works or `GIVE_UP_S` has passed since `since`."""
    while not stop.is_set():
        try:
            return _bootstrap(transport, rows, send)
        except Exception as exc:
            log("connect failed: %r" % (exc,))
            if clock() - since >= GIVE_UP_S:
                log("giving up after %.0f s" % GIVE_UP_S)
                return None
            sleep(RECONNECT_S)
    return None


def run(transport, clock, sleep, stop, log=None):
    log = log or (lambda message: None)
    rows = Rows()
    live = None
    tick = 0
    next_frame = 0.0

    def send(effects):
        _send(transport, log, effects)

    try:
        live = _connect(transport, rows, send, stop, clock, sleep, log, clock())
        while live is not None and not stop.is_set():
            try:
                timeout = max(0.0, next_frame - clock()) if rows.working() else None
                ready, _, _ = select.select([live], [], [], timeout)
                if stop.is_set():
                    break
                if ready:
                    for event in live.read_events():
                        send(rows.apply_event(event))
                    if rows.agent_panes() != rows.covered:
                        live = _resync(transport, rows, live, send)
                if rows.working() and clock() + 1e-6 >= next_frame:
                    send(rows.frame_effects(FRAMES[tick % len(FRAMES)]))
                    tick += 1
                    next_frame = clock() + FRAME_S
            except Stopping:
                raise
            except Exception as exc:
                log("connection lost: %r" % (exc,))
                lost_at = clock()
                live.close()
                live = None
                sleep(RECONNECT_S)
                live = _connect(transport, rows, send, stop, clock, sleep, log, lost_at)
    except Stopping:
        pass
    finally:
        if live is not None:
            live.close()
        send(rows.clear_all())
    return 0


class Log:
    def __init__(self, path):
        self._path = path

    def __call__(self, message):
        entry = "%s %s\n" % (time.strftime("%Y-%m-%dT%H:%M:%S"), message)
        try:
            try:
                size = os.path.getsize(self._path)
            except OSError:
                size = 0
            mode = "w" if size + len(entry) > LOG_MAX else "a"
            with open(self._path, mode) as handle:
                handle.write(entry)
        except OSError:
            pass


def state_dir(env):
    return env.get("HERDR_PLUGIN_STATE_DIR") or os.path.expanduser("~/.local/state/herdr/plugins/dev.agent-rows")


def acquire_lock(directory):
    """The held lock file, or None when another worker holds it. Keep the object alive."""
    handle = open(os.path.join(directory, "agent-rows.lock"), "a")
    try:
        fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        handle.close()
        return None
    return handle


def install_signal_handlers(stop):
    def handler(signum, frame):
        if stop.is_set():
            return
        stop.set()
        raise Stopping()

    signal.signal(signal.SIGTERM, handler)
    signal.signal(signal.SIGINT, handler)


def main(argv=None, env=None, transport=None):
    argv = sys.argv[1:] if argv is None else argv
    env = os.environ if env is None else env
    command = argv[0] if argv else ""
    if command == "start":
        subprocess.Popen([sys.executable, "-I", os.path.abspath(__file__), "worker"], env=dict(env),
                         stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                         start_new_session=True, close_fds=True)
        return 0
    if command != "worker":
        sys.stderr.write("usage: agent-rows.py start|worker\n")
        return 2
    directory = state_dir(env)
    os.makedirs(directory, exist_ok=True)
    lock = acquire_lock(directory)
    if lock is None:
        return 0
    log = Log(os.path.join(directory, "agent-rows.log"))
    if transport is None:
        path = env.get("HERDR_SOCKET_PATH")
        if not path:
            log("HERDR_SOCKET_PATH is not set; exiting")
            return 0
        transport = Transport(path)
    stop = threading.Event()
    install_signal_handlers(stop)
    log("worker started")
    code = run(transport, time.monotonic, time.sleep, stop, log)
    log("worker exiting")
    return code


if __name__ == "__main__":
    sys.exit(main())
