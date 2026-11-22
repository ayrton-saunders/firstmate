"""Implementation behind fm-inbox.sh. No shell, model, renderer or extractor."""
from contextlib import ExitStack, contextmanager, suppress
import errno
import fcntl
import os
from pathlib import Path
import re
import secrets
import struct
import subprocess
import sys
import time
import zipfile

BIN = Path(__file__).resolve().parent
sys.path.insert(0, str(BIN))  # -I: only trusted siblings
from fm_jarvis_store import SAFE, atomic, clear_stage, create, directory, discard, read, regular, remove, safe, stage
from fm_jarvis_wire import FILE, K, M, MANIFEST, Reader, Refusal, digest, envelope, json_bytes, parse, require, text

ID = r'[0-9a-f]{32}'
SHA = r'[0-9a-f]{64}'
SLUG = r'[a-z][a-z0-9-]{0,47}'
DAY = 86400
PRIVATE = dict(private=True, create=True)
REPORT_VERBS = ('bridge-lookup', 'jarvis-publish', 'jarvis-withdraw')


def receipt(req):
    return 'jarvis-' + digest(('jarvis-v1:' + req).encode())[:32]


def result(outcome, **fields):
    return dict(v=1, result=outcome, **fields)


def headers(fd, name):
    return dict(line.split('=', 1) for line in read(fd, name, 1024, header=True).decode().split('\n') if '=' in line)


class Bridge:
    def __init__(self, stack, inbox, verb):
        d = lambda parent, name, **kw: stack.enter_context(directory(parent, name, **kw))
        state = d(None, str(Path(inbox).parent), create=True)
        self.inbox = d(state, 'inbox', create=True)
        self.control = d(self.inbox, '.jarvis', **PRIVATE)
        # Directory flock is released by the kernel on crash; pass the open
        # description to publishing children so orphan completion stays serialized.
        self.lock = self.control
        if verb in REPORT_VERBS:
            return
        self.spool = d(self.inbox, '.attachments', **PRIVATE)
        self.requests = d(self.inbox, '.requests', create=True)
        self.handled = d(self.inbox, 'handled', create=True)
        self.replies = d(self.inbox, '.replies', create=True)
        self.markers = d(self.inbox, '.announced', create=True)

    @contextmanager
    def locked(self):
        fcntl.flock(self.lock, fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(self.lock, fcntl.LOCK_UN)

    def audit(self, verb, outcome, count, elapsed):
        data = json_bytes(dict(at=int(time.time()), principal='jarvis' if verb.startswith('bridge-') else 'parent',
                               verb=verb, result=outcome, correlation=secrets.token_hex(6), bytes=count,
                               duration_ms=round(elapsed*1000))) + b'\n'
        with self.locked():
            name = 'audit.jsonl'
            s = regular(self.control, name)
            if s and s.st_size >= M:
                os.rename(name, name+'.1', src_dir_fd=self.control, dst_dir_fd=self.control)
            with os.fdopen(os.open(name, SAFE | os.O_CREAT | os.O_WRONLY | os.O_APPEND, 0o600, dir_fd=self.control), 'ab') as f:
                safe(os.fstat(f.fileno()))
                f.write(data)

    def child(self, *args, body=b'', codes=(0,), **env):
        p = subprocess.run([str(BIN/'fm-inbox.sh'), *args], input=body, stdout=subprocess.PIPE,
                           stderr=subprocess.DEVNULL, env=dict(os.environ, FM_JARVIS_INTERNAL='1', **env),
                           pass_fds=(self.lock,))
        require(p.returncode in codes, 'server-error')
        return parse(p.stdout)

    def binding(self, req):
        key = 'jarvis-v1:' + req
        if not regular(self.requests, key):
            return None
        fields = read(self.requests, key, 512).decode().splitlines()
        require(len(fields) == 5 and fields[:3] == [receipt(req), 'jarvis', req]
                and all(re.fullmatch(SHA, h) for h in fields[3:]), 'denied')
        return fields[3:]

    def note(self, req, payload):
        note = receipt(req)
        for folder in (self.inbox, self.handled):
            try:
                h = headers(folder, note+'.note')
            except FileNotFoundError:
                continue
            require(h.get('id') == note and h.get('origin') == 'jarvis' and h.get('payload_sha256') == payload
                    and h.get('request_id') == 'jarvis-v1:'+req, 'denied')
            return True
        return False

    def terminal(self, note, release):
        # rename into handled updates ctime, not the note creation mtime.
        r = regular(self.replies, note) if release else None
        h = regular(self.handled, note+'.note')
        return min([t for t in (r.st_mtime if r else None, h.st_ctime if h else None) if t is not None], default=None)

    def expire_slots(self, folder, files, terminal):
        now = time.time()
        for f in files:
            slot = f['slot']
            require(re.fullmatch(ID, slot), 'denied')
            delivered = regular(folder, slot+'.delivered')
            deadline = delivered.st_mtime + 7*DAY if delivered else terminal + 30*DAY if terminal else None
            expired = regular(folder, slot+'.expired')
            if not expired and deadline and now >= deadline:
                create(folder, slot+'.expired', b'')
                expired = True
            if expired:
                if regular(folder, slot):
                    os.fsync(folder)
                    remove(folder, slot)
                f['expired'] = True

    def manifest(self, fd, req, direction, expected):
        raw = read(fd, 'manifest.json', MANIFEST + 4096)
        require(digest(raw) == expected, 'denied')
        m = parse(raw)
        require((m.get('audience'), m.get('receipt'), m.get('request'), m.get('direction')) ==
                ('jarvis', receipt(req), req, direction), 'denied')
        return m

    def sweep(self):
        for folder in (self.inbox, self.replies, self.requests):
            remove(folder, '.jarvis-writing')
        used = 0
        for note in os.listdir(self.spool):
            require(re.fullmatch('jarvis-'+ID, note), 'denied')
            with directory(self.spool, note, private=True) as side:
                dirs = set(os.listdir(side))
                require(dirs <= {'request', 'reply', '.stage'}, 'denied')
                if '.stage' in dirs:
                    clear_stage(side)
                if 'request' in dirs:
                    with directory(side, 'request', private=True) as fd:
                        req = parse(read(fd, 'manifest.json', MANIFEST + 4096))['request']
                        require(re.fullmatch(ID, req) and receipt(req) == note, 'denied')
                        binding = self.binding(req)
                    if not binding:  # interrupted before reservation commit
                        discard(side, 'request')
                    else:
                        release = self.released_hash(note)
                        terminal = self.terminal(note, release)
                        for direction in dirs & {'request', 'reply'}:
                            expected = binding[1] if direction == 'request' else release
                            if not expected:  # no final reply committed this staged manifest
                                discard(side, direction)
                                continue
                            with directory(side, direction, private=True) as fd:
                                m = self.manifest(fd, req, direction, expected)
                                self.expire_slots(fd, m['files'], terminal)
                                for f in m['files']:
                                    s = regular(fd, f['slot'])
                                    if s:
                                        used += s.st_size
                if not os.listdir(side):
                    os.rmdir(note, dir_fd=self.spool)
        return used

    def released_hash(self, note):
        if regular(self.replies, note):
            release = headers(self.replies, note).get('jarvis_release')
            if release:
                os.fsync(self.replies)
                return release
        return None

    def save(self, req, packet, reply):
        body, files, blobs, payload = packet
        note = receipt(req)
        key = 'jarvis-v1:' + req
        direction = 'reply' if reply else 'request'
        used = self.sweep()
        binding = self.binding(req)
        marker = regular(self.markers, note)
        if binding:
            with directory(self.spool, note, private=True) as side, directory(side, 'request', private=True) as fd:
                self.manifest(fd, req, 'request', binding[1])
            exists = self.note(req, binding[0])
            if reply:
                require(exists and not regular(self.handled, note+'.note') and not regular(self.replies, note), 'conflict')
            else:
                require(binding[0] == payload, 'conflict')
        else:
            require(not reply, 'unknown')
            require(not marker and not regular(self.inbox, note+'.note') and not regular(self.handled, note+'.note')
                    and not regular(self.replies, note), 'denied')
        if reply or not binding:
            require(not blobs or used + sum(map(len, blobs)) <= 256*M, 'overload')
            with directory(self.spool, note, **PRIVATE) as side:
                meta = dict(audience='jarvis', request=req, receipt=note, direction=direction)
                if reply:
                    meta.update(text_bytes=len(body.encode()), text_sha256=digest(body.encode()))
                mh = stage(side, direction, files, blobs, meta)
                try:
                    if reply:
                        regular(self.replies, '.seq')
                        self.child('reply', '--json', note, '-', body=body.encode(), FM_JARVIS_RELEASE=mh)
                        return result('answered', receipt=note)
                    atomic(self.requests, key, f'{note}\njarvis\n{req}\n{payload}\n{mh}\n'.encode())
                except Exception:
                    # Do not discard a commit that succeeded but lost its
                    # response. An interrupted process leaves this to sweep.
                    committed = self.released_hash(note) == mh if reply else self.binding(req)
                    if not committed:
                        discard(side, direction)
                    raise
        # The standard note publisher completes this reservation, including
        # after a crash. Neither body nor display names become authority.
        self.child('note', '--request-id', key, '--json', '-', body=body.encode(),
                   FM_JARVIS_DIGEST=payload, codes=(0, 3))
        return self.snapshot(req, None, False)[0]

    def snapshot(self, req, selector, wait):
        note = receipt(req)
        b = self.binding(req)
        require(b, 'unknown')
        out = dict(receipt=note, observed=int(time.time()))
        if not self.note(req, b[0]):
            return result('saved-not-announced', **out), None
        observed = self.child('wait', note, '--timeout', '0', '--json', codes=(0, 2, 3, 4))
        release = self.released_hash(note) if observed['outcome'] == 'answered' else None
        if release:
            with directory(self.spool, note, private=True) as side, directory(side, 'reply', private=True) as fd:
                m = self.manifest(fd, req, 'reply', release)
                if wait:
                    self.expire_slots(fd, m['files'], self.terminal(note, release))
                    if selector:
                        f = next((f for f in m['files'] if f['slot'] == selector), None)
                        require(f, 'not-available')
                        require(not f.get('expired'), 'expired')
                        blob = read(fd, selector, FILE)
                        require(len(blob) == f['length'] and digest(blob) == f['sha256'], 'denied')
                        return result('attachment', **out, **f), blob
                    # Only the explicit final commit releases the single inbox reply body.
                    raw = read(self.replies, note, 16*K + 1024)
                    body = raw.split(b'\n--\n', 1)[1][:m['text_bytes']].decode()
                    require(digest(body.encode()) == m['text_sha256'], 'denied')
                    out.update(text=body, files=m['files'])
            return result('answered', **out), None
        require(not selector, 'not-available')
        if observed['acknowledged']:
            state = 'handled-no-answer'
        elif not regular(self.markers, note):
            state = 'saved-not-announced'
        else:
            state = 'pending' if wait else 'announced'
        return result(state, **out), None

    def delivered(self, note, slot):
        with self.locked(), directory(self.spool, note, private=True) as side, directory(side, 'reply', private=True) as fd:
            if regular(fd, slot) and not regular(fd, slot+'.expired') and not regular(fd, slot+'.delivered'):
                create(fd, slot+'.delivered', b'')
                os.fsync(fd)

    def report(self, verb, slug, data, expiry):
        name = digest(('jarvis:'+slug).encode())
        with directory(self.control, 'releases', **PRIVATE) as fd:
            if verb == 'jarvis-publish':
                record = dict(audience='jarvis', slug=slug, version=secrets.token_hex(16),
                              as_of=int(time.time()), expires=expiry, text=text(data.decode(), 64*K))
                atomic(fd, name, json_bytes(record))
                return result('published', version=record['version'])
            if verb == 'jarvis-withdraw':
                remove(fd, name)
                os.fsync(fd)
                return result('withdrawn')
            if regular(fd, name):
                r = parse(read(fd, name, 6*64*K + 512))
                if r.get('audience') == 'jarvis' and r.get('slug') == slug and (not r['expires'] or r['expires'] > time.time()):
                    return result('available', **{k: r[k] for k in ('version', 'as_of', 'expires', 'text')})
            return result('not-available')

    def dispatch(self, verb, args, reader):
        if verb == 'jarvis-expire':
            require(not args)
            reader.bounded(0)
            with self.locked():
                self.sweep()
            return result('cleaned'), None
        if verb in REPORT_VERBS:
            require(len(args) in ((1, 2) if verb == 'jarvis-publish' else (1,)) and re.fullmatch(SLUG, args[0]))
            expiry = None
            if len(args) == 2:
                require(re.fullmatch('[1-9][0-9]{0,11}', args[1]))
                expiry = int(args[1])
            data = reader.bounded(64*K if verb == 'jarvis-publish' else 0)
            with self.locked():
                return self.report(verb, args[0], data, expiry), None
        require(len(args) == 1 and re.fullmatch(ID, args[0]))
        req = args[0]
        if verb in ('bridge-submit', 'jarvis-release'):
            packet = envelope(reader)
            with self.locked():
                return self.save(req, packet, verb == 'jarvis-release'), None
        wait = verb == 'bridge-wait'
        data = reader.bounded(128 if wait else 0)
        selector = None
        if data:
            s = parse(data)
            require(set(s) == {'attachment'} and type(s['attachment']) is str and re.fullmatch(ID, s['attachment']))
            selector = s['attachment']
        with self.locked():
            answer = self.snapshot(req, selector, wait)
        if wait and not selector and answer[0]['result'] == 'pending':
            # No spool lock across the long poll: parent can publish a final.
            self.child('wait', receipt(req), '--timeout', '20', '--json', codes=(0, 2, 3, 4))
            with self.locked():
                answer = self.snapshot(req, selector, wait)
        return answer


def main():
    inbox, verb, *args = sys.argv[1:]
    reader = Reader()
    started = time.monotonic()
    blob = None
    with ExitStack() as stack:
        bridge = None
        try:
            bridge = Bridge(stack, inbox, verb)
            answer, blob = bridge.dispatch(verb, args, reader)
        except Refusal as e:
            answer = result(str(e))
        except (UnicodeError, zipfile.BadZipFile, struct.error):
            answer = result('invalid')
        except OSError as e:
            answer = result('overload' if e.errno in (errno.ENOSPC, errno.EDQUOT) else 'server-error')
        except Exception:
            answer = result('server-error')
        if bridge is not None:
            with suppress(OSError, Refusal):
                bridge.audit(verb, answer['result'], reader.count + len(blob or b''), time.monotonic()-started)
        try:
            sys.stdout.buffer.write(json_bytes(answer) + b'\n')
            if blob is not None:
                sys.stdout.buffer.write(struct.pack('>I', len(blob)) + blob)
            sys.stdout.buffer.flush()
        except OSError:
            os._exit(1)
        if blob is not None:
            try:
                bridge.delivered(answer['receipt'], answer['slot'])
            except (OSError, Refusal):
                sys.exit(1)


if __name__ == '__main__':
    try:
        main()
    except Exception:
        print('{"v":1,"result":"server-error"}')
