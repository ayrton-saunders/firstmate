"""Inactive stage-2 enrollment kernel. No CLI or production callers.

Only explicit fixture/setup authority may call this module. No function activates a
lane, starts a service, clones a repository, or changes legacy routing. Resource
claims are one atomic inventory document; descriptors/pointers are projections.
Records use canonical JSON SHA-256 envelopes, bounded single-open reads, and
monotone revisions. Lock order: inventory -> operation -> admission. Lock files
are permanent inodes, never PID/age leases. Bundle switching is not implemented.
The installed loader and this bundle use only the enrolled isolated interpreter.
"""
import contextlib
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import stat
import tempfile
import uuid

LIMIT = 1024 * 1024
MAX_FILES = 8192
NAME = re.compile(r"[a-z0-9][a-z0-9-]{0,31}\Z")
HEX = re.compile(r"[0-9a-f]{64}\Z")
STATES = {"reserved", "enrolled", "active", "retired", "aborted"}


class Refusal(ValueError):
    pass


def require(ok, reason):
    if not ok:
        raise Refusal(reason)


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True, allow_nan=False).encode()


def digest(value):
    return hashlib.sha256(canonical(value)).hexdigest()


def unique(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, "duplicate record field: " + key)
        result[key] = value
    return result


def fields(value, expected, label):
    require(isinstance(value, dict) and set(value) == set(expected.split()), "incomplete or unexpected " + label)


def safe_path(path, *, missing=False):
    original = os.fspath(path)
    path = Path(path)
    require(original == str(path) and path.is_absolute() and str(path) == os.path.normpath(path), "noncanonical or alias path")
    require(str(path) == os.path.realpath(path), "symlink or alias path: " + str(path))
    for part in [*reversed(path.parents), path]:
        try:
            info = part.lstat()
        except FileNotFoundError:
            require(missing, "missing path: " + str(part))
            continue
        require(not stat.S_ISLNK(info.st_mode), "symlink: " + str(part))
    return path


def owned(path, directory=False, trusted_tool=False):
    path = safe_path(path)
    info = path.lstat()
    require(info.st_uid in ((0, os.getuid()) if trusted_tool else (os.getuid(),)), "foreign owner: " + str(path))
    require(not info.st_mode & 0o022, "unsafe mode: " + str(path))
    require(stat.S_ISDIR(info.st_mode) if directory else stat.S_ISREG(info.st_mode), "wrong file type: " + str(path))
    if not directory:
        require(info.st_nlink == 1, "hardlinked record: " + str(path))
    return info


def read_bytes(path, limit=LIMIT, trusted_tool=False):
    before = owned(path, trusted_tool=trusted_tool)
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, "rb") as stream:
        info = os.fstat(stream.fileno())
        require((info.st_dev, info.st_ino) == (before.st_dev, before.st_ino), "replaced inode: " + str(path))
        require(info.st_size <= limit, "oversized file: " + str(path))
        data = stream.read(limit + 1)
        after = os.fstat(stream.fileno())
        require(len(data) <= limit and (info.st_size, info.st_mtime_ns, info.st_ctime_ns) ==
                (after.st_size, after.st_mtime_ns, after.st_ctime_ns), "changed snapshot: " + str(path))
    return data


def unpack(data, kind):
    try:
        record = json.loads(data, object_pairs_hook=unique)
    except (json.JSONDecodeError, UnicodeDecodeError) as exc:
        raise Refusal("invalid record") from exc
    fields(record, "schema kind revision payload digest", kind)
    require(type(record["schema"]) is int and record["schema"] == 1 and record["kind"] == kind, "wrong record schema/kind")
    require(type(record["revision"]) is int and record["revision"] > 0, "invalid revision")
    body = {k: v for k, v in record.items() if k != "digest"}
    require(record["digest"] == digest(body), "record digest mismatch")
    return record


def snapshot(path, kind):
    return unpack(read_bytes(path), kind)


def envelope(kind, revision, payload):
    body = dict(schema=1, kind=kind, revision=revision, payload=payload)
    return dict(body, digest=digest(body))


def fsync_dir(path):
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def atomic(path, data, mode=0o600):
    path = Path(path)
    owned(path.parent, True)
    if path.exists() or path.is_symlink():
        owned(path)
    fd, temporary = tempfile.mkstemp(prefix=".publish-", dir=path.parent)
    try:
        os.fchmod(fd, mode)
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        fsync_dir(path.parent)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def publish(path, kind, revision, payload):
    data = canonical(envelope(kind, revision, payload))
    require(len(data) <= LIMIT, "record size bound exceeded")
    atomic(path, data)


def private_dir(path):
    info = owned(path, True)
    require(stat.S_IMODE(info.st_mode) == 0o700, "non-private installed directory: " + str(path))


def mkdir(path):
    path = safe_path(path, missing=True)
    try:
        path.mkdir(mode=0o700)
        fsync_dir(path.parent)
    except FileExistsError:
        pass
    private_dir(path)


def create_lock(path):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    os.fsync(fd)
    os.close(fd)
    fsync_dir(Path(path).parent)


@contextlib.contextmanager
def lock(path, shared=False):
    before = owned(path)
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        info = os.fstat(fd)
        require((info.st_dev, info.st_ino) == (before.st_dev, before.st_ino), "replaced lock inode")
        fcntl.flock(fd, fcntl.LOCK_SH if shared else fcntl.LOCK_EX)
        now = owned(path)
        require((now.st_dev, now.st_ino) == (info.st_dev, info.st_ino), "replaced lock inode")
        yield
    finally:
        os.close(fd)


def initialize(base):
    """Explicit setup only; readers never call this. Parent must already exist."""
    base = Path(base)
    mkdir(base)
    create_lock(base / "inventory.lock")
    mkdir(base / "instances")
    publish(base / "claims.json", "claims", 1, {"entries": {}})


def identity(path):
    info = owned(path, True)
    return {"path": str(path), "device": info.st_dev, "inode": info.st_ino}


def git_storage(path):
    """Inspect files, never invoke Git/hooks/helpers or source application code.

    Only an empty new directory or a standalone .git directory is supported.
    The bounded storage walk includes both repos and physical object hardlinks.
    """
    path = Path(path)
    if not any(path.iterdir()):
        return []
    git = path / ".git"
    require(git.is_dir() and not git.is_symlink(), "unsupported linked-worktree/submodule Git directory: " + str(git))
    owned(git, True)
    for unsupported in ("commondir", "gitdir", "modules", "worktrees", "objects/info/alternates",
                        "objects/info/http-alternates", "info/sparse-checkout", "shallow"):
        require(not os.path.lexists(git / unsupported), "unsupported Git storage " + unsupported + ": " + str(git))
    require(not (path / ".gitmodules").exists(), "unsupported submodule layout")
    config = read_bytes(git / "config").decode("utf-8")
    require(not re.search(r"(?im)filter|sparse|worktree|include|alternate|sharedrepository|extensions", config), "unsupported Git config")
    resources = []
    count = 0
    pending = [git]
    while pending:
        current = pending.pop()
        info = owned(current, True)
        # Reserve stable storage containers, not transient refs/index/objects.
        # Future controlled Git work may create files without reallocating a
        # root or its standalone writable object-store identity.
        if current in (git, git / "objects"):
            resources.append({"path": str(current), "device": info.st_dev, "inode": info.st_ino})
        with os.scandir(current) as children:
            for child in children:
                count += 1
                require(count <= MAX_FILES, "Git storage inspection bound exceeded")
                item = Path(child.path)
                directory = child.is_dir(follow_symlinks=False)
                owned(item, directory)
                if directory:
                    pending.append(item)
    resources.sort(key=lambda item: item["path"])
    return resources


def refuse_existing_lane(path):
    # First-build enrollment is not legacy conversion, even when its physical
    # directories and Git layout are otherwise disjoint and well-formed.
    for marker in (".fm-secondmate-home", ".fm-secondmate-parent", "state"):
        require(not os.path.lexists(Path(path) / marker), "existing lane ownership: " + str(Path(path) / marker))


def manifest(request, bundle, interpreter):
    fields(request, "name binding fleet route root home backend session socket service commit", "enrollment request")
    require(isinstance(request["name"], str) and NAME.fullmatch(request["name"]) and request["name"] != "legacy", "invalid/reserved name")
    for key in ("binding", "fleet"):
        require(str(uuid.UUID(request[key])) == request[key], "invalid " + key)
    for key in ("route", "session", "service"):
        require(isinstance(request[key], str) and re.fullmatch(r"[A-Za-z0-9_.:-]{1,128}", request[key]), "invalid " + key)
    require(request["backend"] in ("herdr", "tmux", "rex"), "unsupported backend")
    require(request["session"] != "default", "default session forbidden")
    require(re.fullmatch(r"[0-9a-f]{40}", request["commit"]), "invalid commit")
    interpreter = str(safe_path(interpreter))
    tool = read_bytes(interpreter, 128 * LIMIT, trusted_tool=True)
    require(os.access(interpreter, os.X_OK), "interpreter not executable")
    require(HEX.fullmatch(bundle), "invalid bundle digest")
    root, home = safe_path(request["root"]), safe_path(request["home"])
    require(not overlaps(str(root), str(home)), "root/home path overlap")
    refuse_existing_lane(root)
    refuse_existing_lane(home)
    socket = str(safe_path(request["socket"], missing=True))
    require(not os.path.lexists(socket), "socket already exists")
    resources = {"root": identity(root), "home": identity(home),
                 "root_git": git_storage(root), "home_git": git_storage(home)}
    seen = set()
    for group in resources.values():
        for item in (group if isinstance(group, list) else [group]):
            physical = (item["device"], item["inode"])
            require(physical not in seen, "root/home share physical inode or Git storage")
            seen.add(physical)
    for repo in (root, home):
        require(not os.path.lexists(repo / ".fm-enrolled-resource"), "unexpected ownership pointer: " + str(repo))
    return dict(request, resources=resources, bundle=bundle,
                interpreter={"path": interpreter, "sha256": hashlib.sha256(tool).hexdigest()})


def overlaps(a, b):
    # Conservative on case-sensitive filesystems, necessary for default macOS.
    a, b = a.casefold(), b.casefold()
    return os.path.commonpath([a, b]) in (a, b)


def collision(candidate, other):
    for label in ("name", "binding"):
        require(candidate[label].casefold() != other[label].casefold(), "colliding " + label)
    for a in ("root", "home"):
        for b in ("root", "home"):
            x, y = candidate["resources"][a], other["resources"][b]
            require(not overlaps(x["path"], y["path"]), "colliding " + a + "/" + b + " path ancestor")
    ca = [(k, x) for k, v in candidate["resources"].items() for x in (v if isinstance(v, list) else [v])]
    cb = [(k, x) for k, v in other["resources"].items() for x in (v if isinstance(v, list) else [v])]
    physical = {(x["device"], x["inode"]): k for k, x in cb}
    for ka, x in ca:
        kb = physical.get((x["device"], x["inode"]))
        require(kb is None, "colliding " + ka + "/" + str(kb) + " inode Git storage")
    for directory in ("root", "home"):
        require(not overlaps(candidate["socket"], other[directory]) and
                not overlaps(other["socket"], candidate[directory]), "colliding socket/" + directory + " path ancestor")
    require(not overlaps(candidate["socket"], other["socket"]), "colliding socket path ancestor")
    for label in ("session", "service"):
        # A backend session namespace is reserved as a whole, not a server.
        require(candidate[label].casefold() != other[label].casefold(), "colliding " + label)


def seal_claim(entry):
    """The reservation digest is immutable; this digest covers selected state.
    Unrelated inventory updates do not change this entry's revision or digest.
    """
    entry["snapshot_digest"] = digest({k: v for k, v in entry.items() if k != "snapshot_digest"})
    return entry


def validate_frozen(frozen):
    fields(frozen, "name binding fleet route root home backend session socket service commit resources bundle interpreter", "claim manifest")
    require(isinstance(frozen["name"], str) and NAME.fullmatch(frozen["name"]) and frozen["name"] != "legacy", "invalid claim name")
    for key in ("binding", "fleet"):
        try:
            require(str(uuid.UUID(frozen[key])) == frozen[key], "invalid claim " + key)
        except (ValueError, AttributeError, TypeError) as exc:
            raise Refusal("invalid claim " + key) from exc
    require(frozen["backend"] in ("herdr", "tmux", "rex"), "unsupported claim backend")
    for key in ("route", "session", "service"):
        require(isinstance(frozen[key], str) and re.fullmatch(r"[A-Za-z0-9_.:-]{1,128}", frozen[key]), "invalid claim " + key)
    require(frozen["session"] != "default", "default session forbidden")
    require(isinstance(frozen["commit"], str) and re.fullmatch(r"[0-9a-f]{40}", frozen["commit"]), "invalid claim commit")
    require(isinstance(frozen["bundle"], str) and HEX.fullmatch(frozen["bundle"]), "invalid claim bundle")
    fields(frozen["resources"], "root home root_git home_git", "claim resources")
    fields(frozen["interpreter"], "path sha256", "interpreter")
    require(isinstance(frozen["interpreter"]["sha256"], str) and HEX.fullmatch(frozen["interpreter"]["sha256"]), "invalid interpreter digest")
    for path in [frozen[k] for k in ("root", "home", "socket")] + [frozen["interpreter"]["path"]]:
        require(isinstance(path, str) and path.startswith("/") and path == str(Path(path)) and path == os.path.normpath(path), "invalid claim path")
    require(not overlaps(frozen["root"], frozen["home"]), "claim root/home overlap")
    identities = []
    for role in ("root", "home"):
        resource = frozen["resources"][role]
        fields(resource, "path device inode", role + " identity")
        require(frozen[role] == resource["path"], "incoherent resource path")
        storage = frozen["resources"][role + "_git"]
        require(isinstance(storage, list) and len(storage) <= 2, "invalid Git storage identities")
        for item in storage:
            fields(item, "path device inode", "Git identity")
            require(item["path"] in (frozen[role] + "/.git", frozen[role] + "/.git/objects"), "foreign Git storage identity")
        identities.extend([resource, *storage])
    seen = set()
    for item in identities:
        require(type(item["device"]) is int and item["device"] >= 0 and type(item["inode"]) is int and item["inode"] > 0, "invalid physical identity")
        key = (item["device"], item["inode"])
        require(key not in seen, "shared claim physical identity")
        seen.add(key)


def inventory(base):
    private_dir(base)
    private_dir(Path(base) / "instances")
    record = snapshot(Path(base) / "claims.json", "claims")
    fields(record["payload"], "entries", "claims payload")
    entries = record["payload"]["entries"]
    require(isinstance(entries, dict) and len(entries) <= 128, "invalid inventory size")
    for name, entry in entries.items():
        fields(entry, "state manifest digest revision snapshot_digest", "claim")
        require(type(entry["revision"]) is int and entry["revision"] > 0, "invalid claim revision")
        require(entry["snapshot_digest"] == digest({k: v for k, v in entry.items() if k != "snapshot_digest"}), "claim snapshot digest mismatch")
        require(entry["state"] in STATES and entry["digest"] == digest(entry["manifest"]), "incomplete claim")
        frozen = entry["manifest"]
        validate_frozen(frozen)
        require(frozen["name"] == name, "claim name mismatch")
    return record


def claim(base, name):
    entries = inventory(base)["payload"]["entries"]
    require(name in entries, "unknown enrollment")
    return entries[name]


def reserve(base, request, bundle, interpreter):
    """Linearization is the claims replace. No external effects precede it.

    A crash before that replace has no authority/effects; every crash after it
    leaves the entire pending resource set. Setup and installation run later.
    """
    base = Path(base)
    with lock(base / "inventory.lock"):
        record = inventory(base)
        frozen = manifest(request, bundle, interpreter)
        validate_frozen(frozen)
        entries = record["payload"]["entries"]
        for existing in entries.values():
            # Aborted names/bindings are tombstones, never reused.
            if existing["state"] == "aborted":
                for key in ("name", "binding"):
                    require(frozen[key] != existing["manifest"][key], "colliding " + key)
            else:
                collision(frozen, existing["manifest"])
                verify_resources(existing, allow_missing=True)
                location = instance(base, existing["manifest"]["name"])
                if os.path.lexists(location) or existing["state"] != "reserved":
                    diagnose(base, existing["manifest"]["name"])
        require(len(entries) < 128, "inventory full")
        entries[frozen["name"]] = seal_claim(dict(state="reserved", manifest=frozen, digest=digest(frozen), revision=1))
        publish(base / "claims.json", "claims", record["revision"] + 1, {"entries": entries})
    return entries[frozen["name"]]


def verify_resources(entry, allow_missing=False):
    frozen = entry["manifest"]
    for key in ("root", "home"):
        resource = frozen["resources"][key]
        path = Path(resource["path"])
        if not os.path.lexists(path):
            require(allow_missing, "missing " + key)
            continue
        require(identity(path) == resource, "replaced inode: " + key)
        refuse_existing_lane(path)
        pointer = path / ".fm-enrolled-resource"
        if os.path.lexists(pointer):
            p = snapshot(pointer, "pointer")["payload"]
            require(canonical(p) == canonical({"binding": frozen["binding"], "claim": entry["digest"], "role": key}), "unexpected ownership pointer: " + key)
        elif entry["state"] != "reserved":
            raise Refusal("missing ownership pointer: " + key)
        # With a pointer present the directory is no longer empty.
        if frozen["resources"][key + "_git"]:
            require(git_storage(path) == frozen["resources"][key + "_git"], "changed " + key + " Git storage")
        else:
            require(set(x.name for x in path.iterdir()) <= {".fm-enrolled-resource"}, "unexpected content: " + key)


def bundle_bytes(source, origin):
    """Accepted release bytes are supplied explicitly, never recovered from root."""
    data = bytes(source)
    require(isinstance(origin, str) and re.fullmatch(r"[0-9a-f]{40}", origin), "invalid bundle origin commit")
    description = {"abi": 1, "schemas": [1], "origin": origin,
                   "imports": ["contextlib", "fcntl", "hashlib", "json", "os", "pathlib", "re", "shlex", "stat", "tempfile", "uuid"],
                   "subprocesses": [], "files": {"enrollment.py": {"sha256": hashlib.sha256(data).hexdigest(), "mode": 0o600}}}
    return digest(description), description, data


def instance(base, name):
    require(NAME.fullmatch(name) and name != "legacy", "invalid instance")
    return Path(base) / "instances" / name


def loader_bytes(base, frozen):
    location = str(instance(base, frozen["name"]))
    # This body is fixed release code with literal enrolled paths; no import from
    # the application, current directory, PYTHONPATH or user site is possible.
    body = ("BASE = " + repr(str(base)) + "\nNAME = " + repr(frozen["name"]) + "\n" + LOADER).encode()
    command = "#!/bin/sh\nexec " + shlex.quote(frozen["interpreter"]["path"]) + " -I -S " + shlex.quote(location + "/loader.py") + ' "$@"\n'
    return command.encode(), body


def install(base, name, source, origin):
    """Private exact-byte install. No selection or authority granted here.

    Deliberately no source URL, executable helper or application fallback.
    A partial bundle is not repaired implicitly; exact attended reinstall can
    supply these same accepted bytes after diagnosis.
    """
    base = Path(base)
    entry = claim(base, name)
    require(entry["state"] == "reserved", "not a pending enrollment")
    frozen = entry["manifest"]
    key, description, data = bundle_bytes(source, origin)
    require(key == frozen["bundle"], "unaccepted bundle")
    location = instance(base, name)
    mkdir(location)
    for filename in ("operation.lock", "admission.lock"):
        if not os.path.lexists(location / filename):
            create_lock(location / filename)
        owned(location / filename)
    # No inventory lock while staging/verifying the package.
    with lock(location / "operation.lock"):
        mkdir(location / "bundles")
        destination = location / "bundles" / key
        if destination.exists():
            verify_bundle(location, key)
        else:
            temporary = Path(tempfile.mkdtemp(prefix=".bundle-", dir=location / "bundles"))
            atomic(temporary / "enrollment.py", data)
            publish(temporary / "manifest.json", "bundle", 1, description)
            verify_bundle_dir(temporary, key)
            os.rename(temporary, destination)
            fsync_dir(destination.parent)
        ingress, body = loader_bytes(base, frozen)
        for filename, content, mode in (("loader.py", body, 0o600), ("ingress", ingress, 0o700)):
            path = location / filename
            if os.path.lexists(path):
                require(read_bytes(path) == content, "unexpected installed loader")
            else:
                atomic(path, content, mode)


def verify_bundle_dir(location, key):
    private_dir(location)
    require(stat.S_IMODE(owned(location / "manifest.json").st_mode) == 0o600, "bundle manifest mode mismatch")
    receipt = snapshot(location / "manifest.json", "bundle")["payload"]
    require(digest(receipt) == key, "bundle manifest digest mismatch")
    fields(receipt, "abi schemas origin imports subprocesses files", "bundle manifest")
    require(receipt["abi"] == 1 and receipt["schemas"] == [1] and receipt["subprocesses"] == [], "unsupported bundle")
    require(set(receipt["files"]) == {"enrollment.py"}, "undeclared bundle files")
    require(set(p.name for p in location.iterdir()) == {"manifest.json", "enrollment.py"}, "partial or extra bundle")
    for name, item in receipt["files"].items():
        fields(item, "sha256 mode", "bundle file")
        path = location / name
        require(stat.S_IMODE(owned(path).st_mode) == item["mode"], "bundle mode mismatch")
        require(hashlib.sha256(read_bytes(path)).hexdigest() == item["sha256"], "bundle file digest mismatch")
    return receipt


def verify_bundle(location, key):
    require(isinstance(key, str) and HEX.fullmatch(key), "invalid bundle selection")
    private_dir(location / "bundles")
    return verify_bundle_dir(location / "bundles" / key, key)


def verify_loader(base, frozen):
    location = instance(base, frozen["name"])
    private_dir(location)
    ingress, body = loader_bytes(base, frozen)
    require(read_bytes(location / "ingress") == ingress and read_bytes(location / "loader.py") == body, "loader digest mismatch")
    require(stat.S_IMODE(owned(location / "ingress").st_mode) == 0o700 and
            stat.S_IMODE(owned(location / "loader.py").st_mode) == 0o600, "loader mode mismatch")
    tool = frozen["interpreter"]
    require(hashlib.sha256(read_bytes(tool["path"], 128 * LIMIT, trusted_tool=True)).hexdigest() == tool["sha256"], "interpreter digest mismatch")
    verify_bundle(location, frozen["bundle"])


def projection(path, kind, payload):
    if os.path.lexists(path):
        record = snapshot(path, kind)
        require(record["revision"] == 1 and canonical(record["payload"]) == canonical(payload), "contradictory " + kind)
    else:
        publish(path, kind, 1, payload)


def projection_payloads(entry):
    frozen = entry["manifest"]
    result = {
        "descriptor": {"claim": entry["digest"], "manifest": frozen},
        "gate": {"binding": frozen["binding"], "generation": 0, "state": "fenced", "owner": "enrollment", "claim": entry["digest"]},
        "selection": {"bundle": frozen["bundle"], "abi": 1, "claim": entry["digest"]},
    }
    result["bootstrap"] = {
        "state": "complete", "claim": entry["digest"], "bundle": frozen["bundle"],
        "records": {kind: envelope(kind, 1, payload)["digest"] for kind, payload in result.items()},
    }
    return result


PROJECTIONS = (("descriptor", "descriptor.json"), ("gate", "gate.json"),
               ("selection", "bootstrap-selection.json"), ("bootstrap", "bootstrap-completeness.json"))


def resume(base, name):
    """Resume only the frozen enrollment, never an update or activation.

    The selected executor is fixed for this build. Missing root/home is reported
    but does not prevent installing their absent projections in the descriptor;
    ordinary activity remains closed and no application path is recreated.
    Bootstrap completion is a separate projection, never lane enrollment.
    No stage-2 path may produce enrolled or active claims, even with both
    repositories present: worker/service verification belongs to later stages.
    """
    base = Path(base)
    location = instance(base, name)
    with lock(base / "inventory.lock"), lock(location / "operation.lock"), lock(location / "admission.lock"):
        record = inventory(base)
        entry = record["payload"]["entries"].get(name)
        require(entry is not None and entry["state"] == "reserved", "enrollment cannot resume")
        frozen = entry["manifest"]
        verify_loader(base, frozen)
        verify_resources(entry, allow_missing=True)
        for role in ("root", "home"):
            path = Path(frozen[role])
            if path.exists():
                projection(path / ".fm-enrolled-resource", "pointer", {"binding": frozen["binding"], "claim": entry["digest"], "role": role})
        expected = projection_payloads(entry)
        for kind, filename in PROJECTIONS:
            projection(location / filename, kind, expected[kind])
    return diagnose(base, name)


def diagnose(base, name):
    """Bounded installed observation. No mkdir, chmod, repair, imports or execs."""
    base = Path(base)
    entry = claim(base, name)
    location = instance(base, name)
    with lock(location / "admission.lock", shared=True):
        entry = claim(base, name)
        frozen = entry["manifest"]
        verify_loader(base, frozen)
        verify_resources(entry, allow_missing=True)
        expected = projection_payloads(entry)
        records = {}
        for kind, filename in PROJECTIONS:
            if os.path.lexists(location / filename):
                value = snapshot(location / filename, kind)
                require(value["revision"] == 1 and canonical(value["payload"]) == canonical(expected[kind]), "contradictory " + kind)
                records[kind] = value["digest"]
            else:
                require(entry["state"] == "reserved", "missing " + kind)
                records[kind] = "pending"
        if records["bootstrap"] != "pending":
            require(all(value != "pending" for value in records.values()), "incomplete bootstrap projections")
            for role in ("root", "home"):
                if Path(frozen[role]).exists():
                    require(os.path.lexists(Path(frozen[role]) / ".fm-enrolled-resource"), "missing ownership pointer: " + role)
        return {"name": name, "state": entry["state"], "ordinary": "closed", "claim": entry["digest"],
                "bootstrap": "pending" if records["bootstrap"] == "pending" else "complete",
                "claim_revision": entry["revision"], "claim_snapshot": entry["snapshot_digest"],
                "records": records, "missing": [k for k in ("root", "home") if not Path(frozen[k]).exists()]}


def abort(base, name, external_absence):
    """Attended abort only. Requires absent paths and exact explicit external
    absence assertion, not age/PID inference. Stage 2 creates no services or
    sessions; later lifecycle owners must supply their own positive receipts.
    Names/bindings remain tombstones. No automatic retired release exists.
    """
    base = Path(base)
    with lock(base / "inventory.lock"):
        record = inventory(base)
        entry = record["payload"]["entries"].get(name)
        require(entry is not None and entry["state"] == "reserved", "not pending")
        frozen = entry["manifest"]
        require(external_absence == {"claim": entry["digest"], "session": frozen["session"], "service": frozen["service"], "absent": True}, "missing explicit external absence proof")
        for key in ("root", "home", "socket"):
            require(not os.path.lexists(frozen[key]), "absence not proved: " + key)
        # Never free a partial installation that might still resolve the name.
        require(not os.path.lexists(instance(base, name)), "installed ingress retention prevents abort")
        entry["state"] = "aborted"
        entry["revision"] += 1
        seal_claim(entry)
        publish(base / "claims.json", "claims", record["revision"] + 1, record["payload"])


# The loader is duplicated only as a deliberately tiny independent trust root.
# Its parser verifies the same canonical envelope before loading any bundle code.
LOADER = r'''
import hashlib
import json
import os
from pathlib import Path
import stat
import sys

def fail(reason):
    raise ValueError(reason)

def pairs(items):
    result = {}
    for k, v in items:
        if k in result:
            fail("duplicate field")
        result[k] = v
    return result

def encoded(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode()

def hashed(value):
    return hashlib.sha256(encoded(value)).hexdigest()

def read(path):
    path = Path(path)
    if str(path) != os.path.realpath(path):
        fail("symlink or alias")
    for parent in (path.parent, path.parent.parent):
        info = parent.stat()
        if info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700:
            fail("unsafe directory")
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, "rb") as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o022 or info.st_nlink != 1 or info.st_size > 1048576:
            fail("unsafe installed file")
        data = stream.read(1048577)
        after = os.fstat(stream.fileno())
        if len(data) > 1048576 or (info.st_size, info.st_mtime_ns, info.st_ctime_ns) != (after.st_size, after.st_mtime_ns, after.st_ctime_ns):
            fail("changed snapshot")
        return data, stat.S_IMODE(info.st_mode)

def record(path, kind):
    value = json.loads(read(path)[0], object_pairs_hook=pairs)
    if set(value) != {"schema", "kind", "revision", "payload", "digest"} or type(value["schema"]) is not int or value["schema"] != 1 or value["kind"] != kind or type(value["revision"]) is not int or value["revision"] < 1:
        fail("incomplete record")
    if value["digest"] != hashed({k:v for k,v in value.items() if k != "digest"}):
        fail("record digest mismatch")
    return value

try:
    if len(sys.argv) != 2 or sys.argv[1] not in ("diagnose", "resume"):
        fail("only installed diagnosis/enrollment resume supported")
    location = Path(BASE) / "instances" / NAME
    claims = record(Path(BASE) / "claims.json", "claims")["payload"]
    entry = claims["entries"][NAME]
    frozen = entry["manifest"]
    if entry["digest"] != hashed(frozen) or frozen["name"] != NAME or entry["state"] not in ("reserved", "enrolled"):
        fail("invalid claim")
    key = frozen["bundle"]
    if len(key) != 64 or any(c not in "0123456789abcdef" for c in key):
        fail("invalid bundle digest")
    selection = location / "bootstrap-selection.json"
    if os.path.lexists(selection):
        selected = record(selection, "selection")
        if selected["revision"] != 1 or encoded(selected["payload"]) != encoded({"bundle": key, "abi": 1, "claim": entry["digest"]}):
            fail("contradictory selection")
    elif entry["state"] != "reserved":
        fail("missing selection")
    bundle = location / "bundles" / key
    receipt = record(bundle / "manifest.json", "bundle")["payload"]
    if hashed(receipt) != key or set(receipt["files"]) != {"enrollment.py"} or set(p.name for p in bundle.iterdir()) != {"manifest.json", "enrollment.py"}:
        fail("partial/unverified bundle")
    code, mode = read(bundle / "enrollment.py")
    item = receipt["files"]["enrollment.py"]
    if hashlib.sha256(code).hexdigest() != item["sha256"] or mode != item["mode"]:
        fail("bundle file mismatch")
    namespace = {"__name__": "installed_enrollment"}
    exec(compile(code, str(bundle / "enrollment.py"), "exec"), namespace)
    result = namespace[sys.argv[1]](Path(BASE), NAME)
    print(json.dumps(result, sort_keys=True))
except (ValueError, OSError, KeyError, TypeError) as exc:
    print("enrollment unknown/refused: " + str(exc), file=sys.stderr)
    sys.exit(126)
'''
