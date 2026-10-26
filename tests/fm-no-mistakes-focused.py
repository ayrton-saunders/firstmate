#!/usr/bin/env python3
"""Controlled local Git histories for the production correspondence component."""

import copy
import importlib.util
import json
import os
import shutil
from pathlib import Path
import subprocess
import sys
import tempfile
import textwrap
import unittest

# Keep dynamically imported production code from writing into the source copy.
sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "focused", ROOT / ".github/verify-focused-upstream.py")
FOCUSED = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(FOCUSED)


class CorrespondenceTests(unittest.TestCase):
    def setUp(self):
        original_env = dict(os.environ)
        self.addCleanup(lambda: (os.environ.clear(), os.environ.update(original_env)))
        os.environ.update(GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_NOSYSTEM="1",
                          GIT_CONFIG_COUNT="0")
        for name in ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR"):
            os.environ.pop(name, None)
        self.temp = tempfile.TemporaryDirectory(prefix="fm-focused-git-")
        self.addCleanup(self.temp.cleanup)
        self.repo = Path(self.temp.name)
        self.git("init", "-q")
        self.git("config", "user.name", "Controlled fixture")
        self.git("config", "user.email", "fixture@example.invalid")
        self.git("config", "commit.gpgsign", "false")
        (self.repo / "shared").write_text("base\n")
        self.git("add", ".")
        self.git("commit", "-qm", "common ancestor")
        self.common = self.git("rev-parse", "HEAD")

    def git(self, *args, input=None):
        return subprocess.run(
            ["git", "-C", str(self.repo), *args], input=input,
            text=True, check=True, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE).stdout.strip()

    def commit_file(self, name, content):
        (self.repo / name).write_text(content)
        self.git("add", name)
        self.git("commit", "-qm", "fixture " + name)
        return self.git("rev-parse", "HEAD")

    def commit_tree(self, tree, *parents):
        args = ["commit-tree", tree]
        for parent in parents:
            args.extend(["-p", parent])
        return self.git(*args, input="controlled fixture merge\n")

    def fixture(self, mode="divergent"):
        o = self.common
        if mode != "ff":
            o = self.commit_file("personal", "preserved personal behavior\n")
        self.git("checkout", "-q", "--detach", self.common)
        u = self.commit_file("canonical", "upstream behavior\n")
        if mode == "ancestry-only":
            self.git("checkout", "-q", "--detach", o)
            self.commit_file("canonical", "upstream behavior\n")
            o = self.git("rev-parse", "HEAD")
        if mode == "ff":
            h = u
        else:
            tree = self.git("merge-tree", "--write-tree", o, u)
            h = self.commit_tree(tree, o, u)
        tree = self.git("rev-parse", h + "^{tree}")
        t = self.commit_tree(tree, o, h)
        claim = {
            "source_repository": FOCUSED.CANONICAL,
            "fork_repository": FOCUSED.FORK,
            "head_repository": FOCUSED.FORK,
            "source_ref": "refs/heads/main",
            "base_ref": "refs/heads/main",
            "head_ref": "refs/heads/integration",
            "O": o, "U": u, "H": h, "B": o, "T": t,
            "conflict_history": "clean",
        }
        current = {**claim, "source_default": "refs/heads/main",
                   "fork_default": "refs/heads/main"}
        return claim, current

    def verify(self, claim, current):
        return FOCUSED.verify_correspondence(str(self.repo), claim, current)

    def test_actual_clean_upstream_histories(self):
        for mode in ("ff", "divergent", "ancestry-only"):
            with self.subTest(mode=mode):
                claim, current = self.fixture(mode)
                result = self.verify(claim, current)
                self.assertEqual(result["H"], claim["H"])
                self.assertEqual(result["execution_evidence"], "not-verified")
                self.git("checkout", "-q", "--detach", self.common)

    def test_source_ref_and_current_publication_binding(self):
        claim, current = self.fixture()
        for name in ("source_repository", "fork_repository", "head_repository",
                     "source_ref", "base_ref", "head_ref", "U", "H", "B", "T"):
            with self.subTest(name=name):
                forged = {**claim, name: "forged"}
                with self.assertRaises(FOCUSED.Refusal):
                    self.verify(forged, current)
        for name in ("source_default", "fork_default", "U", "H", "B", "T"):
            with self.subTest(current=name):
                moved = {**current, name: self.common}
                with self.assertRaises(FOCUSED.Refusal):
                    self.verify(claim, moved)

    def test_personal_changes_and_reversed_parents(self):
        claim, current = self.fixture()
        self.git("checkout", "-q", "--detach", claim["H"])
        personal = self.commit_file("unrelated", "not upstream\n")
        wrong_tree = self.git("rev-parse", personal + "^{tree}")
        for head in (personal,
                     self.commit_tree(wrong_tree, claim["O"], claim["U"]),
                     self.commit_tree(claim["H"] + "^{tree}",
                                      claim["U"], claim["O"])):
            with self.subTest(head=head):
                forged = {**claim, "H": head}
                facts = {**current, "H": head}
                with self.assertRaises(FOCUSED.Refusal):
                    self.verify(forged, facts)

    def test_tested_merge_parents_tree_and_reused_head(self):
        claim, current = self.fixture()
        for tested in (self.commit_tree(claim["H"] + "^{tree}",
                                        claim["H"], claim["B"]),
                       self.commit_tree(self.common + "^{tree}",
                                        claim["B"], claim["H"]),
                       self.commit_tree(claim["H"] + "^{tree}",
                                        claim["B"], claim["U"])):
            with self.subTest(tested=tested):
                with self.assertRaises(FOCUSED.Refusal):
                    self.verify({**claim, "T": tested}, {**current, "T": tested})

    def test_unknown_history_and_already_contained_upstream_refuse(self):
        claim, current = self.fixture()
        for history in (None, "unknown", "conflicted"):
            with self.subTest(history=history):
                with self.assertRaises(FOCUSED.Refusal):
                    self.verify({**claim, "conflict_history": history}, current)
        # A redundant merge does not manufacture new canonical ancestry.
        h = self.commit_tree(claim["O"] + "^{tree}",
                             claim["O"], self.common)
        t = self.commit_tree(h + "^{tree}", claim["O"], h)
        claim.update(U=self.common, H=h, T=t)
        current.update(U=self.common, H=h, T=t)
        with self.assertRaisesRegex(FOCUSED.Refusal, "no new canonical ancestry"):
            self.verify(claim, current)

    def test_real_conflict_cannot_be_declared_clean(self):
        o = self.commit_file("shared", "personal conflict\n")
        self.git("checkout", "-q", "--detach", self.common)
        u = self.commit_file("shared", "canonical conflict\n")
        # A fabricated "clean" claim is insufficient even with real parents.
        h = self.commit_tree(o + "^{tree}", o, u)
        t = self.commit_tree(h + "^{tree}", o, h)
        claim, current = self.fixture()
        claim.update(O=o, U=u, H=h, B=o, T=t, conflict_history="clean")
        current.update(O=o, U=u, H=h, B=o, T=t)
        with self.assertRaisesRegex(FOCUSED.Refusal, "conflict resolutions"):
            self.verify(claim, current)

    def live_api(self, claim):
        source = {"id": 100, "full_name": FOCUSED.CANONICAL, "fork": False,
                  "default_branch": "main"}
        fork = {"id": 200, "full_name": FOCUSED.FORK, "fork": True,
                "default_branch": "main", "parent": source, "source": source}
        replies = {
            "/repos/" + FOCUSED.CANONICAL: source,
            "/repos/" + FOCUSED.FORK: fork,
            f"/repos/{FOCUSED.FORK}/pulls/23": {
                "number": 23, "state": "open", "merged": False,
                "mergeable": True, "merge_commit_sha": claim["T"],
                "base": {"repo": fork, "ref": "main", "sha": claim["B"]},
                "head": {"repo": fork, "ref": "intake/upstream", "sha": claim["H"]},
            },
        }
        for repo, ref, sha in ((FOCUSED.CANONICAL, "main", claim["U"]),
                               (FOCUSED.FORK, "main", claim["B"]),
                               (FOCUSED.FORK, "intake%2Fupstream", claim["H"])):
            replies[f"/repos/{repo}/git/ref/heads/{ref}"] = {
                "ref": "refs/heads/" + ref.replace("%2F", "/"),
                "object": {"type": "commit", "sha": sha}}
        return replies

    def test_fresh_api_facts_bind_real_git_correspondence(self):
        claim, _ = self.fixture()
        claim["head_ref"] = "refs/heads/intake/upstream"
        replies = self.live_api(claim)
        calls = []

        def read(path):
            calls.append(path)
            return copy.deepcopy(replies[path])

        facts = FOCUSED.current_facts(read, 23)
        self.assertEqual(self.verify(claim, facts)["H"], claim["H"])
        self.assertEqual(len(calls), 6)
        # A prior receipt does not survive a newly published integration head.
        replies[f"/repos/{FOCUSED.FORK}/git/ref/heads/intake%2Fupstream"][
            "object"]["sha"] = self.common
        with self.assertRaisesRegex(FOCUSED.Refusal, "publication disagree"):
            FOCUSED.current_facts(read, 23)

    def test_live_identity_and_mergeability_refusals(self):
        claim, _ = self.fixture()
        original = self.live_api(claim)
        source_path = "/repos/" + FOCUSED.CANONICAL
        fork_path = "/repos/" + FOCUSED.FORK
        pr_path = f"/repos/{FOCUSED.FORK}/pulls/23"
        changes = [
            (source_path, ("full_name",), "someone/firstmate"),
            (source_path, ("fork",), True),
            (fork_path, ("fork",), False),
            (fork_path, ("parent", "id"), 999),
            (fork_path, ("source", "full_name"), "someone/firstmate"),
            (fork_path, ("default_branch",), "release"),
            (pr_path, ("number",), 24),
            (pr_path, ("state",), "closed"),
            (pr_path, ("merged",), True),
            (pr_path, ("mergeable",), None),
            (pr_path, ("mergeable",), False),
            (pr_path, ("merge_commit_sha",), None),
            (pr_path, ("head", "repo", "id"), 999),
            (pr_path, ("head", "repo"), None),
            (pr_path, ("base", "ref"), "release"),
            (pr_path, ("head", "ref"), "main"),
            (pr_path, ("base", "sha"), self.common),
            (pr_path, ("head", "sha"), self.common),
            (f"/repos/{FOCUSED.FORK}/git/ref/heads/main",
             ("object", "type"), "tag"),
            (f"/repos/{FOCUSED.CANONICAL}/git/ref/heads/main",
             ("ref",), "refs/heads/other"),
        ]
        for path, keys, value in changes:
            with self.subTest(path=path, keys=keys, value=value):
                # Break shared fixture dictionaries as real API responses are
                # independent snapshots, even for the same repository identity.
                replies = {key: copy.deepcopy(item) for key, item in original.items()}
                target = replies[path]
                for key in keys[:-1]:
                    target = target[key]
                target[keys[-1]] = value
                with self.assertRaises(FOCUSED.Refusal):
                    FOCUSED.current_facts(replies.__getitem__, 23)
        for number in (0, -1, True, "23"):
            with self.subTest(number=number), self.assertRaises(FOCUSED.Refusal):
                FOCUSED.current_facts(original.__getitem__, number)

    def test_live_source_and_tested_merge_changes_invalidate_old_claim(self):
        claim, _ = self.fixture()
        claim["head_ref"] = "refs/heads/intake/upstream"
        for path, key in ((f"/repos/{FOCUSED.CANONICAL}/git/ref/heads/main", "U"),
                          (f"/repos/{FOCUSED.FORK}/pulls/23", "T")):
            with self.subTest(changed=key):
                replies = self.live_api(claim)
                if key == "U":
                    replies[path]["object"]["sha"] = self.common
                else:
                    replies[path]["merge_commit_sha"] = self.common
                facts = FOCUSED.current_facts(replies.__getitem__, 23)
                with self.assertRaisesRegex(FOCUSED.Refusal, "changed current " + key):
                    self.verify(claim, facts)

    def declaration(self, claim):
        return "<!-- firstmate-focused-upstream:v1 " + json.dumps(claim) + " -->"

    def test_strict_focused_routing_preserves_native_only_baseline(self):
        native = ('Updates from [git push no-mistakes]'
                  '(https://github.com/kunchenguid/no-mistakes)\n'
                  '<!-- no-mistakes-pipeline-attestation:v1 '
                  '{"head_sha":"' + self.common + '","steps":[]} -->')
        for body in (None, "", "ordinary personal feature", native):
            with self.subTest(body=body):
                self.assertIsNone(FOCUSED.focused_claim(FOCUSED.FORK, body))
        # No new parsing or exemptions for canonical/nonfork repositories.
        self.assertIsNone(FOCUSED.focused_claim(FOCUSED.CANONICAL,
                                               "firstmate-focused-upstream"))
        claim, _ = self.fixture()
        self.assertEqual(FOCUSED.focused_claim(FOCUSED.FORK,
                                             self.declaration(claim)), claim)
        bad_claims = [[], {}, {**claim, "evidence": "passed"},
                      {**claim, "test_run": 123}, {**claim, "O": True}]
        bad_bodies = ["firstmate-focused-upstream", self.declaration(claim) * 2,
                      self.declaration(claim).replace(":v1 ", ":v2 "),
                      '<!-- firstmate-focused-upstream:v1 {invalid} -->',
                      '<!-- firstmate-focused-upstream:v1 {"O":"a","O":"b"} -->',
                      '<!-- firstmate-focused-upstream:v1 ' + ' ' * 16385 + ' -->']
        bad_bodies.extend(self.declaration(value) for value in bad_claims)
        for body in bad_bodies:
            for suffix in ("", "\n" + native):
                with self.subTest(body=body[:100], native=bool(suffix)):
                    with self.assertRaises(FOCUSED.Refusal):
                        FOCUSED.focused_claim(FOCUSED.FORK, body + suffix)

    def test_live_request_positive_is_not_execution_evidence(self):
        claim, _ = self.fixture()
        claim["head_ref"] = "refs/heads/intake/upstream"
        replies = self.live_api(claim)
        replies[f"/repos/{FOCUSED.FORK}/pulls/23"]["body"] = self.declaration(claim)
        result = FOCUSED.verify_request(FOCUSED.FORK, str(self.repo),
                                        replies.__getitem__, 23, claim["H"])
        self.assertEqual(result["route"], "focused")
        self.assertEqual(result["execution_evidence"], "not-verified")
        self.assertEqual(result["current"]["T"], claim["T"])

    def test_failed_focused_request_never_routes_to_native(self):
        claim, _ = self.fixture()
        claim["head_ref"] = "refs/heads/intake/upstream"
        replies = self.live_api(claim)
        pr = replies[f"/repos/{FOCUSED.FORK}/pulls/23"]
        native = ('\n<!-- no-mistakes-pipeline-attestation:v1 '
                  '{"head_sha":"' + claim["H"] + '","steps":[]} -->')
        # Valid syntax is not evidence: forged identities and reused heads must
        # reach the actual Git/live correspondence checks and refuse terminally.
        for field in ("source_repository", "source_ref", "O", "U", "H", "B", "T"):
            with self.subTest(field=field):
                forged = {**claim, field: self.common}
                pr["body"] = self.declaration(forged) + native
                with self.assertRaises(FOCUSED.Refusal):
                    FOCUSED.verify_request(FOCUSED.FORK, str(self.repo),
                                           replies.__getitem__, 23, claim["H"])
        pr["body"] = self.declaration(claim)
        with self.assertRaisesRegex(FOCUSED.Refusal, "event head"):
            FOCUSED.verify_request(FOCUSED.FORK, str(self.repo),
                                   replies.__getitem__, 23, self.common)
        self.git("checkout", "-q", "--detach", claim["H"])
        personal = self.commit_file("unrelated", "personal feature\n")
        forged = {**claim, "H": personal}
        replies = self.live_api(forged)
        replies[f"/repos/{FOCUSED.FORK}/pulls/23"]["body"] = self.declaration(forged)
        with self.assertRaisesRegex(FOCUSED.Refusal, "personal changes"):
            FOCUSED.verify_request(FOCUSED.FORK, str(self.repo),
                                   replies.__getitem__, 23, personal)

    def test_request_body_is_read_live_and_routing_detects_publication_race(self):
        claim, _ = self.fixture()
        claim["head_ref"] = "refs/heads/intake/upstream"
        replies = self.live_api(claim)
        pr = replies[f"/repos/{FOCUSED.FORK}/pulls/23"]
        self.assertEqual(FOCUSED.verify_request(
            FOCUSED.FORK, str(self.repo), replies.__getitem__, 23, claim["H"]),
            {"route": "native"})
        # Legacy native reruns still let the pinned action evaluate live facts,
        # rather than imposing the focused route's event-head restriction.
        self.assertEqual(FOCUSED.verify_request(
            FOCUSED.FORK, str(self.repo), replies.__getitem__, 23, self.common),
            {"route": "native"})
        pr["body"] = self.declaration(claim)
        calls = 0

        def changed_after_body_read(path):
            nonlocal calls
            calls += 1
            response = copy.deepcopy(replies[path])
            if calls == 1:
                pr["head"]["sha"] = self.common
                replies[f"/repos/{FOCUSED.FORK}/git/ref/heads/intake%2Fupstream"][
                    "object"]["sha"] = self.common
            return response

        with self.assertRaisesRegex(FOCUSED.Refusal, "publication changed"):
            FOCUSED.verify_request(FOCUSED.FORK, str(self.repo),
                                   changed_after_body_read, 23, claim["H"])

    def test_fresh_inspection_retains_actual_patches_and_personal_entries(self):
        claim, current = self.fixture()
        evidence = self.repo / "inspection"
        receipt = FOCUSED.inspect_personal_delta(str(self.repo), claim, current,
                                                 str(evidence))
        self.assertEqual(receipt["H"], claim["H"])
        self.assertEqual(receipt["conflict_history"], "reconstructed-clean")
        self.assertEqual(receipt["personal_paths"][0]["path"], "personal")
        self.assertEqual(receipt["personal_paths"][0]["base_entry"],
                         receipt["personal_paths"][0]["head_entry"])
        self.assertIn("+preserved personal behavior", (evidence / "personal.patch").read_text())
        self.assertIn("+upstream behavior", (evidence / "canonical.patch").read_text())
        self.assertEqual(json.loads((evidence / "inspection.json").read_text()), receipt)
        with self.assertRaises(FileExistsError):
            FOCUSED.inspect_personal_delta(str(self.repo), claim, current, str(evidence))
        with self.assertRaises(FOCUSED.Refusal):
            FOCUSED.inspect_personal_delta(str(self.repo), {**claim, "H": self.common},
                                           current, str(self.repo / "forged-inspection"))

    def test_inspection_handles_ff_and_ancestry_only_integrations(self):
        for mode in ("ff", "ancestry-only"):
            with self.subTest(mode=mode):
                claim, current = self.fixture(mode)
                receipt = FOCUSED.inspect_personal_delta(
                    str(self.repo), claim, current, str(self.repo / ("inspect-" + mode)))
                self.assertEqual(receipt["tree"], self.git("rev-parse", claim["H"] + "^{tree}"))
                if mode == "ff":
                    self.assertEqual(receipt["personal_paths"], [])
                else:
                    self.assertEqual((self.repo / ("inspect-" + mode) /
                                      "integration.patch").read_text(), "")
                self.git("checkout", "-q", "--detach", self.common)

    def test_inspection_refuses_clean_overlap_without_pretending_it_was_reviewed(self):
        (self.repo / "shared").write_text("first\n" + "middle\n" * 20 + "last\n")
        self.git("add", "shared")
        self.git("commit", "-qm", "common multiline behavior")
        self.common = self.git("rev-parse", "HEAD")
        o = self.commit_file("shared", "personal\n" + "middle\n" * 20 + "last\n")
        self.git("checkout", "-q", "--detach", self.common)
        u = self.commit_file("shared", "first\n" + "middle\n" * 20 + "upstream\n")
        tree = self.git("merge-tree", "--write-tree", o, u)
        h = self.commit_tree(tree, o, u)
        t = self.commit_tree(tree, o, h)
        # Git really merges cleanly, but that alone is not substantive review of
        # a changed personal file. This bounded inspector must refuse it.
        claim, current = self.fixture()
        claim.update(O=o, B=o, U=u, H=h, T=t)
        current.update(O=o, B=o, U=u, H=h, T=t)
        self.assertEqual(self.verify(claim, current)["correspondence"], "verified")
        evidence = self.repo / "overlap-inspection"
        with self.assertRaisesRegex(FOCUSED.Refusal, "substantive overlap"):
            FOCUSED.inspect_personal_delta(str(self.repo), claim, current, str(evidence))
        self.assertFalse((evidence / "inspection.json").exists())

    def test_inspection_preserves_deleted_modes_and_literal_personal_paths(self):
        self.git("rm", "shared")
        (self.repo / ":(glob)*").write_text("literal personal filename\n")
        executable = self.repo / "personal-executable"
        executable.write_text("#!/bin/bash\nexit 0\n")
        executable.chmod(0o755)
        (self.repo / "personal-link").symlink_to("personal-executable")
        self.git("add", "--all")
        self.git("commit", "-qm", "personal modes deletion and literal name")
        o = self.git("rev-parse", "HEAD")
        self.git("checkout", "-q", "--detach", self.common)
        u = self.commit_file("canonical", "upstream behavior\n")
        tree = self.git("merge-tree", "--write-tree", o, u)
        h = self.commit_tree(tree, o, u)
        t = self.commit_tree(tree, o, h)
        claim, current = self.fixture()
        claim.update(O=o, B=o, U=u, H=h, T=t)
        current.update(O=o, B=o, U=u, H=h, T=t)
        receipt = FOCUSED.inspect_personal_delta(str(self.repo), claim, current,
                                                 str(self.repo / "mode-inspection"))
        entries = {item["path"]: item["base_entry"] for item in receipt["personal_paths"]}
        self.assertEqual(entries["shared"], "")
        self.assertTrue(entries["personal-executable"].startswith("100755 blob "))
        self.assertTrue(entries["personal-link"].startswith("120000 blob "))
        self.assertIn(":(glob)*", entries)

    def test_fresh_sandbox_execution_and_failed_behavior(self):
        if not shutil.which("docker"):
            if os.environ.get("CI"):
                self.fail("hosted focused execution tests require Docker")
            self.skipTest("Docker is required for real focused execution coverage")
        available = subprocess.run(["docker", "info"], stdout=subprocess.DEVNULL,
                                   stderr=subprocess.DEVNULL, timeout=20, check=False)
        if available.returncode:
            if os.environ.get("CI"):
                self.fail("hosted focused execution tests require a Docker server")
            self.skipTest("Docker server unavailable")
        image = os.environ.get("FM_FOCUSED_TEST_IMAGE", "ubuntu:24.04")
        # This is a controlled upstream test, not a real canonical publication.
        # It checks actual behavior in an uncredentialed isolated process and
        # deliberately emits workflow-command syntax to retained data only.
        (self.repo / "tests").mkdir()
        script = self.repo / "tests/fm-update.test.sh"
        script.write_text(
            '#!/bin/bash\nset -eu\n'
            'test "$(id -u)" = 65534\n'
            'test -z "${GITHUB_TOKEN:-}"\n'
            'test ! -e .git\n'
            'test ! -e /var/run/docker.sock\n'
            'test "$(cat canonical)" = "upstream behavior"\n'
            'test "$(cat personal)" = "preserved personal behavior"\n'
            'echo "::error::retained output is not a workflow command"\n')
        self.git("add", "tests")
        self.git("commit", "-qm", "controlled focused behavior test")
        self.common = self.git("rev-parse", "HEAD")
        claim, current = self.fixture()
        result = self.verify(claim, current)
        evidence = self.repo / "retained-first"
        os.environ["GITHUB_TOKEN"] = "fixture-not-a-secret"
        receipt = FOCUSED.execute_focused_tests(str(self.repo), result, image,
                                                str(evidence))
        self.assertEqual(receipt["T"], claim["T"])
        self.assertEqual(receipt["execution_evidence"], "fresh-sandbox-execution")
        self.assertEqual(receipt["inspection_evidence"], "not-verified")
        self.assertEqual(json.loads((evidence / "execution.json").read_text()), receipt)
        self.assertIn("::error::", (evidence / "execution.log").read_text())
        with self.assertRaises(FileExistsError):
            FOCUSED.execute_focused_tests(str(self.repo), result, image, str(evidence))
        # Actual canonical changes may break preserved personal behavior. Real
        # execution must fail even though correspondence is independently valid.
        self.git("checkout", "-q", "--detach", claim["U"])
        self.commit_file("canonical", "regression\n")
        # Replacing the head's tests with a green assertion must not approve
        # the broken candidate: the actual executed assertions belong to B.
        u = self.commit_file("tests/fm-update.test.sh", "#!/bin/bash\nexit 0\n")
        tree = self.git("merge-tree", "--write-tree", claim["O"], u)
        h = self.commit_tree(tree, claim["O"], u)
        t = self.commit_tree(tree, claim["O"], h)
        claim.update(U=u, H=h, T=t)
        current.update(U=u, H=h, T=t)
        result = self.verify(claim, current)
        failed = self.repo / "retained-failed"
        with self.assertRaisesRegex(FOCUSED.Refusal, "behavior tests failed"):
            FOCUSED.execute_focused_tests(str(self.repo), result, image, str(failed))
        self.assertFalse((failed / "execution.json").exists())
        with self.assertRaisesRegex(FOCUSED.Refusal, "changed execution tree"):
            FOCUSED.execute_focused_tests(str(self.repo), {**result, "tree": self.common},
                                          image, str(self.repo / "retained-stale"))

    def test_combined_qualification_requires_fresh_inspection_execution_and_publication(self):
        if not shutil.which("docker"):
            if os.environ.get("CI"):
                self.fail("hosted combined qualification requires Docker")
            self.skipTest("Docker is required for combined qualification coverage")
        available = subprocess.run(["docker", "info"], stdout=subprocess.DEVNULL,
                                   stderr=subprocess.DEVNULL, timeout=20, check=False)
        if available.returncode:
            if os.environ.get("CI"):
                self.fail("hosted combined qualification requires a Docker server")
            self.skipTest("Docker server unavailable")
        image = os.environ.get("FM_FOCUSED_TEST_IMAGE", "ubuntu:24.04")
        (self.repo / "tests").mkdir()
        (self.repo / "tests/fm-update.test.sh").write_text(
            '#!/bin/bash\nset -eu\n'
            'test "$(cat canonical)" = "upstream behavior"\n'
            'test "$(cat personal)" = "preserved personal behavior"\n')
        self.git("add", "tests")
        self.git("commit", "-qm", "base-owned acceptance assertions")
        self.common = self.git("rev-parse", "HEAD")
        claim, _ = self.fixture()
        claim["head_ref"] = "refs/heads/intake/upstream"
        original = self.live_api(claim)
        pr_path = f"/repos/{FOCUSED.FORK}/pulls/23"
        original[pr_path]["body"] = self.declaration(claim)

        def qualify(replies, directory, read=None):
            return FOCUSED.qualify_request(
                FOCUSED.FORK, str(self.repo), read or replies.__getitem__, 23,
                claim["H"], image, str(directory))

        evidence = self.repo / "combined-positive"
        receipt = qualify(original, evidence)
        self.assertEqual(receipt["qualification"], "fresh-focused-proof")
        self.assertEqual(receipt["inspection"]["H"], claim["H"])
        self.assertEqual(receipt["execution"]["T"], claim["T"])
        self.assertEqual(json.loads((evidence / "qualified.json").read_text()), receipt)
        with self.assertRaises(FileExistsError):
            qualify(original, evidence)
        # Native-only routing produces no focused receipt and does not attempt
        # focused execution. This is preservation, not native authentication.
        native = copy.deepcopy(original)
        native[pr_path]["body"] = "ordinary personal native request"
        untouched = self.repo / "native-no-focused-proof"
        self.assertEqual(qualify(native, untouched), {"route": "native"})
        self.assertFalse(untouched.exists())
        forged = copy.deepcopy(original)
        forged[pr_path]["body"] = self.declaration({**claim, "evidence": "passed"})
        refused = self.repo / "forged-no-proof"
        with self.assertRaises(FOCUSED.Refusal):
            qualify(forged, refused)
        self.assertFalse(refused.exists())

        # Every case executes genuine sandboxed acceptance assertions first.
        # An old successful receipt cannot authorize a changed publication or a
        # switch back to native while that execution was in progress.
        for change in ("body", "U", "B", "H", "T", "repository-id"):
            with self.subTest(changed_after_execution=change):
                replies = copy.deepcopy(original)
                calls = 0

                def changed_on_refresh(path):
                    nonlocal calls
                    calls += 1
                    if calls == 8:
                        if change == "body":
                            replies[pr_path]["body"] = "native-only replacement"
                        elif change == "T":
                            replies[pr_path]["merge_commit_sha"] = self.common
                        elif change == "repository-id":
                            replies["/repos/" + FOCUSED.CANONICAL]["id"] = 101
                        else:
                            repo = FOCUSED.CANONICAL if change == "U" else FOCUSED.FORK
                            ref = "intake%2Fupstream" if change == "H" else "main"
                            replies[f"/repos/{repo}/git/ref/heads/{ref}"][
                                "object"]["sha"] = self.common
                            if change in ("B", "H"):
                                side = "base" if change == "B" else "head"
                                replies[pr_path][side]["sha"] = self.common
                    return copy.deepcopy(replies[path])

                failed = self.repo / ("combined-drift-" + change)
                with self.assertRaises(FOCUSED.Refusal):
                    qualify(replies, failed, changed_on_refresh)
                self.assertTrue((failed / "inspection/inspection.json").exists())
                self.assertTrue((failed / "execution/execution.json").exists())
                self.assertFalse((failed / "qualified.json").exists())

        # A valid upstream correspondence is insufficient when actual personal
        # behavior fails; partial inspection evidence never becomes a verdict.
        self.git("checkout", "-q", "--detach", claim["U"])
        u = self.commit_file("canonical", "broken upstream behavior\n")
        tree = self.git("merge-tree", "--write-tree", claim["O"], u)
        h = self.commit_tree(tree, claim["O"], u)
        t = self.commit_tree(tree, claim["O"], h)
        claim.update(U=u, H=h, T=t)
        broken = self.live_api(claim)
        broken[pr_path]["body"] = self.declaration(claim)
        failed = self.repo / "combined-broken-behavior"
        with self.assertRaisesRegex(FOCUSED.Refusal, "behavior tests failed"):
            qualify(broken, failed)
        self.assertTrue((failed / "inspection/inspection.json").exists())
        self.assertFalse((failed / "execution/execution.json").exists())
        self.assertFalse((failed / "qualified.json").exists())

    def test_first_install_executes_actual_workflow_native_bootstrap(self):
        # Parse the workflow's literal shell block for execution, not assertions
        # about implementation text. No candidate checker exists on this base.
        lines = (ROOT / ".github/workflows/no-mistakes-required.yml").read_text().splitlines()
        start = next(i for i, line in enumerate(lines) if line.strip() == "run: |") + 1
        block = []
        for line in lines[start:]:
            if line.strip() and not line.startswith("          "):
                break
            block.append(line)
        command = textwrap.dedent("\n".join(block))
        verifier = os.environ["FM_NATIVE_TEST_VERIFIER"]
        event = self.repo / "event.json"
        output = self.repo / "output"
        native = ('Updates from [git push no-mistakes]'
                  '(https://github.com/kunchenguid/no-mistakes)\n'
                  '<!-- no-mistakes-pipeline-attestation:v1 ' + json.dumps({
                      "head_sha": self.common, "steps": [
                          {"step": step, "status": "completed"}
                          for step in ("review", "test", "document")]}) + ' -->')
        for body, bootstrap_ok, native_ok in (
                ("ordinary unsigned personal feature", True, False),
                (native, True, True),
                ("firstmate-focused-upstream", False, False),
                ("firstmate-focused-upstream\n" + native, False, False)):
            with self.subTest(body=body[:40]):
                event.write_text(json.dumps({"pull_request": {
                    "number": 23, "body": body, "head": {"sha": self.common},
                    "base": {"sha": self.common}}}))
                output.write_text("")
                env = {**os.environ, "GITHUB_EVENT_PATH": str(event),
                       "GITHUB_OUTPUT": str(output)}
                result = subprocess.run(["bash", "-e", "-c", command],
                                        cwd=self.repo, env=env, capture_output=True)
                self.assertEqual(result.returncode == 0, bootstrap_ok)
                if bootstrap_ok:
                    self.assertEqual(output.read_text(), "route=native\n")
                    env.update(PR_BODY=body, PR_HEAD_SHA=self.common,
                               PR_AUTHOR="regression", PR_NUMBER="23",
                               NM_EXEMPT_AUTHORS="", NM_EXEMPT_BOT_AUTHORS="false",
                               NM_EXEMPT_HEAD_BRANCHES="", GITHUB_EVENT_PATH="",
                               GITHUB_OUTPUT="")
                    checked = subprocess.run([sys.executable, verifier], env=env,
                                             capture_output=True)
                    self.assertEqual(checked.returncode == 0, native_ok)
                else:
                    self.assertEqual(output.read_text(), "")

    def test_workflow_entry_fetches_builds_and_qualifies_without_native_fallback(self):
        if not shutil.which("docker") or subprocess.run(
                ["docker", "info"], stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL, check=False).returncode:
            if os.environ.get("CI"):
                self.fail("hosted workflow integration requires Docker")
            self.skipTest("Docker server required for workflow integration")
        (self.repo / "tests").mkdir()
        (self.repo / "tests/fm-update.test.sh").write_text(
            '#!/bin/bash\nset -eu\n'
            'test "$(cat canonical)" = "upstream behavior"\n'
            'test "$(cat personal)" = "preserved personal behavior"\n'
            'command -v git; command -v python3\n')
        self.git("add", "tests")
        self.git("commit", "-qm", "trusted base assertions")
        self.common = self.git("rev-parse", "HEAD")
        claim, _ = self.fixture()
        claim["head_ref"] = "refs/heads/intake/upstream"
        original = self.live_api(claim)
        pr_path = f"/repos/{FOCUSED.FORK}/pulls/23"
        original[pr_path]["body"] = self.declaration(claim)
        # Only transport is redirected to real local Git object stores. The
        # production fetch/init, correspondence, Dockerfile build, sandbox and
        # final live-read decision all execute without success mocks.
        os.environ["GIT_CONFIG_COUNT"] = "2"
        for i, origin in enumerate((FOCUSED.CANONICAL, FOCUSED.FORK)):
            os.environ[f"GIT_CONFIG_KEY_{i}"] = (
                "url." + (self.repo / ".git").as_uri() + ".insteadOf")
            os.environ[f"GIT_CONFIG_VALUE_{i}"] = "https://github.com/" + origin + ".git"

        def invoke(replies, name, head=None, read=None, base=None):
            event = self.repo / (name + "-event.json")
            output = self.repo / (name + "-output")
            event.write_text(json.dumps({"pull_request": {
                "number": 23, "head": {"sha": head or claim["H"]},
                "base": {"sha": base or claim["B"]}}}))
            output.write_text("")
            os.environ.update(GITHUB_EVENT_PATH=str(event), GITHUB_OUTPUT=str(output),
                              GITHUB_WORKSPACE=str(ROOT), GITHUB_REPOSITORY=FOCUSED.FORK,
                              FM_FOCUSED_EVIDENCE=str(self.repo / name))
            code = FOCUSED.workflow_main(read_json=read or replies.__getitem__)
            if code:
                self.assertEqual(output.read_text(), "")
                raise FOCUSED.Refusal("workflow entry refused")
            route = output.read_text().strip().removeprefix("route=")
            if route == "native":
                return {"route": route}
            self.assertEqual(route, "focused")
            return json.loads((self.repo / name / "qualified.json").read_text())

        receipt = invoke(original, "workflow-positive")
        self.assertEqual(receipt["qualification"], "fresh-focused-proof")
        self.assertTrue((self.repo / "workflow-positive/qualified.json").exists())
        self.assertEqual(receipt["execution"]["T"], claim["T"])
        with self.assertRaises(FOCUSED.Refusal):
            invoke(original, "workflow-positive")
        for field, value in (("source_repository", "someone/firstmate"),
                             ("fork_repository", "someone/firstmate"),
                             ("H", self.common), ("B", self.common),
                             ("T", self.common), ("U", self.common),
                             ("evidence", "reused-success")):
            with self.subTest(forged=field):
                replies = copy.deepcopy(original)
                replies[pr_path]["body"] = self.declaration({**claim, field: value})
                # Even native-looking body data cannot rescue a focused refusal.
                replies[pr_path]["body"] += '\n<!-- no-mistakes-pipeline-attestation:v1 {} -->'
                with self.assertRaises(FOCUSED.Refusal):
                    invoke(replies, "workflow-forged-" + field)
        with self.assertRaises(FOCUSED.Refusal):
            invoke(original, "workflow-stale-event", self.common)
        with self.assertRaises(FOCUSED.Refusal):
            invoke(original, "workflow-stale-base-code", base=self.common)
        personal = self.commit_file("personal-feature", "unrelated personal change\n")
        wrong = {**claim, "H": personal,
                 "T": self.commit_tree(self.git("rev-parse", personal + "^{tree}"),
                                       claim["B"], personal)}
        replies = self.live_api(wrong)
        replies[pr_path]["body"] = self.declaration(wrong)
        with self.assertRaises(FOCUSED.Refusal):
            invoke(replies, "workflow-personal", personal)
        native = copy.deepcopy(original)
        native[pr_path]["body"] = "ordinary personal feature without native attestation"
        self.assertEqual(invoke(native, "workflow-native"), {"route": "native"})
        self.assertFalse((self.repo / "workflow-native").exists())
        calls = 0

        def switch_to_native(path):
            nonlocal calls
            calls += 1
            # First selection + six live facts reads finish before fetch/build.
            if calls > 7 and path == pr_path:
                return copy.deepcopy(native[path])
            return copy.deepcopy(original[path])

        with self.assertRaises(FOCUSED.Refusal):
            invoke(original, "workflow-route-drift", read=switch_to_native)

    def test_cli_reports_only_correspondence_not_execution(self):
        claim, current = self.fixture()
        for filename, value in (("claim.json", claim), ("facts.json", current)):
            (self.repo / filename).write_text(json.dumps(value))
        result = subprocess.run(
            [sys.executable, str(SPEC.origin), str(self.repo),
             str(self.repo / "claim.json"), str(self.repo / "facts.json")],
            text=True, check=True, stdout=subprocess.PIPE)
        self.assertEqual(json.loads(result.stdout)["execution_evidence"],
                         "not-verified")


if __name__ == "__main__":
    unittest.main()
