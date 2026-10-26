#!/usr/bin/env python3
"""Controlled local Git histories for the production correspondence component."""

import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
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
