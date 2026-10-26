#!/usr/bin/env python3
"""Git correspondence component of focused-upstream compliance.

Usage: verify-focused-upstream.py REPOSITORY CLAIM_JSON CURRENT_FACTS_JSON
CURRENT_FACTS_JSON must come from the trusted workflow's fresh forge lookups,
not the PR body. This component checks identities and reconstructs clean Git
integration; it does NOT authenticate inspection/execution evidence or grant
compliance. Its output must never substitute for those remaining checks.
Conflicted or repaired integrations need additional proof and are refused here.
"""

import json
import os
import re
import subprocess
import sys

CANONICAL = "kunchenguid/firstmate"
FORK = "ayrton-saunders/firstmate"
SHA = re.compile(r"[0-9a-f]{40}\Z")


class Refusal(ValueError):
    pass


def require(condition, reason):
    if not condition:
        raise Refusal(reason)


class Git:
    def __init__(self, repository):
        self.repository = repository

    def run(self, *arguments, check=True):
        # Replace refs must not rewrite the history being proved. Objects are
        # fetched by the trusted caller, never by a PR-supplied .git directory.
        env = {**os.environ, "GIT_NO_REPLACE_OBJECTS": "1"}
        result = subprocess.run(
            ["git", "-C", self.repository, "--no-replace-objects", *arguments],
            env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            check=False,
        )
        if check:
            require(result.returncode == 0, "Git correspondence unavailable")
        return result

    def text(self, *arguments):
        return self.run(*arguments).stdout.strip()

    def ancestor(self, older, newer):
        return self.run("merge-base", "--is-ancestor", older, newer,
                        check=False).returncode == 0


def verify_correspondence(repository, claim, current):
    """Return correspondence facts only, never a compliance/evidence verdict."""
    require(isinstance(claim, dict) and isinstance(current, dict),
            "claim and current facts must be objects")
    identities = {
        "source_repository": CANONICAL,
        "fork_repository": FORK,
        "head_repository": FORK,
    }
    for name, expected in identities.items():
        require(current.get(name) == expected and claim.get(name) == expected,
                "wrong " + name)
    for name in ("source_ref", "base_ref", "head_ref"):
        ref = current.get(name)
        require(isinstance(ref, str) and ref.startswith("refs/heads/"),
                "missing current " + name)
        require(claim.get(name) == ref, "changed " + name)
    require(current.get("source_default") == current["source_ref"],
            "canonical ref is not current default")
    require(current.get("fork_default") == current["base_ref"],
            "fork base is not current default")
    require(current["head_ref"] != current["base_ref"],
            "publication must use an integration branch")
    for name in ("O", "U", "H", "B", "T"):
        require(isinstance(claim.get(name), str) and SHA.fullmatch(claim[name]),
                "missing full " + name + " SHA")
    for name in ("U", "H", "B", "T"):
        require(current.get(name) == claim[name], "changed current " + name)

    git = Git(repository)
    require(git.text("rev-parse", "--is-shallow-repository") == "false",
            "full history required")
    grafts = git.text("rev-parse", "--git-path", "info/grafts")
    if not os.path.isabs(grafts):
        grafts = os.path.join(repository, grafts)
    require(not os.path.exists(grafts), "grafted history is ineligible")
    for name in ("O", "U", "H", "B", "T"):
        require(git.text("cat-file", "-t", claim[name]) == "commit",
                name + " is not a commit")
    o, u, h, b, t = (claim[name] for name in ("O", "U", "H", "B", "T"))
    require(o == b, "changed base requires fresh integration proof")
    require(claim.get("conflict_history") == "clean",
            "unknown or conflicted history requires retained inspection/execution proof")
    require(h != b and not git.ancestor(u, o), "no new canonical ancestry to publish")
    require(git.ancestor(o, h) and git.ancestor(u, h),
            "integration lost fork or canonical ancestry")
    parents = git.text("show", "-s", "--format=%P", h).split()
    require((h == u and git.ancestor(o, u)) or parents == [o, u],
            "head contains unproved personal changes or reversed parents")
    merged = git.run("merge-tree", "--write-tree", o, u, check=False)
    require(merged.returncode == 0,
            "conflict resolutions require retained inspection/execution proof")
    tree = git.text("rev-parse", h + "^{tree}")
    require(merged.stdout.strip() == tree,
            "head tree differs from actual canonical integration")
    require(git.text("show", "-s", "--format=%P", t).split() == [b, h],
            "tested merge must have exact base,head parents")
    require(git.text("rev-parse", t + "^{tree}") == tree,
            "tested merge tree differs from integration")
    return {"correspondence": "verified", "H": h, "B": b, "T": t,
            "tree": tree, "execution_evidence": "not-verified"}


def main():
    if len(sys.argv) != 4:
        print(__doc__, file=sys.stderr)
        return 2
    try:
        with open(sys.argv[2], encoding="utf-8") as stream:
            claim = json.load(stream)
        with open(sys.argv[3], encoding="utf-8") as stream:
            current = json.load(stream)
        print(json.dumps(verify_correspondence(sys.argv[1], claim, current)))
        return 0
    except (Refusal, OSError, ValueError) as error:
        print("Focused correspondence refused: " + str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
