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
import urllib.error
import urllib.parse
import urllib.request

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


def current_facts(read_json, number):
    """Read live GitHub identities; no claim/body fields select repositories.

    read_json takes an API-relative path and must perform an authenticated fresh
    read, not load a caller's retained evidence artifact. These facts bind Git
    correspondence only; neither mergeability nor these reads prove execution.
    Call again after inspection/tests and refuse any change before accepting.
    """
    require(type(number) is int and number > 0, "invalid PR number")
    source = read_json("/repos/" + CANONICAL)
    fork = read_json("/repos/" + FORK)
    pr = read_json(f"/repos/{FORK}/pulls/{number}")
    require(all(isinstance(item, dict) for item in (source, fork, pr)),
            "malformed live repository/PR response")
    require(source.get("full_name") == CANONICAL and source.get("fork") is False,
            "wrong live canonical identity")
    require(fork.get("full_name") == FORK and fork.get("fork") is True,
            "wrong live fork identity")
    require(isinstance(source.get("id"), int) and
            isinstance(fork.get("id"), int) and source["id"] != fork["id"],
            "missing live repository ids")
    for relation in ("parent", "source"):
        upstream = fork.get(relation)
        require(isinstance(upstream, dict) and
                upstream.get("id") == source["id"] and
                upstream.get("full_name") == CANONICAL,
                "wrong live fork " + relation)
    require(pr.get("number") == number and pr.get("state") == "open" and
            pr.get("merged") is False and pr.get("mergeable") is True,
            "PR is not a current open mergeable integration")
    defaults = []
    for repo in (source, fork):
        default = repo.get("default_branch")
        require(isinstance(default, str) and default and
                not any(char in default for char in "\r\n"),
                "missing live default branch")
        defaults.append(default)
    refs = []
    for side in ("base", "head"):
        ref = pr.get(side)
        require(isinstance(ref, dict) and isinstance(ref.get("repo"), dict),
                "missing live " + side + " repository")
        require(ref["repo"].get("id") == fork["id"] and
                ref["repo"].get("full_name") == FORK,
                "wrong live " + side + " repository")
        require(isinstance(ref.get("ref"), str) and ref["ref"],
                "missing live " + side + " ref")
        refs.append(ref)
    base, head = refs
    require(base["ref"] == defaults[1] and head["ref"] != base["ref"],
            "PR does not target fork default from an integration branch")

    def advertised(repository, ref):
        encoded = urllib.parse.quote(ref, safe="")
        value = read_json(f"/repos/{repository}/git/ref/heads/{encoded}")
        require(isinstance(value, dict) and value.get("ref") == "refs/heads/" + ref,
                "wrong live advertised ref")
        obj = value.get("object")
        require(isinstance(obj, dict) and obj.get("type") == "commit" and
                isinstance(obj.get("sha"), str) and SHA.fullmatch(obj["sha"]),
                "missing live advertised commit")
        return obj["sha"]

    u = advertised(CANONICAL, defaults[0])
    b = advertised(FORK, defaults[1])
    h = advertised(FORK, head["ref"])
    require(base.get("sha") == b and head.get("sha") == h,
            "PR and advertised publication disagree; retry fresh qualification")
    t = pr.get("merge_commit_sha")
    require(isinstance(t, str) and SHA.fullmatch(t), "missing current tested merge")
    return {"source_repository": CANONICAL, "fork_repository": FORK,
            "head_repository": FORK, "source_ref": "refs/heads/" + defaults[0],
            "source_default": "refs/heads/" + defaults[0],
            "base_ref": "refs/heads/" + defaults[1],
            "fork_default": "refs/heads/" + defaults[1],
            "head_ref": "refs/heads/" + head["ref"], "U": u, "B": b,
            "H": h, "T": t}


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def github_json(path):
    """Fixed GitHub API origin, no redirects or credential-bearing diagnostics."""
    require(path.startswith("/repos/") and "?" not in path and "#" not in path,
            "invalid GitHub API path")
    headers = {"Accept": "application/vnd.github+json",
               "X-GitHub-Api-Version": "2022-11-28"}
    token = os.environ.get("GITHUB_TOKEN")
    if token:
        headers["Authorization"] = "Bearer " + token
    request = urllib.request.Request("https://api.github.com" + path, headers=headers)
    try:
        with urllib.request.build_opener(NoRedirect).open(request, timeout=30) as response:
            return json.load(response)
    except (OSError, ValueError) as error:
        raise Refusal("fresh GitHub API read unavailable") from error


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
