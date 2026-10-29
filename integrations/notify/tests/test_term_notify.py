"""Tests for term-notify. Run: python3 -m unittest discover -s integrations/notify/tests -v

The tmux tests need a real tmux (they use a private server, `tmux -L`) and are skipped without one.
"""
import contextlib
import importlib.machinery
import importlib.util
import io
import json
import os
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.dont_write_bytecode = True
PROGRAM = Path(__file__).resolve().parent.parent / "term-notify"


def load_module():
    loader = importlib.machinery.SourceFileLoader("term_notify", str(PROGRAM))
    spec = importlib.util.spec_from_loader("term_notify", loader)
    module = importlib.util.module_from_spec(spec)
    sys.modules["term_notify"] = module
    loader.exec_module(module)
    return module


tn = load_module()


def setUpModule():
    # Fail closed: even a subprocess that accidentally uses the production runner cannot reach the real services.
    directory = Path(tempfile.mkdtemp(prefix="term-notify-services-"))
    previous_path = os.environ.get("PATH", "")
    unittest.addModuleCleanup(shutil.rmtree, directory, True)
    unittest.addModuleCleanup(os.environ.__setitem__, "PATH", previous_path)
    for name in ("launchctl", "systemctl", "loginctl"):
        executable = directory / name
        executable.write_text("#!/bin/sh\nprintf '%s\\n' \"$0 $*\" >> " + json.dumps(str(directory / "calls"))
                              + "\ncase \"${0##*/}\" in loginctl) printf 'Linger=yes\\n';; esac\nexit 0\n")
        executable.chmod(0o700)
    os.environ["PATH"] = str(directory) + os.pathsep + previous_path

KEY = bytes(range(32)).hex()
SECRET = "ab" * 32
SECRET_B = "cd" * 32
SESSION = "ZZ-private-session-name"
START, PID = "1700000000", "42"


def write_pairing(paths, name="a" * 64, secret=SECRET, key=KEY, url="https://relay.example.com", **extra):
    paths.pairings.mkdir(mode=0o700, parents=True, exist_ok=True)
    data = {"version": 1, "relay_url": url, "secret": secret, "routing_key": key}
    data.update(extra)
    path = paths.pairings / (name + ".json")
    path.write_text(json.dumps(data))
    path.chmod(0o600)
    return path


def agent_line(pane="%1", session=SESSION, seen="", state="done", at=1000.0, heartbeat=1000.0, start=START, pid=PID, **extra):
    payload = {"v": 1, "state": state, "since": at, "t": heartbeat, "pid": 9, "title": "secret title", "last": "secret answer"}
    if at is not None:
        payload["stop"] = {"at": at, "why": state}
    payload.update(extra)
    return "\t".join([pane, session, start, pid, str(seen), json.dumps(payload)])


class Clock:
    def __init__(self, now=1000.0):
        self.now = now

    def __call__(self):
        return self.now


class Harness:
    """A Notifier over a temp HOME with fake tmux panes and a fake relay that records every request."""

    def __init__(self, test, debounce=6.0):
        self.home = Path(tempfile.mkdtemp())
        test.addCleanup(shutil.rmtree, self.home, True)
        self.paths = tn.Paths(self.home)
        self.clock = Clock()
        self.output = ""
        self.lists = 0
        self.after_list = None
        self.answers = []  # statuses returned by the relay in order; 200 when empty
        self.posts = []
        self.logs = []
        self.debounce = debounce
        self.notifier = self.make()

    def make(self):
        return tn.Notifier(self.paths, self.list_panes, self.post, self.clock, self.logs.append, debounce=self.debounce)

    def list_panes(self):
        self.lists += 1
        panes = tn.parse_panes(self.output)
        if self.after_list:
            self.after_list(self)
        return panes

    def post(self, pairing, body):
        self.posts.append((pairing.id, body))
        status = self.answers.pop(0) if self.answers else 200
        if isinstance(status, tn.Result):
            return status
        return tn.Result(status=status)

    def tick(self, at=None):
        if at is not None:
            self.clock.now = at
        return self.notifier.tick()


class RouteTests(unittest.TestCase):
    def pairing(self):
        return tn.parse_pairing("p", {"version": 1, "relay_url": "https://r.example", "secret": SECRET, "routing_key": KEY})

    def pane(self, **changes):
        base = dict(id="%7", session="café", server_start="1793241830", server_pid="27548", seen=0.0, kind="done", stop_at=1.0)
        base.update(changes)
        return tn.Pane(**base)

    def test_route_matches_independent_hmac_vector(self):
        # openssl: printf 'caf\xc3\xa9\0%7\0001793241830\00027548' | openssl dgst -sha256 -mac HMAC -macopt hexkey:000102..1f
        expected = "b188962ceb6d951bed4e26454065cc323232eb4684ace4adadf14718802a011f"
        self.assertEqual(self.pairing().route(self.pane()), expected)

    def test_every_field_changes_the_route(self):
        base = self.pairing().route(self.pane())
        for change in ({"session": "cafe"}, {"id": "%8"}, {"server_start": "1793241831"}, {"server_pid": "27549"}):
            self.assertNotEqual(self.pairing().route(self.pane(**change)), base, change)

    def test_undecodable_session_bytes_route_by_their_raw_bytes(self):
        raw = b"a\xffb".decode("utf-8", "surrogateescape")
        import hmac, hashlib

        expected = hmac.new(bytes.fromhex(KEY), b"a\xffb\0%7\0001793241830\00027548", hashlib.sha256).hexdigest()
        self.assertEqual(self.pairing().route(self.pane(session=raw)), expected)


class ParseTests(unittest.TestCase):
    def one(self, line):
        return tn.parse_panes(line + "\n")

    def test_states_that_stop_for_the_user(self):
        for state in ("ask", "approval", "done", "error"):
            [pane] = self.one(agent_line(state=state))
            self.assertEqual((pane.kind, pane.stop_at), (state, 1000.0))

    def test_states_that_do_not(self):
        for state in ("working", "idle", "aborted", "exited", "nonsense"):
            [pane] = self.one(agent_line(state=state))
            self.assertIsNone(pane.kind, state)
            self.assertIsNone(pane.stop_at, state)

    def test_since_stands_in_when_stop_is_missing_and_nothing_else_does(self):
        [pane] = self.one(agent_line(at=None, since=555.5))
        self.assertEqual(pane.stop_at, 555.5)
        [pane] = self.one(agent_line(at=None, since=None))
        self.assertIsNone(pane.stop_at)

    def test_hostile_numbers_are_not_times(self):
        for bad in ("NaN", "Infinity", "-5", "0", "true", '"7"'):
            line = agent_line(since=555.0).replace('"at": 1000.0', '"at": ' + bad)
            [pane] = self.one(line)
            self.assertEqual(pane.stop_at, 555.0, bad)  # unusable "at" falls back to since

    def test_seen_parse(self):
        self.assertEqual(self.one(agent_line(seen="12.5"))[0].seen, 12.5)
        self.assertEqual(self.one(agent_line(seen=""))[0].seen, 0.0)
        self.assertEqual(self.one(agent_line(seen="junk"))[0].seen, 0.0)
        self.assertEqual(self.one(agent_line(seen="nan"))[0].seen, 0.0)

    def test_malformed_lines_are_skipped_not_fatal(self):
        good = agent_line(pane="%2")
        output = "\n".join(["", "garbage", "%1\tonly\tthree", agent_line(pane="x1"), agent_line(start="soon"), agent_line(pid=""),
                            "%3\ts\t1\t2\t\t{not json", "%4\ts\t1\t2\t\t[1,2]", good])
        self.assertEqual([p.id for p in tn.parse_panes(output)], ["%2"])

    def test_session_name_is_kept_verbatim(self):
        [pane] = self.one(agent_line(session="a b:é🙂"))
        self.assertEqual(pane.session, "a b:é🙂")


class DeliveryTests(unittest.TestCase):
    def setUp(self):
        self.h = Harness(self)
        write_pairing(self.h.paths)

    def test_body_has_only_secret_session_ref_and_kind(self):
        self.h.output = agent_line(state="ask")
        self.assertEqual(self.h.tick(1006.0), (1, 0))
        [(pairing_id, body)] = self.h.posts
        self.assertEqual(sorted(body), ["kind", "secret", "session_ref"])
        self.assertEqual(body["kind"], "ask")
        self.assertEqual(body["secret"], SECRET)
        self.assertRegex(body["session_ref"], r"\A[0-9a-f]{64}\Z")
        wire = json.dumps(body)
        for private in (SESSION, "%1", "secret title", "secret answer", START):
            self.assertNotIn(private, wire)

    def test_kind_follows_state(self):
        for state in ("ask", "approval", "done", "error"):
            h = Harness(self)
            write_pairing(h.paths)
            h.output = agent_line(state=state)
            h.tick(1006.0)
            self.assertEqual(h.posts[0][1]["kind"], state)

    def test_debounce_boundary(self):
        self.h.output = agent_line()
        self.h.tick(1005.99)
        self.assertEqual(self.h.posts, [])
        self.h.tick(1006.0)
        self.assertEqual(len(self.h.posts), 1)

    def test_stop_older_than_five_minutes_is_never_pushed(self):
        self.h.output = agent_line()
        self.h.tick(1300.01)
        self.assertEqual(self.h.posts, [])
        h = Harness(self)
        write_pairing(h.paths)
        h.output = agent_line()
        h.tick(1300.0)
        self.assertEqual(len(h.posts), 1)

    def test_seen_boundary_is_strictly_greater(self):
        self.h.output = agent_line(seen="1000.0")
        self.h.tick(1010.0)
        self.assertEqual(self.h.posts, [])
        self.h.output = agent_line(seen="999.999")
        self.h.tick(1010.0)
        self.assertEqual(len(self.h.posts), 1)

    def test_answer_during_debounce_cancels(self):
        self.h.output = agent_line()
        self.h.tick(1003.0)
        self.h.output = agent_line(seen="1004.5")
        self.h.tick(1007.0)
        self.h.tick(1100.0)
        self.assertEqual(self.h.posts, [])

    def test_agent_resuming_during_debounce_cancels(self):
        self.h.output = agent_line()
        self.h.tick(1003.0)
        self.h.output = agent_line(state="working")
        self.h.tick(1010.0)
        self.assertEqual(self.h.posts, [])

    def test_answer_between_decision_and_send_wins(self):
        self.h.output = agent_line()

        def answer(h):
            if h.lists == 1:  # the look right after "it is due"
                h.output = agent_line(seen="1005.0")

        self.h.after_list = answer
        self.h.tick(1010.0)
        self.assertEqual(self.h.lists, 2)
        self.assertEqual(self.h.posts, [])

    def test_heartbeat_rewrites_do_not_repeat_the_push(self):
        for beat in range(8):
            self.h.output = agent_line(heartbeat=1000.0 + 30 * beat)
            self.h.tick(1006.0 + 30 * beat)
        self.assertEqual(len(self.h.posts), 1)

    def test_restart_does_not_repeat_but_a_new_stop_pushes(self):
        self.h.output = agent_line()
        self.h.tick(1006.0)
        self.h.notifier = self.h.make()
        self.h.tick(1020.0)
        self.assertEqual(len(self.h.posts), 1)
        self.h.output = agent_line(at=1030.0)
        self.h.tick(1040.0)
        self.assertEqual(len(self.h.posts), 2)

    def test_state_file_is_private(self):
        self.h.output = agent_line()
        self.h.tick(1006.0)
        self.assertEqual(stat.S_IMODE(self.h.paths.state.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(self.h.paths.data.stat().st_mode), 0o700)
        self.assertNotIn(SESSION, self.h.paths.state.read_text())

    def test_corrupt_state_starts_fresh_but_old_stops_stay_quiet(self):
        self.h.paths.data.mkdir(mode=0o700, parents=True)
        self.h.paths.state.write_text("{not json")
        self.h.notifier = self.h.make()
        self.h.output = agent_line()
        self.h.tick(1400.0)
        self.assertEqual(self.h.posts, [])
        self.assertTrue(any("state file unreadable" in m for m in self.h.logs))

    def test_new_pane_is_pushed_when_it_appears(self):
        self.h.output = agent_line(pane="%1", at=1000.0, seen="2000")
        self.h.tick(1010.0)
        self.h.output += "\n" + agent_line(pane="%9", session="new", at=1020.0, seen="")
        self.h.tick(1030.0)
        [(_, body)] = self.h.posts
        self.assertEqual(body["session_ref"], tn.Pairing("x", "https://r", SECRET, bytes.fromhex(KEY)).route(
            tn.parse_panes(agent_line(pane="%9", session="new"))[0]))

    def test_each_pane_is_its_own_stop(self):
        self.h.output = agent_line(pane="%1") + "\n" + agent_line(pane="%2")
        self.h.tick(1006.0)
        self.assertEqual(len(self.h.posts), 2)
        self.assertEqual(len({b["session_ref"] for _, b in self.h.posts}), 2)

    def test_reused_pane_id_after_tmux_restart_pushes_a_newer_stop(self):
        self.h.output = agent_line(at=1000.0)
        self.h.tick(1006.0)
        self.h.output = ""
        self.h.tick(1010.0)
        self.h.output = agent_line(at=1020.0, start="1700000500", pid="77")
        self.h.tick(1030.0)
        self.assertEqual(len(self.h.posts), 2)
        self.assertNotEqual(self.h.posts[0][1]["session_ref"], self.h.posts[1][1]["session_ref"])

    def test_tmux_unreadable_changes_nothing(self):
        self.h.output = agent_line()
        self.h.notifier.list_panes = lambda: None
        self.assertEqual(self.h.tick(1100.0), (0, 0))
        self.assertEqual(self.h.posts, [])


class FailureTests(unittest.TestCase):
    def setUp(self):
        self.h = Harness(self)
        write_pairing(self.h.paths)
        self.h.output = agent_line()

    def test_server_error_retries_with_backoff_then_succeeds(self):
        self.h.answers = [500, 503]
        self.h.tick(1006.0)
        self.assertEqual(len(self.h.posts), 1)
        self.h.tick(1010.9)  # before the 5 s backoff ends
        self.assertEqual(len(self.h.posts), 1)
        self.h.tick(1011.0)
        self.assertEqual(len(self.h.posts), 2)
        self.h.tick(1020.9)  # the second wait is 10 s
        self.assertEqual(len(self.h.posts), 2)
        self.h.tick(1021.0)
        self.assertEqual(len(self.h.posts), 3)
        self.h.tick(1100.0)
        self.assertEqual(len(self.h.posts), 3)

    def test_rate_limit_waits_for_retry_after(self):
        self.h.answers = [tn.Result(status=429, retry_after=40.0)]
        self.h.tick(1006.0)
        self.h.tick(1045.0)
        self.assertEqual(len(self.h.posts), 1)
        self.h.tick(1046.0)
        self.assertEqual(len(self.h.posts), 2)

    def test_rate_limit_wait_is_clamped_between_one_and_300_seconds(self):
        for given, waited in ((100000.0, 300.0), (0.0, 1.0), (None, 30.0)):
            h = Harness(self)
            write_pairing(h.paths)
            h.output = agent_line()
            h.answers = [tn.Result(status=429, retry_after=given)]
            h.tick(1006.0)
            [(next_try, _)] = h.notifier.retry.values()
            self.assertEqual(next_try, 1006.0 + waited, given)

    def test_network_error_retries(self):
        self.h.answers = [tn.Result(error="could not reach the relay (ConnectionRefusedError)")]
        self.h.tick(1006.0)
        self.h.tick(1011.0)
        self.assertEqual(len(self.h.posts), 2)

    def test_refusal_is_final_and_tells_what_to_do(self):
        for status in (400, 401, 403, 404):
            h = Harness(self)
            write_pairing(h.paths)
            h.output = agent_line()
            h.answers = [status]
            h.tick(1006.0)
            h.tick(1100.0)
            self.assertEqual(len(h.posts), 1, status)
            self.assertTrue(any("HTTP %d" % status in m and ("pair this host again" in m or "update term-notify" in m) for m in h.logs), status)

    def test_redirect_status_is_final(self):
        self.h.answers = [302]
        self.h.tick(1006.0)
        self.h.tick(1100.0)
        self.assertEqual(len(self.h.posts), 1)

    def test_retry_for_a_stop_answered_meanwhile_is_dropped(self):
        self.h.answers = [500]
        self.h.tick(1006.0)
        self.h.output = agent_line(seen="1007.0")
        self.h.tick(1020.0)
        self.assertEqual(len(self.h.posts), 1)

    def test_logs_never_carry_secrets_or_session_text(self):
        self.h.answers = [500, 403]
        self.h.tick(1006.0)
        self.h.tick(1011.0)
        everything = "\n".join(self.h.logs)
        for private in (SECRET, KEY, SESSION, "%1", "secret title", "secret answer"):
            self.assertNotIn(private, everything)
        self.assertTrue(self.h.logs)


class MultiplePairingTests(unittest.TestCase):
    def setUp(self):
        self.h = Harness(self)
        write_pairing(self.h.paths, name="a" * 64, secret=SECRET, key=KEY)
        write_pairing(self.h.paths, name="b" * 64, secret=SECRET_B, key="11" * 32)
        self.h.output = agent_line()

    def test_every_pairing_is_pushed_with_its_own_secret_and_route(self):
        self.h.tick(1006.0)
        bodies = {pid: body for pid, body in self.h.posts}
        self.assertEqual(set(bodies), {"a" * 64, "b" * 64})
        self.assertEqual(bodies["a" * 64]["secret"], SECRET)
        self.assertEqual(bodies["b" * 64]["secret"], SECRET_B)
        self.assertNotEqual(bodies["a" * 64]["session_ref"], bodies["b" * 64]["session_ref"])

    def test_retry_goes_only_to_the_pairing_that_failed(self):
        self.h.answers = [200, 500]
        self.h.tick(1006.0)
        self.h.tick(1011.0)
        self.assertEqual([pid for pid, _ in self.h.posts], ["a" * 64, "b" * 64, "b" * 64])

    def test_pairing_added_later_gets_only_fresh_unseen_stops(self):
        self.h.tick(1006.0)
        write_pairing(self.h.paths, name="c" * 64, secret="ee" * 32, key="22" * 32)
        self.h.tick(1020.0)
        self.assertEqual(len(self.h.posts), 3)  # c sees the same unseen stop once: it is still unread

    def test_pairing_removed_stops_its_pushes(self):
        (self.h.paths.pairings / ("b" * 64 + ".json")).unlink()
        self.h.tick(1006.0)
        self.assertEqual([pid for pid, _ in self.h.posts], ["a" * 64])

    def test_one_bad_file_does_not_stop_the_others(self):
        write_pairing(self.h.paths, name="c" * 64, secret="XYZ")
        self.h.tick(1006.0)
        self.assertEqual(len(self.h.posts), 2)


class PairingFileTests(unittest.TestCase):
    def setUp(self):
        self.home = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.home, True)
        self.paths = tn.Paths(self.home)
        self.logs = []
        self.store = tn.PairingStore(self.paths.pairings, self.logs.append)

    def test_rejects_each_malformed_field_without_echoing_it(self):
        cases = {
            "uppercase secret": dict(secret="AB" * 32),
            "short secret": dict(secret="ab" * 31 + "a"),
            "long key": dict(key=KEY + "0"),
            "non hex key": dict(key="zz" * 32),
            "plain http relay": dict(url="http://relay.example.com"),
            "credentials in url": dict(url="https://user:pw@relay.example.com"),
            "query in url": dict(url="https://relay.example.com/?x=1"),
            "file url": dict(url="file:///etc/passwd"),
            "future version": dict(version=2),
            "string version": dict(version="1"),
            "bool version": dict(version=True),
        }
        for label, change in cases.items():
            logs = []
            home = Path(tempfile.mkdtemp())
            self.addCleanup(shutil.rmtree, home, True)
            paths = tn.Paths(home)
            args = dict(change)
            if "version" in args:
                path = write_pairing(paths)
                data = json.loads(path.read_text())
                data["version"] = args["version"]
                path.write_text(json.dumps(data))
            else:
                write_pairing(paths, **args)
            self.assertEqual(tn.PairingStore(paths.pairings, logs.append).load(), [], label)
            self.assertTrue(logs, label)
            for value in change.values():
                if isinstance(value, str) and len(value) > 8:
                    self.assertNotIn(value, "\n".join(logs), label)

    def test_local_http_relay_is_allowed(self):
        for url in ("http://127.0.0.1:8787", "http://localhost:8787/", "http://[::1]:8787"):
            self.assertIsNotNone(tn.relay_url(url), url)
        self.assertEqual(tn.relay_url("https://relay.example.com/base/"), "https://relay.example.com/base")
        self.assertIsNone(tn.relay_url("http://127.0.0.1.evil.example"))
        self.assertIsNone(tn.relay_url("https://relay.example.com:notaport"))
        self.assertIsNone(tn.relay_url(None))

    def test_not_json_and_not_object(self):
        self.paths.pairings.mkdir(mode=0o700, parents=True)
        for index, content in enumerate(("{oops", "[]", "", "null")):
            (self.paths.pairings / ("f%d.json" % index)).write_text(content)
        self.assertEqual(self.store.load(), [])
        self.assertEqual(len(self.store.problems), 4)

    def test_wide_permissions_are_tightened(self):
        path = write_pairing(self.paths)
        path.chmod(0o644)
        self.paths.pairings.chmod(0o755)
        self.assertEqual(len(self.store.load()), 1)
        self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(self.paths.pairings.stat().st_mode), 0o700)

    def test_symlink_is_ignored(self):
        real = write_pairing(self.paths, name="r" * 64)
        link = self.paths.pairings / ("l" * 64 + ".json")
        link.symlink_to(real)
        self.assertEqual([p.id for p in self.store.load()], ["r" * 64])

    def test_changed_file_is_reread_and_missing_directory_is_empty(self):
        path = write_pairing(self.paths)
        self.assertEqual(self.store.load()[0].secret, SECRET)
        path.write_text(json.dumps({"version": 1, "relay_url": "https://r.example", "secret": SECRET_B, "routing_key": KEY, "pad": "x"}))
        self.assertEqual(self.store.load()[0].secret, SECRET_B)
        shutil.rmtree(self.paths.pairings)
        self.assertEqual(self.store.load(), [])
        self.assertFalse(self.store.readable)

    def test_a_pairing_file_broken_for_a_moment_does_not_repeat_its_push(self):
        h = Harness(self)
        path = write_pairing(h.paths)
        good = path.read_bytes()
        h.output = agent_line()
        h.tick(1006.0)
        path.write_text("{half written")
        h.tick(1010.0)
        path.write_bytes(good)
        h.tick(1020.0)
        self.assertEqual(len(h.posts), 1)

    def test_repr_hides_secrets(self):
        pairing = tn.parse_pairing("p", {"version": 1, "relay_url": "https://r.example", "secret": SECRET, "routing_key": KEY})
        self.assertNotIn(SECRET, repr(pairing))
        self.assertNotIn(KEY, repr(pairing))

    def test_temporarily_unreadable_directory_keeps_sent_records(self):
        h = Harness(self)
        write_pairing(h.paths)
        h.output = agent_line()
        h.tick(1006.0)
        saved = h.paths.pairings.with_name("moved")
        h.paths.pairings.rename(saved)
        h.tick(1010.0)
        saved.rename(h.paths.pairings)
        h.tick(1020.0)
        self.assertEqual(len(h.posts), 1)


class Relay:
    """A local HTTP relay recording requests; `respond(handler)` returns (status, headers)."""

    def __init__(self):
        self.requests = []
        self.respond = lambda handler: (200, {})
        relay = self

        class Handler(BaseHTTPRequestHandler):
            def do_POST(self):
                body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
                relay.requests.append((self.path, dict(self.headers), body))
                status, headers = relay.respond(self)
                self.send_response(status)
                for key, value in headers.items():
                    self.send_header(key, value)
                self.send_header("Content-Length", "0")
                self.end_headers()

            def log_message(self, *args):
                pass

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.url = "http://127.0.0.1:%d" % self.server.server_address[1]
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def close(self):
        self.server.shutdown()
        self.server.server_close()


class HttpTests(unittest.TestCase):
    def setUp(self):
        self.relay = Relay()
        self.addCleanup(self.relay.close)

    def pairing(self, url=None):
        return tn.parse_pairing("p", {"version": 1, "relay_url": url or self.relay.url, "secret": SECRET, "routing_key": KEY})

    def test_posts_exact_json_to_notify(self):
        body = {"secret": SECRET, "session_ref": "00" * 32, "kind": "done"}
        self.assertEqual(tn.http_post(self.pairing(), body).status, 200)
        [(path, headers, raw)] = self.relay.requests
        self.assertEqual(path, "/notify")
        self.assertEqual(json.loads(raw), body)
        self.assertEqual(headers["Content-Type"], "application/json")
        self.assertNotIn(socket_hostname(), "".join("%s%s" % kv for kv in headers.items()))

    def test_base_path_is_kept(self):
        tn.http_post(self.pairing(self.relay.url + "/v1/"), {"secret": SECRET, "session_ref": "0" * 64, "kind": "ask"})
        self.assertEqual(self.relay.requests[0][0], "/v1/notify")

    def test_429_carries_retry_after(self):
        self.relay.respond = lambda h: (429, {"Retry-After": "17"})
        result = tn.http_post(self.pairing(), {"secret": SECRET, "session_ref": "0" * 64, "kind": "ask"})
        self.assertEqual((result.status, result.retry_after), (429, 17.0))

    def test_bad_retry_after_is_ignored(self):
        for value in ("soon", "nan", "inf"):
            self.relay.respond = lambda h, v=value: (429, {"Retry-After": v})
            result = tn.http_post(self.pairing(), {"secret": SECRET, "session_ref": "0" * 64, "kind": "ask"})
            self.assertIsNone(result.retry_after, value)

    def test_redirect_is_not_followed_so_the_secret_goes_nowhere_else(self):
        elsewhere = Relay()
        self.addCleanup(elsewhere.close)
        self.relay.respond = lambda h: (307, {"Location": elsewhere.url + "/stolen"})
        result = tn.http_post(self.pairing(), {"secret": SECRET, "session_ref": "0" * 64, "kind": "ask"})
        self.assertEqual(result.status, 307)
        self.assertEqual(elsewhere.requests, [])

    def test_unreachable_relay_reports_a_class_not_the_url(self):
        dead = Relay()
        url = dead.url
        dead.close()
        result = tn.http_post(self.pairing(url), {"secret": SECRET, "session_ref": "0" * 64, "kind": "ask"}, timeout=2)
        self.assertIsNone(result.status)
        self.assertNotIn(url, result.error)
        self.assertNotIn(SECRET, result.error)


def socket_hostname():
    import socket

    return socket.gethostname()


class ServiceFilesTests(unittest.TestCase):
    def setUp(self):
        self.home = Path(tempfile.mkdtemp(prefix="home dir "))
        self.addCleanup(shutil.rmtree, self.home, True)
        saved = os.environ.pop("XDG_CONFIG_HOME", None)
        if saved is not None:
            self.addCleanup(os.environ.__setitem__, "XDG_CONFIG_HOME", saved)
        self.paths = tn.Paths(self.home)
        self.calls = []
        self.fail = lambda command: False

    def runner(self, command, **_):
        self.calls.append(command)
        failed = self.fail(command)
        out = "Linger=yes\n" if command[:2] == ["loginctl", "show-user"] else ""
        return subprocess.CompletedProcess(command, 1 if failed else 0, out, "")

    def args(self, **kw):
        return type("Args", (), {"no_start": False, "purge": False, **kw})()

    def install(self, system, **kw):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = tn.cmd_install(self.args(**kw), self.paths, system, self.runner, "/usr/bin/env", lambda _: None)
        return code, out.getvalue()

    def uninstall(self, system, **kw):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = tn.cmd_uninstall(self.args(**kw), self.paths, system, self.runner)
        return code, out.getvalue()

    def modes(self, path):
        return stat.S_IMODE(path.stat().st_mode)

    def test_macos_install_writes_private_launch_agent(self):
        import plistlib

        code, _ = self.install("macos")
        self.assertEqual(code, 0)
        plist = plistlib.loads(self.paths.plist.read_bytes())
        self.assertEqual(plist["Label"], "dev.nategriffin.term.notify")
        self.assertEqual(plist["ProgramArguments"], ["/usr/bin/env", str(self.paths.program), "run"])
        self.assertTrue(plist["RunAtLoad"])
        self.assertEqual(plist["KeepAlive"], {"SuccessfulExit": False})
        self.assertEqual(self.modes(self.paths.plist), 0o600)
        self.assertEqual(self.modes(self.paths.program), 0o700)
        self.assertEqual(self.modes(self.paths.data), 0o700)
        self.assertEqual(self.modes(self.paths.pairings), 0o700)
        self.assertEqual(self.paths.program.read_bytes(), PROGRAM.read_bytes())
        uid = os.getuid()
        self.assertIn(["launchctl", "bootstrap", "gui/%d" % uid, str(self.paths.plist)], self.calls)

    def test_macos_falls_back_to_user_domain_then_warns_but_keeps_files(self):
        self.fail = lambda c: c[:2] == ["launchctl", "bootstrap"] and c[2].startswith("gui/")
        code, out = self.install("macos")
        self.assertEqual(code, 0)
        self.assertIn(["launchctl", "bootstrap", "user/%d" % os.getuid(), str(self.paths.plist)], self.calls)
        self.assertNotIn("warning: launchctl", out)
        self.calls.clear()
        self.fail = lambda c: c[:2] == ["launchctl", "bootstrap"]
        code, out = self.install("macos")
        self.assertEqual(code, 0)
        self.assertIn("warning: launchctl could not load it now", out)
        self.assertTrue(self.paths.plist.exists())

    def test_linux_install_writes_user_unit_with_quoted_paths(self):
        code, out = self.install("linux")
        self.assertEqual(code, 0)
        unit = self.paths.unit.read_text()
        self.assertEqual(self.paths.unit, self.home / ".config/systemd/user/term-notify.service")
        self.assertIn('ExecStart="/usr/bin/env" "%s" run' % self.paths.program, unit)
        self.assertIn("Restart=on-failure", unit)
        self.assertIn("WantedBy=default.target", unit)
        self.assertEqual(self.modes(self.paths.unit), 0o600)
        self.assertEqual(
            [c[2:] for c in self.calls if c[:2] == ["systemctl", "--user"]],
            [["daemon-reload"], ["enable", "term-notify.service"], ["restart", "term-notify.service"]],
        )

    def test_systemd_quote_escapes_specifiers(self):
        self.assertEqual(tn.systemd_quote('a "b" %h $x\\'), '"a \\"b\\" %%h $$x\\\\"')

    def test_linux_without_user_manager_warns_with_the_next_step(self):
        self.fail = lambda c: c[0] == "systemctl"
        code, out = self.install("linux")
        self.assertEqual(code, 0)
        self.assertIn("systemctl --user enable --now term-notify.service", out)

    def test_linger_off_is_called_out(self):
        original = tn.linger_enabled
        tn.linger_enabled = lambda runner: False
        self.addCleanup(setattr, tn, "linger_enabled", original)
        _, out = self.install("linux")
        self.assertIn("loginctl enable-linger", out)

    def test_no_start_touches_no_service_manager(self):
        self.install("macos", no_start=True)
        self.assertEqual([c for c in self.calls if c[0] in ("launchctl", "systemctl")], [])
        self.assertTrue(self.paths.plist.exists())

    def test_install_twice_is_stable_and_leaves_pairings_alone(self):
        pairing = write_pairing(self.paths)
        before = pairing.read_bytes()
        self.install("linux")
        first = self.paths.unit.read_bytes()
        self.install("linux")
        self.assertEqual(self.paths.unit.read_bytes(), first)
        self.assertEqual(pairing.read_bytes(), before)

    def test_uninstall_removes_what_install_made_and_keeps_pairings(self):
        unrelated = self.home / ".local/share/term/other.txt"
        unrelated.parent.mkdir(parents=True)
        unrelated.write_text("mine")
        pairing = write_pairing(self.paths)
        for system in ("macos", "linux"):
            self.install(system)
            self.paths.state.write_text("{}")
            (self.paths.data / ".state.json.tmp123").write_text("{}")
            code, out = self.uninstall(system)
            self.assertEqual(code, 0)
            for path in (self.paths.plist, self.paths.unit, self.paths.program, self.paths.state, self.paths.lock):
                self.assertFalse(path.exists(), path)
            self.assertFalse(self.paths.data.exists())
            self.assertTrue(pairing.exists())
            self.assertIn("--purge", out)
            self.assertEqual(unrelated.read_text(), "mine")

    def test_purge_removes_only_pairing_json(self):
        write_pairing(self.paths)
        (self.paths.pairings / "keep.txt").write_text("x")
        self.install("linux")
        self.uninstall("linux", purge=True)
        self.assertEqual([p.name for p in self.paths.pairings.iterdir()], ["keep.txt"])

    def test_install_uninstall_removes_only_created_directories(self):
        for system in ("macos", "linux"):
            with self.subTest(system=system):
                self.install(system)
                self.install(system)
                self.uninstall(system)
                self.assertEqual(list(self.home.iterdir()), [])

    def test_preexisting_empty_directories_survive_uninstall(self):
        for directory in (self.paths.data, self.paths.pairings, self.paths.plist.parent, self.paths.log.parent,
                          self.paths.unit.parent):
            directory.mkdir(parents=True, exist_ok=True)
        before = set(self.home.rglob("*"))
        for system in ("macos", "linux"):
            self.install(system)
            self.uninstall(system, purge=True)
            self.assertEqual(set(self.home.rglob("*")), before)

    def test_unrelated_file_keeps_a_created_directory(self):
        self.install("macos")
        unrelated = self.paths.log.parent / "another-app.log"
        unrelated.write_text("keep")
        self.uninstall("macos")
        self.assertEqual(unrelated.read_text(), "keep")

    def test_cli_roundtrip_uses_stubbed_services(self):
        environment = dict(os.environ, HOME=str(self.home))
        stub_directory = Path(os.environ["PATH"].split(os.pathsep)[0])
        for command in ("install", "uninstall"):
            result = subprocess.run([sys.executable, str(PROGRAM), command], env=environment,
                                    capture_output=True, text=True, timeout=15)
            self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(list(self.home.iterdir()), [])
        self.assertTrue((stub_directory / "calls").exists())

    def test_uninstall_when_nothing_is_installed(self):
        code, out = self.uninstall("linux")
        self.assertEqual((code, out.strip()), (0, "nothing to remove"))

    def test_uninstall_stops_the_service_before_removing_files(self):
        self.install("linux")
        self.calls.clear()
        self.uninstall("linux")
        self.assertEqual(self.calls[0], ["systemctl", "--user", "disable", "--now", "term-notify.service"])


class StatusAndLockTests(unittest.TestCase):
    def test_second_instance_cannot_take_the_lock(self):
        home = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, home, True)
        paths = tn.Paths(home)
        first = tn.acquire_lock(paths)
        self.assertIsNotNone(first)
        self.assertIsNone(tn.acquire_lock(paths))
        os.close(first)
        second = tn.acquire_lock(paths)
        self.assertIsNotNone(second)
        os.close(second)

    def test_status_is_unhealthy_without_pairings_and_healthy_with_everything(self):
        home = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, home, True)
        paths = tn.Paths(home)
        answers = {"systemctl": "active\n", "launchctl": "state = running\n", "loginctl": "Linger=yes\n"}
        running = lambda command, **_: subprocess.CompletedProcess(command, 0, answers[command[0]], "")
        args = type("A", (), {})()
        with tmux_on_path(self), contextlib.redirect_stdout(io.StringIO()) as out:
            self.assertEqual(tn.cmd_status(args, paths, "linux", running), 1)
            self.assertIn("pairings: none", out.getvalue())
            write_pairing(paths)
        with tmux_on_path(self), contextlib.redirect_stdout(io.StringIO()) as out:
            self.assertEqual(tn.cmd_status(args, paths, "macos", running), 0)
            self.assertIn("-> relay.example.com", out.getvalue())
            self.assertNotIn(SECRET, out.getvalue())


@contextlib.contextmanager
def tmux_on_path(test):
    fake = Path(tempfile.mkdtemp())
    test.addCleanup(shutil.rmtree, fake, True)
    script = fake / "tmux"
    script.write_text("#!/bin/sh\n")
    script.chmod(0o755)
    old = os.environ.get("TERM_NOTIFY_TMUX")
    os.environ["TERM_NOTIFY_TMUX"] = str(script)
    try:
        yield
    finally:
        if old is None:
            os.environ.pop("TERM_NOTIFY_TMUX")
        else:
            os.environ["TERM_NOTIFY_TMUX"] = old


@unittest.skipUnless(shutil.which("tmux"), "tmux is not installed")
class RealTmuxTests(unittest.TestCase):
    """The real program against a private tmux server and a local relay."""

    def setUp(self):
        self.socket = "termnotify-test-%d" % os.getpid()
        self.home = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.home, True)
        self.paths = tn.Paths(self.home)
        self.relay = Relay()
        self.addCleanup(self.relay.close)
        write_pairing(self.paths, url=self.relay.url)
        # No UTF-8 locale, like a LaunchAgent: only tmux -u keeps the non-ASCII session name intact.
        self.env = {k: v for k, v in os.environ.items() if k not in ("TMUX", "LANG", "LC_ALL", "LC_CTYPE")}
        self.env.update(HOME=str(self.home), LC_ALL="C")
        self.addCleanup(self.tmux, "kill-server", check=False)
        self.processes = []

    def tmux(self, *args, check=True):
        result = subprocess.run(["tmux", "-u", "-L", self.socket, *args], capture_output=True, text=True, env=self.env)
        if check and result.returncode:
            self.fail("tmux %s: %s" % (args, result.stderr))
        return result.stdout.strip()

    def start(self, command="run", *extra):
        process = subprocess.Popen([sys.executable, str(PROGRAM), command, "--tmux-socket", self.socket, *extra],
                                   env=self.env, stderr=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        self.processes.append(process)
        self.addCleanup(self.stop, process)
        return process

    def stop(self, process):
        if process.poll() is not None:
            return
        process.send_signal(signal.SIGTERM)
        try:
            process.communicate(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
            process.communicate()

    def session(self, name):
        self.tmux("new-session", "-d", "-s", name, "-x", "80", "-y", "24")
        return self.tmux("display-message", "-p", "-t", name, "#{pane_id}")

    def stop_pane(self, pane, at=None, state="ask", heartbeat=None):
        at = at if at is not None else time.time()
        payload = {"v": 1, "state": state, "since": at, "t": heartbeat or at, "stop": {"at": at, "why": state},
                   "title": "private title", "q": "private question"}
        self.tmux("set-option", "-p", "-t", pane, "@agent", json.dumps(payload))
        return at

    def expected_ref(self, session, pane):
        info = self.tmux("display-message", "-p", "-t", pane, "#{start_time}\t#{pid}").split("\t")
        import hashlib, hmac

        message = "\0".join([session, pane, info[0], info[1]]).encode("utf-8")
        return hmac.new(bytes.fromhex(KEY), message, hashlib.sha256).hexdigest()

    def wait_for(self, count, timeout=15):
        end = time.time() + timeout
        while time.time() < end and len(self.relay.requests) < count:
            time.sleep(0.1)
        return len(self.relay.requests)

    def test_watches_all_panes_debounces_respects_seen_and_ignores_heartbeats(self):
        first = self.session("café")
        process = self.start("run", "--debounce", "1.5", "--interval", "0.2")
        at = self.stop_pane(first)
        self.assertEqual(self.wait_for(1), 1)
        # heartbeats rewrite the payload without a new stop
        for beat in range(6):
            self.stop_pane(first, at=at, heartbeat=time.time())
            time.sleep(0.3)
        # an answer inside the debounce window keeps the phone quiet
        quiet = self.session("quiet")
        stopped = self.stop_pane(quiet)
        self.tmux("set-option", "-t", "quiet", "@seen", repr(stopped + 0.5))
        time.sleep(3.0)
        self.assertEqual(len(self.relay.requests), 1)
        # a pane created later is still handled
        later = self.session("other")
        self.stop_pane(later, state="done")
        self.assertEqual(self.wait_for(2), 2)
        time.sleep(1.0)
        self.assertEqual(len(self.relay.requests), 2)
        sent = [json.loads(raw) for _, _, raw in self.relay.requests]
        for body in sent:
            self.assertEqual(sorted(body), ["kind", "secret", "session_ref"])
        self.assertEqual({b["session_ref"] for b in sent},
                         {self.expected_ref("café", first), self.expected_ref("other", later)})
        self.assertEqual({b["kind"] for b in sent}, {"ask", "done"})
        process.send_signal(signal.SIGTERM)
        out, err = process.communicate(timeout=10)
        self.assertEqual(process.returncode, 0)
        for private in (SECRET, KEY, "café", "private title", "private question", "quiet", "other", first, later):
            self.assertNotIn(private, err + out)
        self.assertEqual(stat.S_IMODE(self.paths.state.stat().st_mode), 0o600)

    def test_a_second_process_after_restart_repeats_nothing(self):
        pane = self.session("work")
        self.stop_pane(pane, at=time.time() - 10)
        for expected in (1, 0):
            process = self.start("once", "--debounce", "1")
            out, _ = process.communicate(timeout=20)
            self.assertEqual(process.returncode, 0, out)
            self.assertIn("pushed %d, failed 0" % expected, out)
        self.assertEqual(len(self.relay.requests), 1)

    def test_no_tmux_server_is_quiet_and_not_an_error(self):
        process = self.start("once")
        out, err = process.communicate(timeout=20)
        self.assertEqual((process.returncode, out.strip()), (0, "pushed 0, failed 0"))
        self.assertNotIn("tmux", err)

    def test_second_run_refuses_while_one_is_watching(self):
        first = self.start("run", "--interval", "0.2")
        time.sleep(1.0)
        second = self.start("run")
        _, err = second.communicate(timeout=10)
        self.assertEqual(second.returncode, 1)
        self.assertIn("already running", err)
        self.assertIsNone(first.poll())


if __name__ == "__main__":
    unittest.main()
