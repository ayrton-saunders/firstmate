"""Inactive enrollment kernel and stage-3a typed admission/outer-reader owner.

No application dispatcher or named producer is enabled. Only explicit fixture/
setup authority calls the reader primitives. No function activates a
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


def atomic(path, data, mode=0o600, *, repair=False):
    path = Path(path)
    owned(path.parent, True)
    if path.exists() or path.is_symlink():
        if repair:
            info = safe_path(path).lstat()
            require(stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid() and info.st_nlink == 1,
                    "unsafe repair target: " + str(path))
        else:
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


def authority_dirs(base, *, creating=False):
    base = safe_path(base, missing=creating)
    for role, path in (("parent", base.parent), ("base", base)):
        if creating and role == "base" and not path.exists():
            continue
        info = path.lstat()
        mode = stat.S_IMODE(info.st_mode)
        require(stat.S_ISDIR(info.st_mode) and info.st_uid == os.getuid() and mode == 0o700,
                f"authority {role} directory {path}: actual mode {mode:04o}; owned mode 0700 required")


def initialize(base):
    """Explicit setup only; readers never call this. Parent must already exist."""
    base = Path(base)
    authority_dirs(base, creating=True)
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


def recovery_placement(base, manifests):
    paths = [str(base)]
    for frozen in manifests:
        paths.extend((frozen["interpreter"]["path"],
                      str(instance(base, frozen["name"]) / "bundles" / frozen["bundle"])))
    paths = [(path, os.path.realpath(path).casefold()) for path in paths]
    for frozen in manifests:
        for role, group in frozen["resources"].items():
            for resource in group if isinstance(group, list) else [group]:
                protected = resource["path"]
                for path, physical in paths:
                    require(os.path.commonpath([physical, protected.casefold()]) != protected.casefold(),
                            f"recovery path {path} is inside protected {frozen['name']} {role}: {protected}")


def inventory(base):
    authority_dirs(base)
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
    recovery_placement(base, [entry["manifest"] for entry in entries.values()])
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
        recovery_placement(base, [frozen, *(entry["manifest"] for entry in entries.values())])
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
    This explicit owner repairs only the frozen bundle from accepted bytes.
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
        if os.path.lexists(destination):
            private_dir(destination)
            require(set(p.name for p in destination.iterdir()) <= {"enrollment.py", "manifest.json"}, "extra bundle files")
            atomic(destination / "enrollment.py", data, repair=True)
            atomic(destination / "manifest.json", canonical(envelope("bundle", 1, description)), repair=True)
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
            atomic(path, content, mode, repair=True)


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


# Protocol 2 is data, never a shell/argv dispatcher. These schemas are also the
# capability table: an operation class is derived here, not supplied by callers.
# No production producer, activation, or application executor is provided yet.
TOKEN = re.compile(r"[a-zA-Z0-9][a-zA-Z0-9_.-]{0,95}\Z")
COMMIT = re.compile(r"[0-9a-f]{40}\Z")
REQUEST_LIMIT = 65536
TEXT_LIMIT = 16384
VERBS = {
    # verb: (capability, required typed body fields). No arbitrary file/argv.
    "observe": ("observe", ""),
    "probe": ("observe", "challenge"),
    "reply-read": ("reply-read", "task correlation"),
    "reply-ack": ("reply-ack", "task correlation result_digest"),
    "task-answer": ("task-answer", "task correlation text"),
    "task-steer": ("task-steer", "task correlation text"),
    "inherit-apply": ("inherit", "material content content_digest"),
    "sync-verify": ("verify", "parent_commit"),
    "dispatch": ("dispatch", "task instructions_digest"),
    "launch": ("launch", "task reader launch_digest"),
    "relaunch": ("relaunch", "task incarnation launch_digest"),
    "stop": ("stop", "task incarnation"),
    "cleanup": ("cleanup", "task incarnation"),
    "repair-accepted": ("repair", "resource accepted_commit"),
    "update-prepare": ("prepare", "operation target_commit source_digest resources_digest"),
    "operation-step": ("transition", "operation transition expected_revision"),
    "operation-status": ("operation-status", "operation"),
    "abort-before-stop": ("abort", "operation expected_revision"),
}
# Only these finite private data artifacts can ever be inherited. Configuration,
# code, launch files, source selection and ownership are deliberately absent.
MATERIALS = {"captain-shared", "learnings-shared"}
REPAIR_RESOURCES = {"worker-projection", "service-projection", "ingress-projection"}
# This stage has no update state machine. A transition cannot smuggle in its own
# payload or executable; later stages must implement each legal state edge.
TRANSITIONS = {"fence", "drain", "status"}


def token(value, label):
    require(isinstance(value, str) and TOKEN.fullmatch(value), "invalid " + label)


def sha(value, label):
    require(isinstance(value, str) and HEX.fullmatch(value), "invalid " + label)


def commit(value, label):
    require(isinstance(value, str) and COMMIT.fullmatch(value), "invalid " + label)


def positive(value, label, zero=False):
    require(type(value) is int and (0 if zero else 1) <= value <= 2**53 - 1, "invalid " + label)


def uuid_text(value, label):
    require(isinstance(value, str), "invalid " + label)
    try:
        require(str(uuid.UUID(value)) == value, "noncanonical " + label)
    except (ValueError, AttributeError) as exc:
        raise Refusal("invalid " + label) from exc


def typed_request(data):
    """Capture/validate bounded untrusted bytes outside admission.

    Root/home are optional expectations in typed_body, never selectors. The
    digest covers every validated field except request_digest itself, including
    expectations. Re-run this parser at staging, claim and result verification.
    """
    require(isinstance(data, bytes) and len(data) <= REQUEST_LIMIT, "oversized/nonbyte request")
    try:
        request = json.loads(data.decode("utf-8"), object_pairs_hook=unique)
    except (ValueError, UnicodeDecodeError, RecursionError) as exc:
        raise Refusal("invalid protocol-2 JSON") from exc
    fields(request, "version instance binding fleet route generation expected_commit request_id request_digest verb typed_body", "typed request")
    require(type(request["version"]) is int and request["version"] == 2, "unsupported protocol")
    require(isinstance(request["instance"], str) and NAME.fullmatch(request["instance"]) and request["instance"] != "legacy", "invalid instance")
    for key in ("binding", "fleet"):
        uuid_text(request[key], key)
    require(isinstance(request["route"], str) and re.fullmatch(r"[A-Za-z0-9_.:-]{1,128}", request["route"]), "invalid route")
    token(request["request_id"], "request_id")
    positive(request["generation"], "generation", zero=True)
    commit(request["expected_commit"], "expected_commit")
    verb = request["verb"]
    require(isinstance(verb, str) and verb in VERBS, "unknown named verb")
    body = request["typed_body"]
    require(isinstance(body, dict), "invalid typed body")
    required = set(VERBS[verb][1].split())
    require(required <= set(body) <= required | {"expectations"}, "incomplete/unexpected typed body")
    expectations = body.get("expectations", {})
    require(isinstance(expectations, dict) and set(expectations) <= {"root", "home"}, "unexpected authority expectation")
    for path in expectations.values():
        require(isinstance(path, str) and path.startswith("/") and path == os.path.normpath(path) and len(path) <= 4096 and "\x00" not in path, "invalid path expectation")
    for key, value in body.items():
        if key == "expectations":
            continue
        if key.endswith("_digest"):
            sha(value, key)
        elif key.endswith("_commit"):
            commit(value, key)
        elif key == "expected_revision":
            positive(value, key)
        elif key in {"text", "content"}:
            require(isinstance(value, str) and "\x00" not in value, "invalid " + key)
            try:
                require(len(value.encode("utf-8")) <= TEXT_LIMIT, "oversized " + key)
            except UnicodeEncodeError as exc:
                raise Refusal("invalid UTF-8 " + key) from exc
        else:
            token(value, key)
    if verb == "launch":
        require(body["reader"] in READER_ENTRIES, "unclassified application reader")
    if verb == "inherit-apply":
        require(body["material"] in MATERIALS, "unapproved private material")
        require(hashlib.sha256(body["content"].encode()).hexdigest() == body["content_digest"], "content digest mismatch")
    if verb == "repair-accepted":
        require(body["resource"] in REPAIR_RESOURCES, "unowned repair resource")
    if verb == "operation-step":
        require(body["transition"] in TRANSITIONS, "unimplemented transition")
    computed = digest({key: value for key, value in request.items() if key != "request_digest"})
    sha(request["request_digest"], "request_digest")
    require(request["request_digest"] == computed, "request digest mismatch")
    return request


def request_class(request):
    # Even trusted internal callers must not turn a mutable dict into authority.
    checked = typed_request(canonical(request))
    return VERBS[checked["verb"]][0]


def adapter_expectations(request, route, home):
    """Legacy-shaped wrapper argv is an expectation, never a second selector."""
    checked = typed_request(canonical(request))
    require(route == checked["route"], "positional route mismatch")
    require(home == checked["typed_body"].get("expectations", {}).get("home"), "positional home mismatch")
    return checked


def verify_result(request_bytes, result):
    request = typed_request(request_bytes)
    fields(result, "binding generation request_id request_digest outcome", "typed result")
    for key in ("binding", "generation", "request_id", "request_digest"):
        require(type(result[key]) is type(request[key]) and result[key] == request[key], "result " + key + " mismatch")
    require(result["outcome"] in {"complete", "refused", "not-executed", "partial", "unknown", "update-required"}, "invalid result outcome")
    return result


def admission_snapshot(base, name):
    """Caller holds inventory then admission; all records are opened once.

    No context environment variable chooses the installation, gate or physical
    resources. The installed loader supplies literal base/name values.
    """
    entry = claim(base, name)
    frozen = entry["manifest"]
    location = instance(base, name)
    descriptor = snapshot(location / "descriptor.json", "descriptor")
    require(descriptor["payload"] == {"claim": entry["digest"], "manifest": frozen}, "descriptor/claim mismatch")
    verify_loader(base, frozen)
    selected = snapshot(location / "bootstrap-selection.json", "selection")
    require(selected["revision"] == 1 and selected["payload"] == {"bundle": frozen["bundle"], "abi": 1, "claim": entry["digest"]}, "contradictory selection")
    verify_resources(entry)
    gate = snapshot(location / "gate.json", "gate")
    payload = gate["payload"]
    fields(payload, "binding generation state owner claim", "admission gate")
    require(payload.get("binding") == frozen["binding"] and payload.get("claim") == entry["digest"], "gate/claim mismatch")
    positive(payload.get("generation"), "gate generation", zero=True)
    require(payload.get("state") in {"released", "fenced"}, "unknown gate state")
    require(entry["state"] == "active", "inactive enrollment")
    for key in ("FM_ROOT_OVERRIDE", "FM_STATE_OVERRIDE", "FM_REMOTE_JOB_STATE_OVERRIDE"):
        require(key not in os.environ, "production override refused: " + key)
    require("FM_HOME" not in os.environ or os.environ["FM_HOME"] == frozen["home"], "contradictory home lineage")
    return entry, gate


@contextlib.contextmanager
def admission(base, name):
    base = Path(base)
    with lock(base / "inventory.lock"), lock(instance(base, name) / "admission.lock"):
        yield admission_snapshot(base, name)


def request_authority(entry, gate, request, operands):
    """Re-derived at each boundary against actual, not environment, operands.

    The outer reader protects loaded code, not another lane or arbitrary Git
    movement. Code/provision/ref operations are never ordinary capabilities.
    """
    checked = typed_request(canonical(request))
    frozen, current = entry["manifest"], gate["payload"]
    for key, expected in (("instance", frozen["name"]), ("binding", frozen["binding"]),
                          ("fleet", frozen["fleet"]), ("route", frozen["route"]),
                          ("generation", current["generation"]), ("expected_commit", frozen["commit"])):
        require(checked[key] == expected, "request " + key + " mismatch")
    require(isinstance(operands, dict) and set(operands) == {"root", "home"}, "missing actual resource operands")
    for role in ("root", "home"):
        path = str(safe_path(operands[role]))
        require(path == frozen[role] and identity(path) == frozen["resources"][role], "foreign physical " + role)
    for role, path in checked["typed_body"].get("expectations", {}).items():
        require(path == frozen[role], "resource expectation mismatch")
    if checked["verb"] == "repair-accepted":
        require(checked["typed_body"]["accepted_commit"] == frozen["commit"], "repair version mismatch")
    if checked["verb"] == "sync-verify":
        require(checked["typed_body"]["parent_commit"] == frozen["commit"], "update-required")
    require(current["state"] == "released", "registration closed by fence")
    return request_class(checked)


def population(location):
    """One durable ledger; pending starts remain consumers after owner death.

    Terminal records remain in this stage. No timer, PID probe, heartbeat,
    garbage collector, or controller lifetime can remove a registration.
    """
    path = location / "population.json"
    if not os.path.lexists(path):
        return envelope("population", 1, {"leases": {}, "requests": {}})
    record = snapshot(path, "population")
    fields(record["payload"], "leases requests", "population")
    require(isinstance(record["payload"]["leases"], dict) and isinstance(record["payload"]["requests"], dict), "invalid population")
    return record


def save_population(location, record):
    publish(location / "population.json", "population", record["revision"] + 1, record["payload"])


def stage_request(base, name, data, operands):
    request = typed_request(data)  # bounded capture is outside all locks
    with admission(base, name) as (entry, gate):
        capability = request_authority(entry, gate, request, operands)
        location = instance(base, name)
        record = population(location)
        requests = record["payload"]["requests"]
        key = request["request_id"]
        if key in requests:
            require(requests[key]["request"] == request, "request id reused with different intent")
            return requests[key]
        queued = {"request": request, "capability": capability, "state": "queued"}
        requests[key] = queued
        save_population(location, record)
        return queued


def reserve_execution(base, name, data, operands, executable_digest):
    """Before any application read, publish a pending single-reader nonce.

    Only typed launch intent binds an application-byte manifest in this slice.
    No task/service is launched here, and observation never permits app reads.
    Inherited/detached consumer handoffs are deliberately not implemented.
    """
    request = typed_request(data)
    sha(executable_digest, "executable digest")
    with admission(base, name) as (entry, gate):
        capability = request_authority(entry, gate, request, operands)
        require(capability == "launch", "no application reader capability for this verb")
        require(request["typed_body"]["launch_digest"] == executable_digest, "unbound application manifest")
        location = instance(base, name)
        record = population(location)
        queued = record["payload"]["requests"].get(request["request_id"])
        require(queued is not None and queued["request"] == request and queued["state"] == "queued", "unstaged/already claimed request")
        leases = record["payload"]["leases"]
        nonce = uuid.uuid4().hex
        leases[nonce] = {"nonce": nonce, "binding": request["binding"], "generation": request["generation"],
                         "request_id": request["request_id"], "request_digest": request["request_digest"],
                         "task": request["typed_body"].get("task"), "correlation": request["typed_body"].get("correlation"),
                         "resources": entry["manifest"]["resources"], "executable_digest": executable_digest,
                         "capability": capability, "state": "pending"}
        queued["state"] = "claimed"
        queued["lease"] = nonce
        save_population(location, record)
        return nonce


# This slice has no named application dispatcher. Paths here are the CLOSED
# reader kinds for the installed owner, not caller-supplied executable paths.
# Stage 3b must wire their launch/source/callback consumers and actual effects.
READER_ENTRIES = {
    "shell-entry": "bin/fm-remote-entrypoint.sh",
    "source-module": "bin/fm-remote-job-lib.sh",
    "python-import": "bin/fm-record-export.py",
    "callback": "bin/fm-procevent-when.sh",
}


def read_registered_application(base, name, nonce, reader_kind, operands):
    """Installed outer reader, never a retroactive in-script guard.

    A caller gets fresh manifest-bound bytes, NOT permission to execute bytes it read
    before registration. No API validates buffered interpreter bytes against a
    current file hash. A local trampoline must exec the installed launcher and
    discard its interpreter; source/import/callback owners must enter here
    before their first read. Wiring those consumers is not claimed in 3a.
    """
    require(isinstance(reader_kind, str) and reader_kind in READER_ENTRIES, "unclassified application reader")
    require(isinstance(nonce, str) and re.fullmatch(r"[0-9a-f]{32}", nonce), "missing installed registration")
    with admission(base, name) as (entry, gate):
        location = instance(base, name)
        record = population(location)
        lease = record["payload"]["leases"].get(nonce)
        require(lease is not None and lease["state"] == "pending", "missing/unusable installed registration")
        queued = record["payload"]["requests"].get(lease["request_id"])
        require(queued is not None and queued["state"] == "claimed" and queued.get("lease") == nonce, "unbound reader registration")
        request = typed_request(canonical(queued["request"]))
        capability = request_authority(entry, gate, request, operands)
        require(lease["binding"] == request["binding"] and lease["generation"] == request["generation"]
                and lease["request_digest"] == request["request_digest"] and lease["capability"] == capability
                and lease["resources"] == entry["manifest"]["resources"] and capability == "launch"
                and lease["executable_digest"] == request["typed_body"]["launch_digest"]
                and reader_kind == request["typed_body"]["reader"], "contradictory reader registration")
        # Only NOW may even stat/open the application path. The retained lease
        # prevents a cooperating mutation owner moving the code after this read.
        path = Path(entry["manifest"]["root"]) / READER_ENTRIES[reader_kind]
        data = read_bytes(path)
        require(hashlib.sha256(data).hexdigest() == lease["executable_digest"], "application manifest digest mismatch")
        lease["state"] = "reading"
        lease["reader_kind"] = reader_kind
        save_population(location, record)
        return data


def require_no_application_readers(base, name):
    """Mutation-owner predicate; caller MUST hold admission through its effect.

    Not a maintained fence, drain algorithm, or standalone check-then-mutate
    API. Stage 3b supplies those owners. Pending/crashed reservations also block.
    There is deliberately no automatic release or timeout in this slice.
    """
    record = population(instance(base, name))
    require(not record["payload"]["leases"], "application registration prevents movement")


def inspect_request(base, name, data):
    """Installed parser/admission diagnostic; no ordinary application dispatch.

    A parsed capability is NOT an execution permit. All application/action
    verbs stay unreachable until their concrete guarded owner is implemented.
    The installed ingress never executes application code in this slice.
    """
    request = typed_request(data)
    with admission(base, name) as (entry, gate):
        capability = request_authority(entry, gate, request, {role: entry["manifest"][role] for role in ("root", "home")})
        require(capability in {"observe", "verify"}, "application/action owner not enabled")
        return {"binding": request["binding"], "generation": request["generation"], "request_id": request["request_id"],
                "request_digest": request["request_digest"], "outcome": "not-executed"}


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
    if len(sys.argv) != 2 or sys.argv[1] not in ("diagnose", "resume", "inspect-request"):
        fail("only installed diagnosis/enrollment resume/request inspection supported")
    for role, directory in (("parent", Path(BASE).parent), ("base", Path(BASE))):
        info = directory.lstat()
        mode = stat.S_IMODE(info.st_mode)
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or mode != 0o700:
            fail(f"authority {role} directory {directory}: actual mode {mode:04o}; owned mode 0700 required")
    location = Path(BASE) / "instances" / NAME
    claims = record(Path(BASE) / "claims.json", "claims")["payload"]
    entry = claims["entries"][NAME]
    frozen = entry["manifest"]
    if entry["digest"] != hashed(frozen) or frozen["name"] != NAME or entry["state"] not in ("reserved", "enrolled", "active"):
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
    if sys.argv[1] == "inspect-request":
        result = namespace["inspect_request"](Path(BASE), NAME, sys.stdin.buffer.read(65537))
    else:
        result = namespace[sys.argv[1]](Path(BASE), NAME)
    print(json.dumps(result, sort_keys=True))
except (ValueError, OSError, KeyError, TypeError) as exc:
    print("enrollment unknown/refused: " + str(exc), file=sys.stderr)
    sys.exit(126)
'''
