#!/usr/bin/env python3
"""Focused-upstream proof components for a trusted workflow caller.

Usage: python3 .github/verify-focused-upstream.py --workflow
       python3 .github/verify-focused-upstream.py --draft-repairs <repository> <fork-base> <repaired-head>
Draft output is untrusted until separately landed in the fork base's
.github/upstream-repairs.json through normal no-mistakes validation/approval.
The library's qualify_request composes live correspondence, retained inspection,
fresh sandbox execution and a final publication recheck. It accepts no prior
receipts. --workflow is the trusted-base Actions entry for PR classification
and any requested fresh focused qualification. Conflicted or repaired histories
cannot earn focused evidence.
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
REPAIR_RECORD = ".github/upstream-repairs.json"
CLAIM_FIELDS = frozenset({
    "source_repository", "fork_repository", "head_repository", "source_ref",
    "base_ref", "head_ref", "O", "U", "H", "B", "T", "conflict_history",
})


class Refusal(ValueError):
    pass


class GitHubNotFound(Refusal):
    pass


def require(condition, reason):
    if not condition:
        raise Refusal(reason)


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, "duplicate JSON key")
        result[key] = value
    return result


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

    def run(self, *arguments, check=True, binary=False):
        # Replace refs must not rewrite the history being proved. Objects are
        # fetched by the trusted caller, never by a PR-supplied .git directory.
        env = {**os.environ, "GIT_NO_REPLACE_OBJECTS": "1",
               "GIT_LITERAL_PATHSPECS": "1"}
        result = subprocess.run(
            ["git", "-C", self.repository, "--no-replace-objects", *arguments],
            env=env, text=not binary, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            check=False,
        )
        if check:
            require(result.returncode == 0, "Git correspondence unavailable")
        return result

    def text(self, *arguments):
        return self.run(*arguments).stdout.strip()

    def ancestor(self, older, newer):
        result = self.run("merge-base", "--is-ancestor", older, newer, check=False)
        require(result.returncode in (0, 1), "Git ancestry unavailable")
        return result.returncode == 0


def advertised_commit(read_json, repository, ref):
    encoded = urllib.parse.quote(ref, safe="")
    value = read_json(f"/repos/{repository}/git/ref/heads/{encoded}")
    require(isinstance(value, dict) and value.get("ref") == "refs/heads/" + ref,
            "wrong live advertised ref")
    obj = value.get("object")
    require(isinstance(obj, dict) and obj.get("type") == "commit" and
            isinstance(obj.get("sha"), str) and SHA.fullmatch(obj["sha"]),
            "missing live advertised commit")
    return obj["sha"]


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

    u = advertised_commit(read_json, CANONICAL, defaults[0])
    b = advertised_commit(read_json, FORK, defaults[1])
    h = advertised_commit(read_json, FORK, head["ref"])
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
    except urllib.error.HTTPError as error:
        if error.code == 404:
            raise GitHubNotFound("GitHub API object not found") from error
        raise Refusal("fresh GitHub API read unavailable") from error
    except (OSError, ValueError) as error:
        raise Refusal("fresh GitHub API read unavailable") from error


def fork_pr_snapshot(read_json, number, expected_head):
    require(type(number) is int and number > 0 and
            isinstance(expected_head, str) and SHA.fullmatch(expected_head),
            "invalid PR event")
    pr = read_json(f"/repos/{FORK}/pulls/{number}")
    require(isinstance(pr, dict) and type(pr.get("number")) is int and
            pr["number"] == number, "wrong live PR request")
    base, head = pr.get("base"), pr.get("head")
    require(isinstance(base, dict) and base.get("ref") == "main" and
            isinstance(base.get("sha"), str) and SHA.fullmatch(base["sha"]) and
            isinstance(head, dict) and head.get("sha") == expected_head,
            "invalid PR base or head no longer matches event")
    return pr


def integration_route(number, expected_head, expected_base, workspace, read_json):
    """Classify both integration shapes against one advertised canonical tip."""
    require(isinstance(expected_base, str) and SHA.fullmatch(expected_base),
            "invalid PR event base")

    def publication():
        pr = fork_pr_snapshot(read_json, number, expected_head)
        base, head = pr["base"].get("repo"), pr["head"].get("repo")
        require(pr.get("state") == "open" and isinstance(base, dict) and
                base.get("full_name") == FORK, "not an open PR into the fork")
        return (head.get("full_name") if isinstance(head, dict) else None, pr["base"]["sha"])

    def ancestor(older, newer, *, missing_is_negative=False):
        if older == newer:
            return True
        try:
            # Compare immutable objects within the base repository's fork network.
            comparison = read_json(f"/repos/{FORK}/compare/{older}...{newer}")
        except GitHubNotFound:
            if missing_is_negative:
                return False
            raise
        require(isinstance(comparison, dict), "invalid GitHub ancestry comparison")
        base = comparison.get("base_commit")
        merge_base = comparison.get("merge_base_commit")
        require(isinstance(base, dict) and base.get("sha") == older and
                isinstance(merge_base, dict) and isinstance(merge_base.get("sha"), str) and
                SHA.fullmatch(merge_base["sha"]), "invalid GitHub ancestry objects")
        status = ("ahead" if merge_base["sha"] == older else
                  "behind" if merge_base["sha"] == newer else "diverged")
        require(comparison.get("status") == status, "inconsistent GitHub ancestry comparison")
        return status == "ahead"

    head_repo, live_base = publication()
    if head_repo not in (FORK, CANONICAL) or expected_head == expected_base:
        return None
    source = read_json(f"/repos/{CANONICAL}")
    require(isinstance(source, dict) and source.get("full_name") == CANONICAL and
            source.get("fork") is False, "wrong live canonical identity")
    default = source.get("default_branch")
    require(isinstance(default, str) and default and not any(c in default for c in "\r\n"),
            "missing live canonical default branch")
    tip = advertised_commit(read_json, CANONICAL, default)
    if ancestor(expected_head, tip, missing_is_negative=True):
        # Fast-forward: the PR head itself is canonical, with no fork-only commits.
        integration = ancestor(expected_base, expected_head)
    elif head_repo == FORK:
        commit = read_json(f"/repos/{FORK}/git/commits/{expected_head}")
        require(isinstance(commit, dict) and commit.get("sha") == expected_head and
                isinstance(commit.get("parents"), list), "invalid GitHub head commit")
        parents = commit["parents"]
        require(all(isinstance(parent, dict) and isinstance(parent.get("sha"), str) and
                    SHA.fullmatch(parent["sha"]) for parent in parents), "invalid GitHub head parents")
        if len(parents) == 1:
            if (parents[0]["sha"] != expected_base and expected_head != live_base and
                    is_repaired_integration(expected_head, expected_base, live_base, tip, workspace)
                    and publication() == (head_repo, live_base)):
                return "repaired-integration"
            return None
        integration = (len(parents) == 2 and parents[0]["sha"] == expected_base and
                       ancestor(parents[1]["sha"], tip, missing_is_negative=True) and
                       not ancestor(parents[1]["sha"], expected_base))
    else:
        return None
    if integration:
        require(publication()[0] == head_repo, "PR repository changed during classification")
        return "canonical-integration"
    return None


def repair_fingerprint(git, revision):
    """Bind a complete fork or integration tree except its base-owned approval file.

    Excluding only that file permits approval to land before rebuilding the
    merge on the new base, without a self-referential commit/tree hash.
    Everything else, including modes and paths, is bound byte-for-byte.
    """
    inventory = git.run("ls-tree", "--full-tree", "-r", "-z", revision, binary=True).stdout
    entries = [entry for entry in inventory.split(b"\0") if entry and
               entry.split(b"\t", 1)[1] != REPAIR_RECORD.encode()]
    return hashlib.sha256(b"\0".join(entries) + b"\0").hexdigest()


def repair_delta(git, parent, child):
    # Exact raw deltas bind every path, old/new blob and mode, not just a
    # patch-id (which can discard whitespace). No diff drivers are executed.
    delta = git.run("diff-tree", "--no-commit-id", "--raw", "--no-renames",
                    "--no-ext-diff", "--no-relative", "--ignore-submodules=none", "--abbrev=40", "-O/dev/null",
                    "-r", "-z", parent, child, binary=True).stdout
    require(delta, "empty repair is not an integration repair")
    return hashlib.sha256(delta).hexdigest()


def repair_record(repository, base, head, *, limit=None):
    """Construct an UNTRUSTED draft; only a separately landed base approves it.

    upstream-repairs.json schema 1 contains an integrations array of exact
    records returned here: upstream SHA, fork and integration tree fingerprints,
    ordered repair delta digests. These are approvals of exact code, not claims that a
    path glob, commit message, or reviewer declaration makes code in scope.
    Only nonempty, single-parent repairs may follow the one merge.
    """
    require(all(isinstance(sha, str) and SHA.fullmatch(sha) for sha in (base, head)),
            "invalid repair endpoints")
    git = Git(repository)
    approval = git.run("ls-tree", "--full-tree", "-z", base, "--", REPAIR_RECORD, binary=True).stdout
    cursor, repairs = head, []
    while True:
        require(git.run("ls-tree", "--full-tree", "-z", cursor, "--", REPAIR_RECORD,
                        binary=True).stdout == approval,
                "integration or repair changed its approval file")
        parents = git.text("rev-list", "-1", "--parents", cursor).split()[1:]
        if len(parents) != 1:
            break
        require(cursor != base and (limit is None or len(repairs) < limit),
                "repair history exceeds approval")
        repairs.append(repair_delta(git, parents[0], cursor))
        cursor = parents[0]
    require(repairs and len(parents) == 2 and parents[0] == base,
            "repairs must follow exactly one merge from the event base")
    upstream = parents[1]
    require(not git.ancestor(upstream, base), "no new canonical ancestry")
    return {"upstream": upstream, "fork_tree": repair_fingerprint(git, base),
            "integration_tree": repair_fingerprint(git, cursor),
            "repairs": list(reversed(repairs))}


def approved_entries(records):
    if not (isinstance(records, dict) and set(records) == {"schema", "integrations"}
            and type(records["schema"]) is int and records["schema"] == 1
            and isinstance(records["integrations"], list)):
        return []
    seen = set()
    for entry in records["integrations"]:
        if not (isinstance(entry, dict) and
                set(entry) == {"upstream", "fork_tree", "integration_tree", "repairs"} and
                isinstance(entry["upstream"], str) and SHA.fullmatch(entry["upstream"]) and
                isinstance(entry["repairs"], list) and
                entry["repairs"] and
                all(isinstance(digest, str) and re.fullmatch(r"[0-9a-f]{64}", digest)
                    for digest in [entry["fork_tree"], entry["integration_tree"], *entry["repairs"]])):
            return []
        key = json.dumps(entry, sort_keys=True)
        if key in seen:
            return []
        seen.add(key)
    return records["integrations"]


def read_repair_approvals(git, base):
    record = git.run("cat-file", "blob", base + ":" + REPAIR_RECORD, check=False, binary=True)
    if record.returncode:
        return []
    try:
        return approved_entries(json.loads(record.stdout.decode("utf-8"),
                                           object_pairs_hook=unique_object))
    except (ValueError, RecursionError):
        return []


def verify_repaired_integration(repository, base, head, canonical_tip, entries, live_base):
    """Only exact, still-applicable base approvals qualify."""
    try:
        actual = repair_record(repository, base, head,
                               limit=max((len(e["repairs"]) for e in entries), default=0))
        git = Git(repository)
        upstream = actual["upstream"]
        return (actual in entries and git.ancestor(upstream, canonical_tip) and
                (base == live_base or
                 (actual in read_repair_approvals(git, live_base) and
                  actual["fork_tree"] == repair_fingerprint(git, live_base) and
                  not git.ancestor(upstream, live_base))))
    except Refusal:
        return False


def is_repaired_integration(head, base, live_base, tip, workspace):
    try:
        git = Git(workspace)
        entries = read_repair_approvals(git, base)
        if not entries:
            return False
        fork_tree = repair_fingerprint(git, base)
        entries = [entry for entry in entries if entry["fork_tree"] == fork_tree]
        if not entries:
            return False
        with tempfile.TemporaryDirectory(prefix="fm-repaired-integration-") as objects:
            fetched = Git(objects)
            fetched.run("init", "--bare", "--quiet")
            for name, origin, shas in (("fork", FORK, (head, live_base)), ("canonical", CANONICAL, (tip,))):
                fetched.run("remote", "add", name, "https://github.com/" + origin + ".git")
                fetched.run("-c", "credential.helper=", "-c", "core.hooksPath=/dev/null",
                            "fetch", "--quiet", "--no-tags", "--no-recurse-submodules",
                            "--filter=blob:none", name, *(sha + ":refs/proof/" + sha for sha in shas))
            return verify_repaired_integration(objects, base, head, tip, entries, live_base)
    except (OSError, Refusal, UnicodeError):
        return False


def requires_no_mistakes(number, expected_head, read_json=github_json):
    """Classify the fork's PR diff, independently of claims or authorship."""
    def diff_snapshot():
        pr = fork_pr_snapshot(read_json, number, expected_head)
        count = pr.get("changed_files")
        require(type(count) is int and count >= 0, "invalid changed-file count")
        return count, pr["base"]["sha"]

    count, base = diff_snapshot()
    if count > 2:
        return True
    # A small diff fits on GitHub's first page. Require agreement with the
    # aggregate and recheck the publication around the unversioned files read.
    files = read_json(f"/repos/{FORK}/pulls/{number}/files")
    require(isinstance(files, list) and len(files) == count,
            "incomplete changed-file list")
    require(diff_snapshot() == (count, base),
            "PR diff moved during classification")
    seen = set()
    protected = ("bin/", ".agents/", ".github/")
    test_roots = ("tests/", ".claude/mods/firstmate-calm/tests/")
    lines = 0
    for file in files:
        require(isinstance(file, dict), "invalid changed-file entry")
        filename = file.get("filename")
        paths = [filename]
        if file.get("status") == "renamed" or "previous_filename" in file:
            paths.append(file.get("previous_filename"))
        require(all(isinstance(name, str) and name for name in paths) and
                filename not in seen, "invalid changed-file paths")
        seen.add(filename)
        if any(name.startswith(protected) for name in paths):
            return True
        if not all(name.startswith(test_roots) for name in paths):
            for key in ("additions", "deletions"):
                value = file.get(key)
                require(type(value) is int and value >= 0, "invalid changed-file line count")
                lines += value
    return lines > 60


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


def fetch_current_objects(repository, facts):
    """Acquire full histories from fixed public origins into a new object store.

    No candidate checkout, credential helper, PR-selected URL or retained .git is
    used. SHA fetches are bound to live facts and checked again by qualification.
    """
    os.mkdir(repository, 0o700)
    subprocess.run(["git", "init", "--bare", "--quiet", repository], check=True)
    git = Git(repository)
    for origin, names in ((CANONICAL, ("U",)), (FORK, ("B", "H", "T"))):
        for name in names:
            sha = facts.get(name)
            require(isinstance(sha, str) and SHA.fullmatch(sha),
                    "invalid live fetch object")
            git.run("-c", "credential.helper=", "-c", "core.hooksPath=/dev/null",
                    "fetch", "--quiet", "--no-tags", "--no-recurse-submodules",
                    "https://github.com/" + origin + ".git",
                    sha + ":refs/qualification/" + name)
            require(git.text("rev-parse", "refs/qualification/" + name) == sha,
                    "fetched object differs from live publication")


def workflow_request(repository, number, expected_head, workspace,
                     evidence_directory, *, expected_base, read_json=github_json):
    """Classify on base-owned facts before reading any author declaration.

    Only a proven canonical integration can request focused evidence. That
    route builds an execution image from the trusted base, never the PR source.
    """
    if repository != FORK:
        return {"route": "native"}
    route = integration_route(number, expected_head, expected_base, workspace, read_json)
    if route == "repaired-integration":
        return {"route": route}
    if route is None:
        if requires_no_mistakes(number, expected_head, read_json):
            return {"route": "native"}
        return {"route": "below-threshold"}

    pr = fork_pr_snapshot(read_json, number, expected_head)
    claim = focused_claim(repository, pr.get("body"))
    if claim is None:
        return {"route": "canonical-integration"}
    facts = current_facts(read_json, number)
    require(facts["H"] == expected_head, "event head is no longer current")
    require(facts["B"] == expected_base,
            "qualification code is not from the current PR base")
    for name in ("source_repository", "fork_repository", "head_repository",
                 "source_ref", "base_ref", "head_ref", "U", "B", "H", "T"):
        require(claim[name] == facts[name], "declaration differs from live facts")
    with tempfile.TemporaryDirectory(prefix="fm-focused-workflow-") as scratch:
        objects = os.path.join(scratch, "objects.git")
        fetch_current_objects(objects, facts)
        # Build only trusted-base instructions, without token/build args or
        # candidate context. Builder output never enters the Actions channel.
        context = os.path.join(scratch, "empty-context")
        os.mkdir(context)
        result = subprocess.run(
            ["docker", "build", "--quiet", "--file",
             os.path.join(workspace, ".github/focused-upstream.Dockerfile"),
             context],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
            timeout=300, check=False)
        require(result.returncode == 0, "trusted execution image build failed")
        image = result.stdout.strip()
        require(re.fullmatch(r"sha256:[0-9a-f]{64}", image) is not None,
                "missing immutable local execution image")
        receipt = qualify_request(repository, objects, read_json, number,
                                  expected_head, image, evidence_directory)
        require(receipt.get("route") == "focused" and
                receipt.get("claim") == claim and receipt.get("current") == facts,
                "focused request changed after workflow routing")
        return receipt


def workflow_main(read_json=github_json):
    try:
        with open(os.environ["GITHUB_EVENT_PATH"], encoding="utf-8") as stream:
            event = json.load(stream)
        pr = event["pull_request"]
        number, head, base = pr["number"], pr["head"]["sha"], pr["base"]["sha"]
        require(type(number) is int and number > 0 and
                isinstance(head, str) and SHA.fullmatch(head) and
                isinstance(base, str) and SHA.fullmatch(base), "invalid PR event")
        result = workflow_request(
            os.environ["GITHUB_REPOSITORY"], number, head,
            os.environ["GITHUB_WORKSPACE"], os.environ["FM_FOCUSED_EVIDENCE"],
            read_json=read_json, expected_base=base)
        with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as stream:
            stream.write("route=" + result["route"] + "\n")
        print("PR compliance route: " + result["route"])
        return 0
    except (Refusal, OSError, ValueError, KeyError,
            subprocess.SubprocessError):
        print("PR compliance decision refused; native fallback prohibited.",
              file=sys.stderr)
        return 1


def main():
    if sys.argv[1:] == ["--workflow"]:
        return workflow_main()
    if len(sys.argv) == 5 and sys.argv[1] == "--draft-repairs":
        # Usage: --draft-repairs <repository> <fork-base> <repaired-head>
        try:
            record = repair_record(*sys.argv[2:])
            print(json.dumps({"schema": 1, "integrations": [record]}, indent=2))
            return 0
        except (Refusal, ValueError, OSError):
            print("Cannot draft repair approval from this history.", file=sys.stderr)
            return 1
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
