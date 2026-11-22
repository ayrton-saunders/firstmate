"""Private descriptor-relative inbox storage. Caller serializes mutations."""
from contextlib import contextmanager, suppress
import fcntl
import os
from pathlib import Path
import secrets
import stat
import sys
import time

if __name__ == '__main__':
    sys.path.insert(0, str(Path(__file__).resolve().parent))
from fm_jarvis_wire import require

DIR = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
SAFE = os.O_NOFOLLOW | os.O_NONBLOCK
NEW = os.O_WRONLY | os.O_CREAT | os.O_EXCL | SAFE


@contextmanager
def directory(parent, name, create=False, private=False):
    if create:
        with suppress(FileExistsError):
            os.mkdir(name, 0o700, dir_fd=parent)
    fd = os.open(name, DIR, dir_fd=parent)
    try:
        info = os.fstat(fd)
        require(info.st_uid == os.geteuid() and not info.st_mode & (0o077 if private else 0o022), 'denied')
        if create:
            if parent is None:
                sync_path(Path(name).parent)
            else:
                os.fsync(parent)
        yield fd
    finally:
        os.close(fd)


def regular(fd, name):
    try:
        s = os.stat(name, dir_fd=fd, follow_symlinks=False)
    except FileNotFoundError:
        return None
    safe(s)
    return s


def safe(s):
    require(stat.S_ISREG(s.st_mode) and s.st_nlink == 1 and s.st_uid == os.geteuid(), 'denied')


def read(fd, name, limit, header=False):
    # Reject devices before even opening them; re-check the opened object.
    if not regular(fd, name):
        raise FileNotFoundError
    with os.fdopen(os.open(name, os.O_RDONLY | SAFE, dir_fd=fd), 'rb') as f:
        safe(os.fstat(f.fileno()))
        data = f.read(limit+1)
        if header:
            data, sep, _ = data.partition(b'\n--\n')
            require(sep, 'denied')
        require(len(data) <= limit, 'denied')
        return data


def create(fd, name, data):
    with os.fdopen(os.open(name, NEW, 0o600, dir_fd=fd), 'wb') as f:
        f.write(data)
        f.flush()
        os.fsync(f.fileno())


def atomic(fd, name, data):
    # One known staging name per locked directory, also recoverable after SIGKILL.
    stage = '.jarvis-writing'
    remove(fd, stage)
    try:
        create(fd, stage, data)
        os.rename(stage, name, src_dir_fd=fd, dst_dir_fd=fd)
        os.fsync(fd)
    finally:
        remove(fd, stage)


def remove(fd, name):
    with suppress(FileNotFoundError):
        os.unlink(name, dir_fd=fd)


def clear_dir(fd, name):
    with directory(fd, name, private=True) as child:
        for leaf in os.listdir(child):
            remove(child, leaf)
    os.rmdir(name, dir_fd=fd)


def stage(side, direction, files, blobs, metadata):
    from fm_jarvis_wire import digest, json_bytes
    os.mkdir('.stage', 0o700, dir_fd=side)
    try:
        with directory(side, '.stage', private=True) as tmp:
            for f, blob in zip(files, blobs):
                f['slot'] = secrets.token_hex(16)
                create(tmp, f['slot'], blob)
            manifest = json_bytes(dict(metadata, files=files))
            create(tmp, 'manifest.json', manifest)
            os.fsync(tmp)
        os.rename('.stage', direction, src_dir_fd=side, dst_dir_fd=side)
    except Exception:
        clear_dir(side, '.stage')
        raise
    os.fsync(side)
    return digest(manifest)


def sync_path(path):
    fd = os.open(path, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def main():
    op, *args = sys.argv[1:]
    if op == 'commit':
        source, target = map(Path, args)
        sync_path(source)
        os.replace(source, target)
        sync_path(target.parent)
    elif op == 'sync':
        for name in args:
            path = Path(name)
            sync_path(path)
            sync_path(path.parent)
    elif op == 'mark':
        inbox, *ids = args
        with directory(None, inbox) as fd, directory(fd, '.announced', create=True) as marks:
            for note in ids:
                if not regular(marks, note):
                    atomic(marks, note, time.strftime('%Y-%m-%dT%H:%M:%SZ\n', time.gmtime()).encode())
            os.fsync(marks)
    elif op == 'ack':
        inbox, note = args
        with directory(None, inbox) as fd, directory(fd, '.jarvis', create=True, private=True) as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            with directory(fd, 'handled', create=True) as handled:
                name = note+'.note'
                if regular(fd, name):
                    if (Path(inbox)/'.replies'/note).is_file():
                        sync_path(Path(inbox)/'.replies')
                    os.rename(name, name, src_dir_fd=fd, dst_dir_fd=handled)
                    os.fsync(handled)
                    os.fsync(fd)
                    print('acked', note)
                else:
                    print('already-acked', note)


if __name__ == '__main__':
    main()
