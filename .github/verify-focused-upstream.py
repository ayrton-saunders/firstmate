#!/usr/bin/env python3
"""Focused-upstream proof components for a trusted workflow caller.

Usage: verify-focused-upstream.py REPOSITORY CLAIM_JSON CURRENT_FACTS_JSON
The CLI checks correspondence only, not inspection/execution or compliance.
CURRENT_FACTS_JSON must come from fresh trusted forge lookups, not the PR body.
The library's qualify_request composes live correspondence, retained inspection,
fresh sandbox execution and a final publication recheck. It accepts no prior
receipts. Trusted workflow execution/transport is required and is not supplied
by this CLI. Conflicted or repaired integrations are conservatively refused.
"""

import hashlib
import json
import os
import re
import subprocess
import sys
import tarfile
import tempfile
import urllib.error
import urllib.parse
import urllib.request
import uuid

CANONICAL = "kunchenguid/firstmate"
FORK = "ayrton-saunders/firstmate"
SHA = re.compile(r"[0-9a-f]{40}\Z")
FOCUSED_MARKER = "firstmate-focused-upstream"
CLAIM_FIELDS = frozenset({
    "source_repository", "fork_repository", "head_repository", "source_ref",
    "base_ref", "head_ref", "O", "U", "H", "B", "T", "conflict_history",
})


class Refusal(ValueError):
    pass


def require(condition, reason):
    if not condition:
        raise Refusal(reason)


def focused_claim(repository, body):
    """Select the fork-only alternative, never fall back on a bad declaration.

    A declaration requests fresh verification; it is not inspection/execution
    evidence. Native-only bodies keep the existing action's baseline behavior.
    Nonfork repositories retain that behavior even if their body uses this text.
    """
    if repository != FORK:
        return None
    require(body is None or isinstance(body, str), "malformed live PR body")
    body = body or ""
    if FOCUSED_MARKER not in body:
        return None
    require(body.count(FOCUSED_MARKER) == 1, "ambiguous focused declarations")
    match = re.search(r"<!-- firstmate-focused-upstream:v1 (.*?) -->", body,
                      re.DOTALL)
    require(match is not None, "malformed or unsupported focused declaration")
    require(len(match[1]) <= 16384, "oversized focused declaration")

    def unique_object(pairs):
        result = {}
        for key, value in pairs:
            require(key not in result, "duplicate focused declaration field")
            result[key] = value
        return result

    try:
        claim = json.loads(match[1], object_pairs_hook=unique_object)
    except ValueError as error:
        raise Refusal("invalid focused declaration JSON") from error
    require(isinstance(claim, dict) and set(claim) == CLAIM_FIELDS,
            "focused declaration must contain only correspondence fields")
    require(all(isinstance(value, str) for value in claim.values()),
            "focused declaration fields must be strings")
    return claim


def verify_request(repository, git_repository, read_json, number, expected_head):
    """Fresh request routing and correspondence, NOT an execution verdict.

    The trusted workflow supplies its event head to prevent a queued old run
    qualifying a newer publication. No claim field selects a URL or command.
    An exception is terminal for this request, including a body that also carries
    structurally acceptable legacy native JSON. The caller must not catch it
    and invoke the native action instead.
    """
    if repository != FORK:
        return {"route": "native"}
    require(type(number) is int and number > 0, "invalid PR number")
    pr = read_json(f"/repos/{FORK}/pulls/{number}")
    require(isinstance(pr, dict) and pr.get("number") == number,
            "wrong live PR request")
    claim = focused_claim(repository, pr.get("body"))
    if claim is None:
        return {"route": "native"}
    head = pr.get("head")
    require(isinstance(expected_head, str) and SHA.fullmatch(expected_head) and
            isinstance(head, dict) and head.get("sha") == expected_head,
            "event head is no longer the current publication")
    facts = current_facts(read_json, number)
    require(facts["H"] == expected_head, "publication changed during routing")
    result = verify_correspondence(git_repository, claim, facts)
    return {"route": "focused", "claim": claim, "current": facts,
            **result}


class Git:
    def __init__(self, repository):
        self.repository = repository

    def run(self, *arguments, check=True):
        # Replace refs must not rewrite the history being proved. Objects are
        # fetched by the trusted caller, never by a PR-supplied .git directory.
        env = {**os.environ, "GIT_NO_REPLACE_OBJECTS": "1",
               "GIT_LITERAL_PATHSPECS": "1"}
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
            "source_id": source["id"], "fork_id": fork["id"],
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


def inspect_personal_delta(repository, claim, current, evidence_directory):
    """Inspect exact personal-file preservation, retaining actual Git patches.

    This bounded deterministic inspection supports clean integrations whose
    existing personal paths are byte-for-byte preserved, including modes and
    deletions. Overlapping upstream/personal changes need substantive resolution
    review beyond this inspector and are refused, even when Git merges cleanly.
    No caller artifact, body assertion or historical clean claim proves this:
    correspondence and every personal path are independently recomputed now.
    """
    correspondence = verify_correspondence(repository, claim, current)
    evidence = os.path.abspath(evidence_directory)
    os.mkdir(evidence, 0o700)
    git = Git(repository)
    bases = git.text("merge-base", "--all", claim["O"], claim["U"]).splitlines()
    require(len(bases) == 1, "ambiguous personal-delta merge base")
    ancestor = bases[0]
    paths = git.run("diff", "--name-only", "--no-renames", "-z", ancestor,
                    claim["O"], "--").stdout.split("\0")
    paths = [path for path in paths if path]
    inspected = []
    for path in paths:
        # Literal pathspecs prevent a repository filename from selecting other
        # paths. ls-tree includes mode/type/object/name and represents deletion
        # by empty output; it does not execute candidate tools or diff drivers.
        before = git.run("ls-tree", "-z", claim["O"], "--", path).stdout
        after = git.run("ls-tree", "-z", claim["H"], "--", path).stdout
        require(before == after,
                "personal path changed; substantive overlap/resolution inspection required")
        inspected.append({"path": path, "base_entry": before,
                          "head_entry": after})
    patches = {}
    for name, older, newer in (
            ("personal.patch", ancestor, claim["O"]),
            ("canonical.patch", ancestor, claim["U"]),
            ("integration.patch", claim["O"], claim["H"])):
        patch = git.run("diff", "--binary", "--no-ext-diff", "--no-textconv",
                        "--no-renames", older, newer, "--").stdout
        data = patch.encode("utf-8")
        with open(os.path.join(evidence, name), "xb") as stream:
            stream.write(data)
        patches[name] = hashlib.sha256(data).hexdigest()
    receipt = {key: correspondence[key] for key in ("H", "B", "T", "tree")}
    receipt.update(inspection_evidence="fresh-exact-personal-path-inspection",
                   merge_base=ancestor, conflict_history="reconstructed-clean",
                   personal_paths=inspected, patches=patches)
    with open(os.path.join(evidence, "inspection.json"), "x", encoding="utf-8") as stream:
        json.dump(receipt, stream, sort_keys=True)
    return receipt


def execute_focused_tests(repository, correspondence, image, evidence_directory):
    """Execute fresh personal-behavior tests without giving PR code host access.

    This is called only after correspondence verification, by trusted workflow
    code. image and evidence_directory are workflow-owned, never claim fields.
    No retained receipt is an input. The container receives only a Git archive,
    no .git directory, token, host environment, network or writable host mount.
    This proves execution, not semantic human inspection or conflict provenance;
    callers must not treat it alone as a complete compliance verdict.
    """
    require(correspondence.get("correspondence") == "verified",
            "execution requires verified correspondence")
    for name in ("H", "B", "T"):
        require(isinstance(correspondence.get(name), str) and
                SHA.fullmatch(correspondence[name]), "missing execution " + name)
    require(isinstance(image, str) and image and not image.startswith("-"),
            "missing trusted execution image")
    evidence = os.path.abspath(evidence_directory)
    # The caller must allocate a new directory for each attempt. Refusing reuse
    # prevents accidental substitution of an earlier head's retained result.
    os.mkdir(evidence, 0o700)
    git = Git(repository)
    for name in ("H", "T"):
        require(git.text("rev-parse", correspondence[name] + "^{tree}") ==
                correspondence["tree"], "changed execution tree")
    with tempfile.TemporaryFile() as archive:
        # Keep the test definitions owned by the trusted current fork base.
        # Head changes, even canonical ones, cannot replace the assertions that
        # decide whether this head preserves existing personal behavior.
        with tarfile.open(fileobj=archive, mode="w") as bundle:
            for filename, revision, paths in (
                    ("candidate.tar", correspondence["T"], []),
                    ("trusted-tests.tar", correspondence["B"], ["tests"])):
                with tempfile.TemporaryFile() as content:
                    result = subprocess.run(
                        ["git", "-C", repository, "--no-replace-objects", "archive",
                         "--format=tar", revision, *paths], stdout=content,
                        stderr=subprocess.PIPE, check=False)
                    require(result.returncode == 0, "execution archive unavailable")
                    member = tarfile.TarInfo(filename)
                    member.size = content.tell()
                    content.seek(0)
                    bundle.addfile(member, content)
        archive.seek(0)
        # docker does not inherit environment unless explicitly requested. All
        # test output is retained as data, never interpreted as Actions commands.
        # The script cannot control the verdict through output files or stdout.
        container = "fm-focused-" + uuid.uuid4().hex
        command = [
            "docker", "run", "--name=" + container, "--rm", "--network=none", "--read-only",
            "--cap-drop=ALL", "--security-opt=no-new-privileges",
            "--pids-limit=256", "--memory=2g", "--cpus=2",
            "--user=65534:65534", "--tmpfs=/tmp:rw,nosuid,nodev,size=1g",
            "--workdir=/tmp", "--interactive", "--entrypoint=/bin/bash",
            image, "-euc",
            "tar -xf -; mkdir source; tar -xf candidate.tar -C source; "
            "rm -rf source/tests; tar -xf trusted-tests.tar -C source; cd source; "
            "export HOME=/tmp/home; mkdir -p \"$HOME\"; "
            "bash tests/fm-update.test.sh",
        ]
        with open(os.path.join(evidence, "execution.log"), "wb") as log:
            try:
                result = subprocess.run(command, stdin=archive, stdout=log,
                                        stderr=subprocess.STDOUT, timeout=300,
                                        check=False)
            except subprocess.TimeoutExpired as error:
                raise Refusal("focused execution exceeded its bound") from error
            finally:
                # Scope cleanup to this invocation, including timeout paths.
                subprocess.run(["docker", "rm", "--force", container],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                               timeout=30, check=False)
        require(result.returncode == 0, "focused personal-behavior tests failed")
    with open(os.path.join(evidence, "execution.log"), "rb") as log:
        digest = hashlib.sha256(log.read()).hexdigest()
    receipt = {key: correspondence[key] for key in ("H", "B", "T", "tree")}
    receipt.update(execution_evidence="fresh-sandbox-execution",
                   test="bash tests/fm-update.test.sh", log_sha256=digest,
                   inspection_evidence="not-verified")
    with open(os.path.join(evidence, "execution.json"), "x", encoding="utf-8") as stream:
        json.dump(receipt, stream, sort_keys=True)
    return receipt


def qualify_request(repository, git_repository, read_json, number, expected_head,
                    image, evidence_directory):
    """Compose fresh proof, inspection and execution, then recheck publication.

    Only trusted workflow code may call this with a workflow-owned Git object
    store, image and new evidence directory. No receipt is accepted as input.
    Failure is terminal, never permission to retry through the native action.
    Workflow transport/required-context wiring remains a separate caller concern.
    """
    request = verify_request(repository, git_repository, read_json, number,
                             expected_head)
    if request["route"] == "native":
        return request
    evidence = os.path.abspath(evidence_directory)
    os.mkdir(evidence, 0o700)
    inspection = inspect_personal_delta(
        git_repository, request["claim"], request["current"],
        os.path.join(evidence, "inspection"))
    execution = execute_focused_tests(
        git_repository, request, image, os.path.join(evidence, "execution"))
    # A test run cannot qualify a later body, canonical tip, fork base, head or
    # tested merge. Refetch the full request, not merely the event's head SHA.
    refreshed = verify_request(repository, git_repository, read_json, number,
                               expected_head)
    require(refreshed == request,
            "focused request changed during inspection/execution")
    receipt = {key: request[key] for key in ("H", "B", "T", "tree")}
    receipt.update(route="focused", qualification="fresh-focused-proof",
                   claim=request["claim"], current=request["current"],
                   inspection=inspection, execution=execution)
    with open(os.path.join(evidence, "qualified.json"), "x", encoding="utf-8") as stream:
        json.dump(receipt, stream, sort_keys=True)
    return receipt


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
