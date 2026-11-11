"""Behavioral stage-2 fixtures. Never invoke real SSH, launchd or Herdr.

Negative controls change callable policy in isolated subprocesses, not source
bytes. Each control must make the same acceptance oracle reject the result.
"""
import contextlib
import copy
import importlib.util
import json
import multiprocessing
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
import uuid

ROOT, SCRATCH = map(lambda p: Path(p).resolve(), sys.argv[1:3])
del sys.argv[1:3]
sys.dont_write_bytecode = True
SPEC = importlib.util.spec_from_file_location("enrollment", ROOT / "bin/fm-remote-enrollment.py")
e = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(e)
SOURCE = (ROOT / "bin/fm-remote-enrollment.py").read_bytes()
ORIGIN = "4c96fb169f0171c6a806275e180b0bd4bc7a255d"
BUNDLE = e.bundle_bytes(SOURCE, ORIGIN)[0]


def install(base, name):
    e.install(base, name, SOURCE, ORIGIN)
INTERPRETER = str(Path(sys.executable).resolve())
CTX = multiprocessing.get_context("fork")


def tree(path):
    """Read-only oracle includes inodes/modes/mtime/content, not read atime."""
    result = {}
    for item in [path, *sorted(path.rglob("*"))]:
        info = item.lstat()
        result[str(item.relative_to(path))] = (info.st_ino, info.st_mode, info.st_mtime_ns,
                                               item.read_bytes() if item.is_file() else None)
    return result


def race(base, a, b, broken=False):
    start = CTX.Barrier(2)
    read_barrier = CTX.Barrier(2)
    output = CTX.Queue()

    def contender(request):
        if broken:
            # Deliberately remove the transaction's exclusion and force two
            # stale inventory reads before either can publish its authority.
            e.lock = lambda *_a, **_k: contextlib.nullcontext()
            original = e.inventory

            def stale(path):
                result = original(path)
                read_barrier.wait(15)
                return result
            e.inventory = stale
        start.wait(15)
        try:
            answer = e.reserve(base, request, BUNDLE, INTERPRETER)
            output.put((request["name"], "won", answer["digest"]))
        except (ValueError, OSError) as exc:
            output.put((request["name"], "refused", str(exc)))

    processes = [CTX.Process(target=contender, args=(request,)) for request in (a, b)]
    for process in processes:
        process.start()
    results = [output.get(timeout=30) for _ in processes]
    for process in processes:
        process.join(30)
        if process.is_alive():
            process.kill()
            process.join()
        assert process.exitcode == 0, process.exitcode
    output.close()
    return results


class Enrollment(unittest.TestCase):
    def setUp(self):
        self.folder = Path(tempfile.mkdtemp(dir=SCRATCH)).resolve()
        self.base = self.folder / "authority"
        e.initialize(self.base)

    def tearDown(self):
        shutil.rmtree(self.folder)

    def request(self, name):
        root, home = self.folder / (name + "-root"), self.folder / (name + "-home")
        root.mkdir(mode=0o700)
        home.mkdir(mode=0o700)
        return dict(name=name, binding=str(uuid.uuid4()), fleet=str(uuid.uuid4()), route=name,
                    root=str(root), home=str(home), backend="herdr", session="lab-" + name,
                    socket=str(self.folder / (name + ".sock")), service="dev.fixture." + name,
                    commit="a" * 40)

    def reserve(self, request):
        return e.reserve(self.base, request, BUNDLE, INTERPRETER)

    def ready(self, request):
        entry = self.reserve(request)
        install(self.base, request["name"])
        return entry, e.instance(self.base, request["name"])

    def run_loader(self, request, verb, ok=True):
        location = e.instance(self.base, request["name"])
        poison = self.folder / "python-poison"
        poison.mkdir(exist_ok=True)
        (poison / "sitecustomize.py").write_text("raise RuntimeError('untrusted import')")
        (poison / "json.py").write_text("raise RuntimeError('application import')")
        result = subprocess.run([str(location / "ingress"), verb], cwd=poison,
                                env=dict(os.environ, PYTHONPATH=str(poison), PYTHONSTARTUP=str(poison / "json.py")),
                                capture_output=True, text=True, timeout=30)
        if ok:
            self.assertEqual(result.returncode, 0, result.stderr)
            return json.loads(result.stdout)
        self.assertEqual(result.returncode, 126, result.stderr)
        return result.stderr

    def repo(self, path):
        subprocess.run(["git", "init", "-q", str(path)], check=True, capture_output=True)
        # No commit, hooks, filters, external service or user configuration used.

    def test_races_all_valid_resource_names(self):
        for resource in ("root", "home", "root-home", "ancestor", "session", "socket", "service", "name", "binding"):
            with self.subTest(resource=resource):
                a, b = self.request("a-" + resource), self.request("b-" + resource)
                if resource == "ancestor":
                    self.repo(a["root"])
                    child = Path(a["root"]) / "child"
                    child.mkdir(mode=0o700)
                    b["root"] = str(child)
                elif resource == "root-home":
                    b["home"] = a["root"]
                else:
                    b[resource] = a[resource]
                results = race(self.base, a, b)
                self.assertEqual(sum(row[1] == "won" for row in results), 1, results)
                loser = next(row for row in results if row[1] == "refused")
                label = "path ancestor" if resource in ("ancestor", "root-home") else resource
                self.assertIn(label, loser[2], results)
                winner = next(row[0] for row in results if row[1] == "won")
                self.assertEqual(e.claim(self.base, winner)["state"], "reserved")
                # Different namespace for the next independent collision.
                self.base = self.folder / ("authority-" + resource)
                e.initialize(self.base)

    def test_shared_git_and_alias_contenders_cannot_win(self):
        for resource in ("common-git", "home-storage", "alternates", "inode-alias", "socket-alias"):
            with self.subTest(resource=resource):
                a, b = self.request("a-" + resource), self.request("b-" + resource)
                self.repo(a["root"])
                self.repo(a["home"])
                if resource in ("common-git", "home-storage"):
                    key = "home" if resource == "home-storage" else "root"
                    (Path(b[key]) / ".git").write_text("gitdir: " + str(Path(a[key]) / ".git") + "\n")
                    reason = "Git directory"
                elif resource == "alternates":
                    self.repo(b["root"])
                    (Path(b["root"]) / ".git/objects/info/alternates").write_text(a["root"] + "/.git/objects\n")
                    reason = "alternates"
                else:
                    alias = self.folder / (resource + "-alias")
                    alias.symlink_to(a["root"], target_is_directory=True)
                    b["root" if resource == "inode-alias" else "socket"] = str(alias)
                    reason = "alias"
                results = race(self.base, a, b)
                self.assertEqual([(r[0], r[1]) for r in sorted(results)], [(a["name"], "won"), (b["name"], "refused")])
                self.assertIn(reason, next(r[2] for r in results if r[1] == "refused"))
                self.base = self.folder / ("authority-" + resource)
                e.initialize(self.base)

    def test_shared_object_hardlinks_refuse_both_not_normalize(self):
        a, b = self.request("a"), self.request("b")
        for request in (a, b):
            self.repo(request["home"])
        x = Path(a["home"]) / ".git/objects/shared-pack"
        x.write_bytes(b"object storage")
        os.link(x, Path(b["home"]) / ".git/objects/shared-pack")
        results = race(self.base, a, b)
        self.assertTrue(all(row[1] == "refused" and "hardlinked record:" in row[2] and "/.git/objects/" in row[2] for row in results), results)
        self.assertEqual(e.inventory(self.base)["payload"]["entries"], {})

    def test_kernel_lock_inode_and_crash_release(self):
        path = self.base / "inventory.lock"
        inode = path.stat().st_ino
        entered = CTX.Event()

        def holder():
            with e.lock(path):
                entered.set()
                CTX.Event().wait(30)
        process = CTX.Process(target=holder)
        process.start()
        self.assertTrue(entered.wait(15))
        acquired = CTX.Event()

        def waiter():
            with e.lock(path):
                acquired.set()
        second = CTX.Process(target=waiter)
        second.start()
        self.assertFalse(acquired.wait(0.2))
        process.kill()
        process.join(15)
        self.assertTrue(acquired.wait(15))
        second.join(15)
        self.assertEqual(second.exitcode, 0)
        self.assertEqual(path.stat().st_ino, inode)
        for _ in range(3):
            with e.lock(path):
                self.assertEqual(path.stat().st_ino, inode)

    def crash(self, action, cut):
        def child():
            original = e.publish

            def interrupted(path, kind, revision, payload):
                original(path, kind, revision, payload)
                if kind == cut:
                    os._exit(71)
            e.publish = interrupted
            action()
        process = CTX.Process(target=child)
        process.start()
        process.join(30)
        self.assertFalse(process.is_alive())
        self.assertEqual(process.exitcode, 71)

    def test_reservation_and_each_projection_crash_blocks_rival(self):
        for cut in ("reservation", "pointer", "descriptor", "gate", "selection", "bootstrap"):
            with self.subTest(cut=cut):
                a, b = self.request("a-" + cut), self.request("b-" + cut)
                b["root"] = a["root"]
                if cut == "reservation":
                    self.crash(lambda: self.reserve(a), "claims")
                    self.assertEqual(e.claim(self.base, a["name"])["state"], "reserved")
                    install(self.base, a["name"])
                else:
                    self.ready(a)
                    self.crash(lambda: e.resume(self.base, a["name"]), cut)
                with self.assertRaises((e.Refusal, OSError)):
                    self.reserve(b)
                result = self.run_loader(a, "resume")
                self.assertEqual(result["state"], "reserved")
                self.assertEqual(result["bootstrap"], "complete")
                self.assertEqual(result["ordinary"], "closed")
                with self.assertRaises(e.Refusal):
                    self.reserve(b)
                self.base = self.folder / ("authority-" + cut)
                e.initialize(self.base)

    def test_install_crash_cutpoints_remain_pending(self):
        for filename in ("enrollment.py", "manifest.json", "loader.py", "ingress"):
            a, b = self.request("a-" + filename.replace(".", "-")), self.request("b-" + filename.replace(".", "-"))
            b["home"] = a["root"]
            self.reserve(a)

            def child():
                original = e.atomic

                def interrupted(path, data, mode=0o600):
                    original(path, data, mode)
                    if Path(path).name == filename:
                        os._exit(73)
                e.atomic = interrupted
                install(self.base, a["name"])
            process = CTX.Process(target=child)
            process.start()
            process.join(30)
            self.assertEqual(process.exitcode, 73)
            self.assertEqual(e.claim(self.base, a["name"])["state"], "reserved")
            with self.assertRaisesRegex(e.Refusal, "colliding"):
                self.reserve(b)
            # Explicit exact-byte reinstall is separate from ordinary resume;
            # no application bytes or implicit source fallback are used.
            install(self.base, a["name"])
            result = self.run_loader(a, "resume")
            self.assertEqual(result["state"], "reserved")
            self.assertEqual(result["bootstrap"], "complete")
            self.base = self.folder / ("authority-" + filename)
            e.initialize(self.base)

    def test_pending_missing_root_cannot_be_certified_complete(self):
        a = self.request("pending-missing")
        self.ready(a)
        shutil.rmtree(a["root"])
        before = tree(self.base)
        answer = self.run_loader(a, "diagnose")
        self.assertEqual(answer["bootstrap"], "pending")
        self.assertEqual(before, tree(self.base))
        answer = self.run_loader(a, "resume")
        self.assertEqual(answer["state"], "reserved")
        self.assertEqual(answer["bootstrap"], "complete")
        self.assertEqual(answer["missing"], ["root"])
        self.assertEqual(answer["ordinary"], "closed")
        self.assertFalse(Path(a["root"]).exists())
        self.assertEqual(e.claim(self.base, a["name"])["state"], "reserved")

    def test_atomic_replace_cutpoints(self):
        for after in (False, True):
            a = self.request("a-" + str(after).lower())

            def child():
                original = os.replace

                def interrupted(src, dest):
                    if Path(dest).name == "claims.json":
                        if after:
                            original(src, dest)
                        os._exit(72)
                    return original(src, dest)
                os.replace = interrupted
                self.reserve(a)
            process = CTX.Process(target=child)
            process.start()
            process.join(30)
            self.assertEqual(process.exitcode, 72)
            entries = e.inventory(self.base)["payload"]["entries"]
            self.assertEqual(a["name"] in entries, after)
            self.assertEqual(list(Path(a["root"]).iterdir()), [])
            if after:
                b = self.request("b-after")
                b["home"] = a["root"]
                with self.assertRaisesRegex(e.Refusal, "colliding"):
                    self.reserve(b)

    def test_missing_application_and_broken_entry_library_resume(self):
        a = self.request("missing")
        self.repo(a["root"])
        app = Path(a["root"]) / "bin"
        app.mkdir()
        for filename in ("fm-remote-entrypoint.sh", "fm-remote-job-lib.sh"):
            (app / filename).write_text("exit 99 # deliberately broken\n")
        self.ready(a)
        before = tree(self.base)
        diagnosis = self.run_loader(a, "diagnose")
        self.assertEqual(diagnosis["state"], "reserved")
        self.assertEqual(before, tree(self.base))
        result = self.run_loader(a, "resume")
        self.assertEqual(result["state"], "reserved")
        self.assertEqual(result["bootstrap"], "complete")
        shutil.rmtree(a["root"])
        shutil.rmtree(a["home"])
        before = tree(self.base)
        for verb in ("diagnose", "resume"):
            result = self.run_loader(a, verb)
            self.assertEqual(result["missing"], ["root", "home"])
            self.assertEqual(result["ordinary"], "closed")
        self.assertEqual(before, tree(self.base))
        self.assertFalse(Path(a["root"]).exists())
        self.assertFalse(Path(a["home"]).exists())

    def test_readonly_no_state_even_absent_authority(self):
        absent = self.folder / "absent"
        before = tree(self.folder)
        with self.assertRaises((e.Refusal, FileNotFoundError)):
            e.diagnose(absent, "unknown")
        self.assertEqual(before, tree(self.folder))
        a = self.request("read")
        self.ready(a)
        # Create import-poison fixtures before the no-write observation.
        self.run_loader(a, "diagnose")
        for bootstrap in ("pending", "complete"):
            if bootstrap == "complete":
                self.run_loader(a, "resume")
            before = tree(self.base)
            result = self.run_loader(a, "diagnose")
            self.assertEqual(result["state"], "reserved")
            self.assertEqual(result["bootstrap"], bootstrap)
            self.assertEqual(before, tree(self.base))

    def test_partial_bundle_missing_loader_selection_refuse(self):
        a = self.request("partial")
        self.reserve(a)
        with self.assertRaises((e.Refusal, OSError)):
            e.resume(self.base, a["name"])
        install(self.base, a["name"])
        location = e.instance(self.base, a["name"])
        code = location / "bundles" / BUNDLE / "enrollment.py"
        accepted = code.read_bytes()
        code.write_bytes(b"raise RuntimeError('must not execute')")
        self.assertIn("bundle file mismatch", self.run_loader(a, "resume", False))
        code.write_bytes(accepted)
        code.rename(code.with_suffix(".missing"))
        self.assertIn("partial/unverified", self.run_loader(a, "diagnose", False))
        code.with_suffix(".missing").rename(code)
        loader = location / "ingress"
        loader.unlink()
        with self.assertRaises((e.Refusal, OSError)):
            e.diagnose(self.base, a["name"])
        install(self.base, a["name"])
        self.run_loader(a, "resume")
        selection = location / "bootstrap-selection.json"
        original = selection.read_bytes()
        e.publish(selection, "selection", 2, {"bundle": "b" * 64, "abi": 1, "claim": e.claim(self.base, a["name"])["digest"]})
        self.assertIn("contradictory selection", self.run_loader(a, "resume", False))
        selection.write_bytes(original)
        selection.unlink()
        self.assertIn("incomplete bootstrap projections", self.run_loader(a, "diagnose", False))

    def test_unsafe_paths_modes_and_layouts(self):
        for layout in ("symlink", "unsafe-root", "unsafe-home", "submodule", "filter", "sparse", "common", "linked", "hardlink"):
            with self.subTest(layout=layout):
                a = self.request("bad-" + layout)
                root = Path(a["root"])
                if layout == "symlink":
                    alias = self.folder / "alias"
                    alias.symlink_to(root)
                    a["root"] = str(alias)
                elif layout.startswith("unsafe"):
                    Path(a["root" if layout.endswith("root") else "home"]).chmod(0o777)
                elif layout == "linked":
                    (root / ".git").write_text("gitdir: /not-owned\n")
                else:
                    self.repo(root)
                    if layout == "submodule":
                        (root / ".gitmodules").write_text("submodule")
                    elif layout == "filter":
                        with (root / ".git/config").open("a") as stream:
                            stream.write("\n[filter \"bad\"]\n smudge = false\n")
                    elif layout == "sparse":
                        (root / ".git/info/sparse-checkout").write_text("/*")
                    elif layout == "common":
                        (root / ".git/commondir").write_text("../other")
                    else:
                        os.link(root / ".git/config", root / ".git/shared")
                with self.assertRaises((e.Refusal, OSError)):
                    self.reserve(a)
        self.assertEqual(e.inventory(self.base)["payload"]["entries"], {})

    def test_foreign_pointer_replaced_inode_incomplete_records(self):
        a = self.request("identity")
        entry, location = self.ready(a)
        pointer = Path(a["home"]) / ".fm-enrolled-resource"
        e.publish(pointer, "pointer", 1, {"binding": str(uuid.uuid4()), "claim": entry["digest"], "role": "home"})
        self.assertIn("unexpected ownership pointer", self.run_loader(a, "resume", False))
        pointer.unlink()
        self.run_loader(a, "resume")
        old = Path(a["root"])
        old.rename(old.with_suffix(".old"))
        old.mkdir(mode=0o700)
        self.assertIn("replaced inode", self.run_loader(a, "diagnose", False))
        old.rmdir()
        old.with_suffix(".old").rename(old)
        descriptor = location / "descriptor.json"
        original = descriptor.read_bytes()
        for damaged in (b"{", original[:-10], b'{"schema":1,"schema":1}', e.canonical(e.envelope("descriptor", 2, {}))):
            descriptor.write_bytes(damaged)
            self.run_loader(a, "diagnose", False)
        descriptor.write_bytes(original)
        descriptor.chmod(0o666)
        self.run_loader(a, "diagnose", False)
        descriptor.chmod(0o600)
        descriptor.unlink()
        descriptor.symlink_to(location / "gate.json")
        self.run_loader(a, "diagnose", False)

    def test_retired_and_name_binding_reuse_still_reserved(self):
        a = self.request("retained")
        self.ready(a)
        e.resume(self.base, a["name"])
        record = e.inventory(self.base)
        retained = record["payload"]["entries"][a["name"]]
        retained["state"] = "retired"
        retained["revision"] += 1
        e.seal_claim(retained)
        e.publish(self.base / "claims.json", "claims", record["revision"] + 1, record["payload"])
        for resource in ("root", "home", "name", "binding", "session", "socket", "service"):
            b = self.request("r-" + resource)
            b[resource] = a[resource]
            with self.assertRaises(e.Refusal):
                self.reserve(b)
        with self.assertRaisesRegex(e.Refusal, "cannot resume"):
            e.resume(self.base, a["name"])

    def test_explicit_abort_requires_absence_and_never_reuses_identity(self):
        a = self.request("abort")
        entry = self.reserve(a)
        proof = dict(claim=entry["digest"], session=a["session"], service=a["service"], absent=True)
        with self.assertRaisesRegex(e.Refusal, "absence not proved"):
            e.abort(self.base, a["name"], proof)
        Path(a["root"]).rmdir()
        Path(a["home"]).rmdir()
        with self.assertRaisesRegex(e.Refusal, "explicit external"):
            e.abort(self.base, a["name"], {})
        e.abort(self.base, a["name"], proof)
        b = self.request("after-abort")
        b["name"] = a["name"]
        with self.assertRaisesRegex(e.Refusal, "colliding name"):
            self.reserve(b)
        b["name"] = "different"
        b["binding"] = a["binding"]
        with self.assertRaisesRegex(e.Refusal, "colliding binding"):
            self.reserve(b)

    def test_records_are_one_open_snapshot_and_selected_entry_is_coherent(self):
        path = self.base / "snapshot.json"
        old = {"left": "old", "right": "old"}
        new = {"left": "new", "right": "new"}
        e.publish(path, "fixture", 1, old)
        original_open = os.open
        swapping = False

        def swapped(file, flags, *args, **kwargs):
            nonlocal swapping
            fd = original_open(file, flags, *args, **kwargs)
            if Path(file) == path and not swapping and flags & os.O_NOFOLLOW:
                swapping = True
                e.publish(path, "fixture", 2, new)
            return fd
        os.open = swapped
        try:
            self.assertEqual(e.snapshot(path, "fixture")["payload"], old)
        finally:
            os.open = original_open
        self.assertEqual(e.snapshot(path, "fixture")["payload"], new)
        a, b = self.request("coherent-a"), self.request("coherent-b")
        entry, _ = self.ready(a)
        selected = e.claim(self.base, a["name"])
        self.reserve(b)
        self.assertEqual(selected, e.claim(self.base, a["name"]))
        self.run_loader(a, "resume")
        after = e.claim(self.base, a["name"])
        self.assertEqual(after["digest"], entry["digest"])
        self.assertEqual(after, selected)
        self.assertEqual(self.run_loader(a, "diagnose")["bootstrap"], "complete")
        record = e.inventory(self.base)
        record["payload"]["entries"][a["name"]]["state"] = "active"
        e.publish(self.base / "claims.json", "claims", record["revision"] + 1, record["payload"])
        self.run_loader(a, "diagnose", False)

    def test_semantically_incomplete_claims_are_not_valid_snapshots(self):
        a = self.request("strict-claim")
        self.ready(a)
        original = e.inventory(self.base)
        variants = []
        for field, value in (("binding", "not-a-binding"), ("session", "default"), ("socket", "/tmp/../alias")):
            bad = copy.deepcopy(original)
            bad["payload"]["entries"][a["name"]]["manifest"][field] = value
            variants.append(bad)
        for key, value in (("inode", -1), ("device", True), ("extra", "unknown")):
            bad = copy.deepcopy(original)
            bad["payload"]["entries"][a["name"]]["manifest"]["resources"]["root"][key] = value
            variants.append(bad)
        bad = copy.deepcopy(original)
        bad["payload"]["entries"][a["name"]]["manifest"]["resources"]["home_git"] = [{"path": "/foreign", "device": 1, "inode": 42}]
        variants.append(bad)
        for bad in variants:
            entry = bad["payload"]["entries"][a["name"]]
            entry["digest"] = e.digest(entry["manifest"])
            e.seal_claim(entry)
            e.publish(self.base / "claims.json", "claims", bad["revision"], bad["payload"])
            error = self.run_loader(a, "diagnose", False)
            self.assertRegex(error, "invalid|incomplete|foreign|default")
        e.publish(self.base / "claims.json", "claims", original["revision"], original["payload"])
        self.assertEqual(self.run_loader(a, "diagnose")["state"], "reserved")

    def test_existing_lane_ownership_is_never_adopted(self):
        for marker in (".fm-secondmate-home", ".fm-secondmate-parent", "state"):
            a = self.request("owned-" + marker.strip(".").replace("fm-secondmate-", ""))
            self.repo(a["home"])
            path = Path(a["home"]) / marker
            if marker == "state":
                path.mkdir()
            else:
                path.write_text("foreign existing lane")
            with self.assertRaisesRegex(e.Refusal, "existing lane"):
                self.reserve(a)
        a = self.request("late-owner")
        self.ready(a)
        (Path(a["home"]) / ".fm-secondmate-parent").write_text("foreign")
        self.assertIn("existing lane", self.run_loader(a, "resume", False))

    def test_bootstrap_completeness_is_not_lane_acceptance(self):
        a = self.request("only-bootstrap")
        entry, location = self.ready(a)
        before = e.inventory(self.base)
        result = self.run_loader(a, "resume")
        self.assertEqual(result["state"], "reserved")
        self.assertEqual(result["bootstrap"], "complete")
        self.assertEqual(e.inventory(self.base), before)
        # Empty reserved directories are still empty except for their pointers;
        # this cannot be a repository, worker, service or application proof.
        for role in ("root", "home"):
            self.assertEqual([p.name for p in Path(a[role]).iterdir()], [".fm-enrolled-resource"])
        completeness = location / "bootstrap-completeness.json"
        proof = e.snapshot(completeness, "bootstrap")["payload"]
        self.assertEqual(proof["claim"], entry["digest"])
        for kind, filename in e.PROJECTIONS:
            if kind != "bootstrap":
                self.assertEqual(proof["records"][kind], e.snapshot(location / filename, kind)["digest"])
        proof["records"]["selection"] = "f" * 64
        e.publish(completeness, "bootstrap", 1, proof)
        self.assertIn("contradictory bootstrap", self.run_loader(a, "diagnose", False))

    def test_bounded_records_and_unknown_operation_refusal(self):
        a = self.request("bounded")
        self.ready(a)
        self.run_loader(a, "diagnose")
        before = tree(self.base)
        self.assertIn("only installed", self.run_loader(a, "dispatch", False))
        self.assertEqual(before, tree(self.base))
        claims = self.base / "claims.json"
        original = claims.read_bytes()
        claims.write_bytes(b" " * (e.LIMIT + 1))
        self.run_loader(a, "diagnose", False)
        claims.write_bytes(original)
        location = e.instance(self.base, a["name"])
        location.chmod(0o755)
        self.run_loader(a, "diagnose", False)
        location.chmod(0o700)
        self.run_loader(a, "resume")
        selection = location / "bootstrap-selection.json"
        selected = e.snapshot(selection, "selection")["payload"]
        selected["abi"] = True
        e.publish(selection, "selection", 1, selected)
        self.assertIn("contradictory selection", self.run_loader(a, "diagnose", False))

    def test_negative_controls_bite(self):
        a, b = self.request("negative-a"), self.request("negative-b")
        b["root"] = a["root"]
        result = race(self.base, a, b, broken=True)
        with self.assertRaises(AssertionError):
            self.assertEqual(sum(row[1] == "won" for row in result), 1, result)
        self.assertEqual(sum(row[1] == "won" for row in result), 2, result)
        print("negative-control: removing kernel transaction exclusion admits two winners (oracle failed)")
        # The same behavioral pointer oracle fails when its guard is removed.
        base = self.folder / "negative-pointer"
        e.initialize(base)
        self.base = base
        a = self.request("negative-pointer")
        entry, _ = self.ready(a)
        pointer = Path(a["home"]) / ".fm-enrolled-resource"
        e.publish(pointer, "pointer", 1, {"binding": "foreign", "claim": entry["digest"], "role": "home"})
        original = e.verify_resources
        e.verify_resources = lambda *_a, **_k: None
        try:
            with self.assertRaises(AssertionError):
                with self.assertRaises(e.Refusal):
                    e.diagnose(self.base, a["name"])
        finally:
            e.verify_resources = original
        print("negative-control: omitting resource validation misses foreign pointer (oracle failed)")
        pointer.unlink()
        # Reintroduce the unsafe draft transition at the real completion write;
        # the same stage-boundary oracle must catch false lane acceptance.
        original_publish = e.publish

        def false_enrollment(path, kind, revision, payload):
            original_publish(path, kind, revision, payload)
            if kind == "bootstrap":
                record = e.inventory(self.base)
                entry = record["payload"]["entries"][a["name"]]
                entry["state"] = "enrolled"
                entry["revision"] += 1
                e.seal_claim(entry)
                original_publish(self.base / "claims.json", "claims", record["revision"] + 1, record["payload"])
        e.publish = false_enrollment
        try:
            result = e.resume(self.base, a["name"])
            with self.assertRaises(AssertionError):
                self.assertEqual(result["state"], "reserved")
            self.assertEqual(result["state"], "enrolled")
        finally:
            e.publish = original_publish
        print("negative-control: bootstrap-only enrolled transition fails the stage-boundary oracle")


if __name__ == "__main__":
    unittest.main(verbosity=2)
