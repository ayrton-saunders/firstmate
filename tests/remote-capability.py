"""Inactive 3a owner fixtures. No service/backend/fleet action.

The fixture activates ONLY private temporary records, never through production
code. The installed inspection path stays closed on real reserved enrollments.
The out-of-application runner below models a local exec trampoline, not a
qualified agent adapter or integration of existing launch/source owners.
"""
import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
import uuid

ROOT, SCRATCH = (Path(p).resolve() for p in sys.argv[1:3])
del sys.argv[1:3]
sys.dont_write_bytecode = True
SPEC = importlib.util.spec_from_file_location("enrollment", ROOT / "bin/fm-remote-enrollment.py")
e = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(e)
SOURCE = (ROOT / "bin/fm-remote-enrollment.py").read_bytes()
ORIGIN = "3e1d20a8" + "0" * 32
BUNDLE = e.bundle_bytes(SOURCE, ORIGIN)[0]
PYTHON = str(Path(sys.executable).resolve())


def encode(request):
    value = dict(request)
    value.pop("request_digest", None)
    value["request_digest"] = e.digest(value)
    return e.canonical(value)


class Capability(unittest.TestCase):
    def setUp(self):
        self.folder = Path(tempfile.mkdtemp(dir=SCRATCH)).resolve()
        self.base = self.folder / "authority"
        e.initialize(self.base)
        self.root, self.home = self.folder / "root", self.folder / "home"
        for path in (self.root, self.home, self.root / "bin"):
            path.mkdir(mode=0o700)
        for path in (self.root, self.home):
            subprocess.run(["git", "init", "-q", str(path)], check=True, capture_output=True)
        request = dict(name="lane-a", binding=str(uuid.uuid4()), fleet=str(uuid.uuid4()), route="route:a",
                       root=str(self.root), home=str(self.home), backend="herdr", session="fixture-only",
                       socket=str(self.folder / "socket"), service="dev.fixture.a", commit="a" * 40)
        self.entry = e.reserve(self.base, request, BUNDLE, PYTHON)
        e.install(self.base, "lane-a", SOURCE, ORIGIN)
        e.resume(self.base, "lane-a")
        self.location = e.instance(self.base, "lane-a")
        self.operands = {"root": str(self.root), "home": str(self.home)}
        self.environment = dict(os.environ)
        for key in ("FM_HOME", "FM_ROOT_OVERRIDE", "FM_STATE_OVERRIDE", "FM_REMOTE_JOB_STATE_OVERRIDE"):
            os.environ.pop(key, None)
        self.fixture_activate()

    def tearDown(self):
        os.environ.clear()
        os.environ.update(self.environment)
        shutil.rmtree(self.folder)

    def fixture_activate(self):
        # Deliberate test-only projection writer. Not exported by bin/ or loader.
        record = e.inventory(self.base)
        entry = record["payload"]["entries"]["lane-a"]
        entry["state"] = "active"
        entry["revision"] += 1
        e.seal_claim(entry)
        e.publish(self.base / "claims.json", "claims", record["revision"] + 1, record["payload"])
        gate = e.snapshot(self.location / "gate.json", "gate")
        gate["payload"].update(state="released", owner=None, generation=1)
        e.publish(self.location / "gate.json", "gate", gate["revision"] + 1, gate["payload"])

    def request(self, verb="observe", body=None, **changes):
        manifest = e.claim(self.base, "lane-a")["manifest"]
        gate = e.snapshot(self.location / "gate.json", "gate")["payload"]
        value = dict(version=2, instance="lane-a", binding=manifest["binding"], fleet=manifest["fleet"],
                     route=manifest["route"], generation=gate["generation"], expected_commit=manifest["commit"],
                     request_id=uuid.uuid4().hex, verb=verb, typed_body={} if body is None else body)
        value.update(changes)
        return encode(value)

    def gate(self, state):
        with e.admission(self.base, "lane-a") as (_entry, gate):
            gate["payload"]["state"] = state
            gate["payload"]["owner"] = "fixture-update" if state == "fenced" else None
            e.publish(self.location / "gate.json", "gate", gate["revision"] + 1, gate["payload"])

    def reserve(self, data, code, kind="shell-entry"):
        request = json.loads(data)
        request.update(verb="launch", typed_body={"task": "task-1", "reader": kind, "launch_digest": hashlib.sha256(code).hexdigest()})
        data = encode(request)
        e.stage_request(self.base, "lane-a", data, self.operands)
        return e.reserve_execution(self.base, "lane-a", data, self.operands, hashlib.sha256(code).hexdigest())

    def write_entry(self, kind, content):
        path = self.root / e.READER_ENTRIES[kind]
        path.write_bytes(content)
        path.chmod(0o600)
        return path

    def fixture_move(self, path, content):
        # Minimal serialized mutation fixture, NOT an update implementation.
        # It uses the real owner's no-reader predicate while holding admission
        # through file and generation publication. No fence snapshot/drain.
        with e.admission(self.base, "lane-a") as (_entry, gate):
            e.require_no_application_readers(self.base, "lane-a")
            replacement = path.with_suffix(".replacement")
            replacement.write_bytes(content)
            replacement.chmod(0o600)
            os.replace(replacement, path)
            gate["payload"]["generation"] += 1
            e.publish(self.location / "gate.json", "gate", gate["revision"] + 1, gate["payload"])

    def driver(self):
        # Fixed trusted fixture launcher OUTSIDE root/home. It verifies accepted
        # bundle bytes before entering its reader owner. No production override,
        # fixture switch, arbitrary application path, or executor is installed.
        path = self.folder / "installed-fixture-launcher.py"
        path.write_text("""import hashlib, json, os, sys
from pathlib import Path
base, name, kind, envelope, manifest = sys.argv[1:6]
location = Path(base) / 'instances' / name
bundle = location / 'bundles' / %r / 'enrollment.py'
code = bundle.read_bytes()
if hashlib.sha256(code).hexdigest() != %r:
    raise SystemExit(126)
ns = {'__name__': 'installed_fixture'}
exec(compile(code, str(bundle), 'exec'), ns)
try:
    data = Path(envelope).read_bytes()
    operands = {key: str(Path(base).parent / key) for key in ('root', 'home')}
    ns['stage_request'](Path(base), name, data, operands)
    nonce = ns['reserve_execution'](Path(base), name, data, operands, manifest)
    if sys.argv[6:] == ['pause-before-read']:
        print('reserved-before-read', flush=True)
        sys.stdin.readline()
    loaded = ns['read_registered_application'](Path(base), name, nonce, kind, operands)
    # Execute ONLY the freshly selected bytes. This is a bounded fixture body,
    # not a real backend/agent or an inherited consumer qualification.
    exec(compile(loaded, '<fresh-application>', 'exec'), {'__name__': '__main__'})
except (ValueError, OSError) as exc:
    print('fixture admission refused: ' + str(exc), file=sys.stderr)
    raise SystemExit(126)
""" % (BUNDLE, hashlib.sha256(SOURCE).hexdigest()))
        return path

    def test_typed_vocabulary_and_refused_neighbours(self):
        samples = {
            "observe": {}, "probe": {"challenge": "fresh"},
            "reply-read": {"task": "task-1", "correlation": "reply-1"},
            "reply-ack": {"task": "task-1", "correlation": "reply-1", "result_digest": "0" * 64},
            "task-answer": {"task": "task-1", "correlation": "reply-1", "text": "answer"},
            "task-steer": {"task": "task-1", "correlation": "reply-1", "text": "steer"},
            "inherit-apply": {"material": "captain-shared", "content": "private", "content_digest": hashlib.sha256(b"private").hexdigest()},
            "sync-verify": {"parent_commit": "a" * 40},
            "dispatch": {"task": "task-1", "instructions_digest": "0" * 64},
            "launch": {"task": "task-1", "reader": "shell-entry", "launch_digest": "0" * 64},
            "relaunch": {"task": "task-1", "incarnation": "inc-1", "launch_digest": "0" * 64},
            "stop": {"task": "task-1", "incarnation": "inc-1"},
            "cleanup": {"task": "task-1", "incarnation": "inc-1"},
            "repair-accepted": {"resource": "worker-projection", "accepted_commit": "a" * 40},
            "update-prepare": {"operation": "op-1", "target_commit": "b" * 40, "source_digest": "0" * 64, "resources_digest": "1" * 64},
            "operation-step": {"operation": "op-1", "transition": "fence", "expected_revision": 1},
            "operation-status": {"operation": "op-1"},
            "abort-before-stop": {"operation": "op-1", "expected_revision": 1},
        }
        expected_classes = {
            "observe": "observe",
            "probe": "observe",
            "reply-read": "reply-read",
            "reply-ack": "reply-ack",
            "task-answer": "task-answer",
            "task-steer": "task-steer",
            "inherit-apply": "inherit",
            "sync-verify": "verify",
            "dispatch": "dispatch",
            "launch": "launch",
            "relaunch": "relaunch",
            "stop": "stop",
            "cleanup": "cleanup",
            "repair-accepted": "repair",
            "update-prepare": "prepare",
            "operation-step": "transition",
            "operation-status": "operation-status",
            "abort-before-stop": "abort",
        }
        self.assertEqual(set(samples), set(expected_classes))
        self.assertEqual(set(expected_classes), set(e.VERBS))
        for verb, body in samples.items():
            with self.subTest(verb=verb):
                data = self.request(verb, body)
                self.assertEqual(e.request_class(e.typed_request(data)), expected_classes[verb])
                # Parsing/derivation alone never executes this capability.
                if verb not in {"observe", "probe", "sync-verify"}:
                    with self.assertRaisesRegex(e.Refusal, "owner not enabled"):
                        e.inspect_request(self.base, "lane-a", data)
                for neighbour in ("argv", "script", "home", "root", "capability", "operation_class"):
                    with self.assertRaises(e.Refusal):
                        e.typed_request(self.request(verb, dict(body, **{neighbour: "injected"})))
        for verb in ("fm-update.sh", "ff_target", "provision", "account-reap", "hook-install", "sync/update", "fm-arbitrary.sh"):
            with self.assertRaises(e.Refusal):
                e.typed_request(self.request(verb))

    def test_strict_envelope_and_digest_at_each_boundary(self):
        good = self.request()
        for data in (good[:-1], good + b" trailing", b"{" + b" " * e.REQUEST_LIMIT + b"}",
                     good.replace(b'"version":2', b'"version":2,"version":2'),
                     good.replace(b'"typed_body":{}', b'"typed_body":{"expectations":{"home":"/x","home":"/y"}}'),
                     good.replace(b'"route:a"', b'"route:a\\u0000"'), good.decode().encode("utf-16")):
            with self.assertRaises(e.Refusal):
                e.typed_request(data)
        for key, value in (("version", True), ("generation", True), ("generation", -1), ("generation", 2**60),
                           ("binding", "not-a-uuid"), ("instance", "legacy"), ("request_id", "../escape"),
                           ("expected_commit", "a" * 39), ("authority", "injected")):
            with self.assertRaises(e.Refusal):
                e.typed_request(self.request(**{key: value}))
        for body in ({"task": "t", "correlation": "c", "text": "\ud800"},
                     {"task": "t", "correlation": "c", "text": "x" * (e.TEXT_LIMIT + 1)}):
            with self.assertRaises(e.Refusal):
                e.typed_request(self.request("task-answer", body))
        bad = json.loads(good)
        bad["request_digest"] = "0" * 64
        for operation in (lambda: e.stage_request(self.base, "lane-a", e.canonical(bad), self.operands),
                          lambda: e.reserve_execution(self.base, "lane-a", e.canonical(bad), self.operands, "0" * 64),
                          lambda: e.verify_result(e.canonical(bad), {})):
            with self.assertRaisesRegex(e.Refusal, "digest mismatch"):
                operation()
        result = e.inspect_request(self.base, "lane-a", good)
        self.assertEqual(e.verify_result(good, result), result)
        result["request_digest"] = "1" * 64
        with self.assertRaises(e.Refusal):
            e.verify_result(good, result)

    def test_resources_lineage_and_positional_arguments(self):
        data = self.request(body={"expectations": self.operands})
        checked = e.typed_request(data)
        self.assertEqual(e.adapter_expectations(checked, "route:a", str(self.home)), checked)
        for route, home in (("other", str(self.home)), ("route:a", "/other")):
            with self.assertRaises(e.Refusal):
                e.adapter_expectations(checked, route, home)
        for flag in (None, "0", "1", "spoof"):
            if flag is None:
                os.environ.pop("FM_REMOTE_JOB_ACTIVE", None)
            else:
                os.environ["FM_REMOTE_JOB_ACTIVE"] = flag
            with self.assertRaisesRegex(e.Refusal, "missing installed registration"):
                e.read_registered_application(self.base, "lane-a", None, "shell-entry", self.operands)
        for key in ("FM_ROOT_OVERRIDE", "FM_STATE_OVERRIDE", "FM_REMOTE_JOB_STATE_OVERRIDE", "FM_HOME"):
            os.environ[key] = str(self.folder)
            try:
                with self.assertRaises(e.Refusal):
                    e.inspect_request(self.base, "lane-a", data)
            finally:
                del os.environ[key]
        for role in ("root", "home"):
            foreign = self.folder / ("foreign-" + role)
            foreign.mkdir(mode=0o700)
            with self.assertRaisesRegex(e.Refusal, "foreign physical"):
                e.stage_request(self.base, "lane-a", data, dict(self.operands, **{role: str(foreign)}))
            with self.assertRaisesRegex(e.Refusal, "expectation mismatch"):
                e.stage_request(self.base, "lane-a", self.request(body={"expectations": {role: str(foreign)}}), self.operands)
        with self.assertRaisesRegex(e.Refusal, "update-required"):
            e.inspect_request(self.base, "lane-a", self.request("sync-verify", {"parent_commit": "b" * 40}))
        self.assertEqual(e.claim(self.base, "lane-a")["manifest"]["commit"], "a" * 40)

    def test_registration_before_application_read_and_claim_race(self):
        for kind in e.READER_ENTRIES:
            with self.subTest(kind=kind):
                # Missing application file is intentional: an unregistered
                # caller must be rejected by the owner BEFORE touching it.
                with self.assertRaisesRegex(e.Refusal, "missing installed registration"):
                    e.read_registered_application(self.base, "lane-a", None, kind, self.operands)
                content = b"print('A')\n"
                path = self.write_entry(kind, content)
                data = self.request()
                nonce = self.reserve(data, content, kind)
                with self.assertRaisesRegex(e.Refusal, "prevents movement"):
                    self.fixture_move(path, b"print('M')\n")
                self.assertEqual(e.read_registered_application(self.base, "lane-a", nonce, kind, self.operands), content)
                with self.assertRaises(e.Refusal):
                    e.read_registered_application(self.base, "lane-a", nonce, kind, self.operands)
                # No timer or missing process clears even a completed read.
                with self.assertRaises(e.Refusal):
                    self.fixture_move(path, b"print('M')\n")
        queued = self.request()
        e.stage_request(self.base, "lane-a", queued, self.operands)
        self.gate("fenced")
        for action in (lambda: e.stage_request(self.base, "lane-a", self.request(), self.operands),
                       lambda: e.reserve_execution(self.base, "lane-a", queued, self.operands, "0" * 64)):
            with self.assertRaisesRegex(e.Refusal, "closed by fence"):
                action()

    def test_entry_before_read_installed_invocation_blocks_movement(self):
        content = b"print('A')\n"
        path = self.write_entry("shell-entry", content)
        request_path = self.folder / "request.json"
        request_path.write_bytes(self.request("launch", {"task": "task-1", "reader": "shell-entry", "launch_digest": hashlib.sha256(content).hexdigest()}))
        command = [PYTHON, "-I", "-S", str(self.driver()), str(self.base), "lane-a", "shell-entry",
                   str(request_path), hashlib.sha256(content).hexdigest(), "pause-before-read"]
        process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            self.assertEqual(process.stdout.readline(), "reserved-before-read\n")
            with self.assertRaisesRegex(e.Refusal, "prevents movement"):
                self.fixture_move(path, b"print('M')\n")
            output, error = process.communicate("resume\n", timeout=30)
            self.assertEqual(process.returncode, 0, error)
            self.assertEqual(output, "A\n")
            # Process exit (or a controller crash) does not release the lease.
            with self.assertRaisesRegex(e.Refusal, "prevents movement"):
                self.fixture_move(path, b"print('M')\n")
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate()

    def test_stale_or_fenced_reservation_never_opens_application(self):
        code = b"print('A')\n"
        nonce = self.reserve(self.request(), code)
        # The path does not exist. A gated/stale reader must still fail on its
        # registration rather than attempting the application open.
        self.gate("fenced")
        with self.assertRaisesRegex(e.Refusal, "closed by fence"):
            e.read_registered_application(self.base, "lane-a", nonce, "shell-entry", self.operands)
        self.gate("released")
        with e.admission(self.base, "lane-a") as (_entry, gate):
            gate["payload"]["generation"] += 1
            e.publish(self.location / "gate.json", "gate", gate["revision"] + 1, gate["payload"])
        with self.assertRaisesRegex(e.Refusal, "generation mismatch"):
            e.read_registered_application(self.base, "lane-a", nonce, "shell-entry", self.operands)

    def test_entry_before_read_old_interpreter_trampoline_and_negative_control(self):
        # Bash has opened A and may have buffered its tail. Pause before its
        # guard, atomically replace the entry by M and advance the fixture's
        # generation. A correct trampoline EXECs the installed outside runner;
        # it never returns to A's already-open descriptor/buffer.
        for kind in e.READER_ENTRIES:
            for broken in (False, True):
                with self.subTest(kind=kind, broken=broken):
                    # Each scenario has a new isolated enrollment/population.
                    nested = Capability(methodName="runTest")
                    nested.setUp()
                    try:
                        driver = nested.driver()
                        request_path = nested.folder / "request.json"
                        fresh = b"print('M')\n"
                        command = [PYTHON, "-I", "-S", str(driver), str(nested.base), "lane-a", kind,
                                   str(request_path), hashlib.sha256(fresh).hexdigest()]
                        import shlex
                        invocation = " ".join(shlex.quote(part) for part in command)
                        script = ("#!/usr/bin/env bash\nprintf 'opened\\n'\nIFS= read -r resume\n" +
                                  ("" if broken else "exec ") + invocation + "\nprintf 'A-buffered\\n'\n").encode()
                        path = nested.write_entry(kind, script)
                        process = subprocess.Popen([shutil.which("bash"), str(path)], stdin=subprocess.PIPE,
                                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                        try:
                            self.assertEqual(process.stdout.readline(), "opened\n")
                            nested.fixture_move(path, fresh)
                            request_path.write_bytes(nested.request("launch", {"task": "task-1", "reader": kind, "launch_digest": hashlib.sha256(fresh).hexdigest()}))
                            output, error = process.communicate("resume\n", timeout=30)
                            self.assertEqual(process.returncode, 0, error)
                            if broken:
                                with self.assertRaises(AssertionError):
                                    self.assertEqual(output, "M\n")
                                self.assertIn("A-buffered", output)
                            else:
                                self.assertEqual(output, "M\n")
                        finally:
                            if process.poll() is None:
                                process.kill()
                                process.communicate()
                    finally:
                        nested.tearDown()
        print("entry-before-read: installed exec discards A; returning in-script guard fails the same oracle")

    def test_removed_registration_and_post_fence_controls_fail_oracles(self):
        content = b"print('A')\n"
        path = self.write_entry("shell-entry", content)

        def unregistered_oracle(reader):
            with self.assertRaises(e.Refusal):
                reader(self.base, "lane-a", None, "shell-entry", self.operands)
        unregistered_oracle(e.read_registered_application)
        # Remove the admission boundary, not the oracle. A direct read now
        # succeeds, so the identical unregistered-caller oracle must fail.
        with self.assertRaises(AssertionError):
            unregistered_oracle(lambda *_args: e.read_bytes(path))
        data = self.request("launch", {"task": "task-1", "reader": "shell-entry", "launch_digest": hashlib.sha256(content).hexdigest()})
        e.stage_request(self.base, "lane-a", data, self.operands)
        self.gate("fenced")

        def fenced_oracle():
            with self.assertRaises(e.Refusal):
                e.reserve_execution(self.base, "lane-a", data, self.operands, hashlib.sha256(content).hexdigest())
        fenced_oracle()
        actual = e.request_authority

        def no_fence(entry, gate, request, operands):
            return actual(entry, dict(gate, payload=dict(gate["payload"], state="released")), request, operands)
        e.request_authority = no_fence
        try:
            with self.assertRaises(AssertionError):
                fenced_oracle()
        finally:
            e.request_authority = actual
        print("negative-controls: removed reader admission and post-fence registration fail acceptance oracles")

    def test_reader_kind_and_stored_request_digest_are_revalidated(self):
        content = b"print('A')\n"
        self.write_entry("shell-entry", content)
        self.write_entry("source-module", content)
        nonce = self.reserve(self.request(), content)
        with self.assertRaisesRegex(e.Refusal, "contradictory reader registration"):
            e.read_registered_application(self.base, "lane-a", nonce, "source-module", self.operands)
        with e.admission(self.base, "lane-a"):
            record = e.population(self.location)
            lease = record["payload"]["leases"][nonce]
            queued = record["payload"]["requests"][lease["request_id"]]
            queued["request"]["request_digest"] = "0" * 64
            e.save_population(self.location, record)
        with self.assertRaisesRegex(e.Refusal, "request digest mismatch"):
            e.read_registered_application(self.base, "lane-a", nonce, "shell-entry", self.operands)

    def test_observation_never_grants_application_read_and_manifest_is_bound(self):
        data = self.request()
        e.stage_request(self.base, "lane-a", data, self.operands)
        with self.assertRaisesRegex(e.Refusal, "no application reader"):
            e.reserve_execution(self.base, "lane-a", data, self.operands, "0" * 64)
        data = self.request("launch", {"task": "task-1", "reader": "shell-entry", "launch_digest": "1" * 64})
        e.stage_request(self.base, "lane-a", data, self.operands)
        with self.assertRaisesRegex(e.Refusal, "unbound application manifest"):
            e.reserve_execution(self.base, "lane-a", data, self.operands, "0" * 64)

    def test_installed_inspection_has_no_producer_or_fixture_override(self):
        ingress = str(self.location / "ingress")
        good = self.request()
        result = subprocess.run([ingress, "inspect-request"], input=good, capture_output=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        e.verify_result(good, json.loads(result.stdout))
        before = sorted(str(p.relative_to(self.folder)) for p in self.folder.rglob("*"))
        for verb in ("launch", "activate", "application", "enroll", "fixture-activate"):
            result = subprocess.run([ingress, verb], input=good, capture_output=True, timeout=30)
            self.assertEqual(result.returncode, 126)
        self.assertEqual(before, sorted(str(p.relative_to(self.folder)) for p in self.folder.rglob("*")))
        self.assertFalse((self.location / "population.json").exists())
        # Deactivate this fixture. Installed production invocation cannot turn
        # the reserved state into activity, irrespective of context flags.
        record = e.inventory(self.base)
        entry = record["payload"]["entries"]["lane-a"]
        entry["state"] = "reserved"
        entry["revision"] += 1
        e.seal_claim(entry)
        e.publish(self.base / "claims.json", "claims", record["revision"] + 1, record["payload"])
        result = subprocess.run([ingress, "inspect-request"], input=good, capture_output=True, timeout=30,
                                env=dict(os.environ, FM_REMOTE_JOB_ACTIVE="1", FM_FIXTURE="1"))
        self.assertEqual(result.returncode, 126)
        self.assertIn(b"inactive enrollment", result.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
