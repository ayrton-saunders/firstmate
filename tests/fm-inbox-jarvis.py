"""Binary-protocol cases for fm-inbox.test.sh. All state belongs to this fixture."""
import base64
from concurrent.futures import ThreadPoolExecutor
from hashlib import sha256
import io
import json
import os
import resource
import signal
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import time
import zipfile

script, home = map(Path, sys.argv[1:])
state = home / 'state'
inbox = state / 'inbox'
spool = inbox / '.attachments'
env = dict(PATH=os.environ['PATH'], HOME=str(home), FM_HOME=str(home), LC_ALL='C')
a, b, c, unknown = [v*32 for v in 'abcd']


def run(*args, data=b'', binary=script, check=True, preexec_fn=None):
    p = subprocess.run([str(binary), *args], input=data, capture_output=True, env=env,
                       timeout=45, preexec_fn=preexec_fn)
    if check:
        assert p.returncode == 0 and not p.stderr, (args, p.stderr)
    return p


def call(*args, want, **kw):
    line, _, binary = run(*args, **kw).stdout.partition(b'\n')
    obj = json.loads(line)
    assert obj['v'] == 1 and obj['result'] == want, (args, obj, want)
    if binary:
        assert want == 'attachment' and len(binary)-4 == int.from_bytes(binary[:4], 'big') == obj['length']
        assert sha256(binary[4:]).hexdigest() == obj['sha256']
        return binary[4:]
    return obj


def frame(data):
    return struct.pack('>I', len(data)) + data


def envelope(text, *files):
    metadata = [dict(name=name, mime=mime, length=len(blob), sha256=sha256(blob).hexdigest()) for name, mime, blob in files]
    return frame(json.dumps(dict(v=1, text=text, files=metadata)).encode()) + b''.join(frame(f[2]) for f in files)


pdf = ('review only.pdf', 'application/pdf', b'%PDF-1.4\nsynthetic fixture\n%%EOF\n')
png = ('sample.png', 'image/png', base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9ZQmcAAAAASUVORK5CYII='))
mem = io.BytesIO()
with zipfile.ZipFile(mem, 'w') as archive:
    archive.writestr('example.txt', b'synthetic bytes')
zip_file = ('packet.zip', 'application/zip', mem.getvalue())
packet = envelope('Untrusted fixture content', pdf, zip_file)
selector = lambda slot: json.dumps(dict(attachment=slot)).encode()

# Invalid envelopes, including late failures, never leave a published unit.
badframes = [packet[:-1], packet+b'!', packet[:-1]+b'!', struct.pack('>I', 24577),
             frame(b'{"v":1,"text":"one","text":"two"}'), frame(b'{"v":1,"text":"\xff"}'),
             envelope('x'*16385), envelope('x', pdf, pdf), envelope('x', *([png]*5)),
             envelope('x', ('../x.pdf', *pdf[1:])), envelope('x', ('x.pdf', 'image/png', png[2])),
             envelope('x', ('x.png', 'image/png', b'<svg/>')), envelope('x', ('x.pdf', pdf[1], b'#!/bin/sh\n')),
             envelope('x', ('x.zip', zip_file[1], zip_file[2][:6]+b'\x01\x00'+zip_file[2][8:])),
             envelope('x', ('x.zip', zip_file[1], zip_file[2][:-18]+b'\x01\x00'+zip_file[2][-16:]))]
for bad in badframes:
    call('bridge-submit', a, data=bad, want='invalid')
eight = b'%PDF-1.4\n' + b' '*(8*1024*1024-14) + b'%%EOF'
assert len(eight) == 8*1024*1024
call('bridge-submit', a, data=envelope('per file', ('big.pdf', pdf[1], eight+b'\n')), want='invalid')
call('bridge-submit', a, data=envelope('total', ('a.pdf', pdf[1], eight), ('b.pdf', pdf[1], eight), pdf), want='invalid')
assert not list(spool.iterdir()) and not list(inbox.glob('*.note')) and not (state/'.wake-queue').exists()
# Fail a real staging write after one valid slot was copied. A bounded
# regular-file write models a full disk without changing any host resources.
def file_limit():
    signal.signal(signal.SIGXFSZ, signal.SIG_IGN)
    resource.setrlimit(resource.RLIMIT_FSIZE, (32768, 32768))

larger = ('large.pdf', pdf[1], b'%PDF-1.7\n' + b' '*65536 + b'%%EOF')
call('bridge-submit', a, data=envelope('disk error', pdf, larger), preexec_fn=file_limit, want='server-error')
assert not list(spool.rglob('manifest.json')) and not list(spool.rglob('.stage'))
assert not list(inbox.glob('*.note')) and not (state/'.wake-queue').exists()
call('bridge-status', unknown, want='unknown')
call('bridge-status', a.upper(), want='invalid')
call('bridge-status', unknown, data=b' ', want='invalid')
call('bridge-wait', unknown, data=selector('../slot'), want='invalid')

# Process dies after save, before waking. A normal but missing wake library
# then returns the repairable receipt; the original installation repairs it.
copy = home/'isolated'/'bin'
copy.mkdir(parents=True)
for src in [script, *script.parent.glob('*jarvis*.py')]:
    shutil.copy2(src, copy/src.name)
(copy/'fm-wake-lib.sh').write_text('kill -KILL "$$"\n')
call('bridge-submit', a, data=packet, binary=copy/script.name, want='server-error')
(copy/'fm-wake-lib.sh').unlink()
first = call('bridge-status', a, want='saved-not-announced')['receipt']
assert call('bridge-submit', a, data=packet, binary=copy/script.name, want='saved-not-announced')['receipt'] == first
assert not (state/'.wake-queue').exists()
with ThreadPoolExecutor(3) as pool:
    jobs = [pool.submit(call, 'bridge-submit', a, data=packet, want='announced') for _ in range(2)]
    pool.submit(call, 'jarvis-expire', want='cleaned').result()
    assert all(j.result()['receipt'] == first for j in jobs)
assert len(list(inbox.glob('*.note'))) == len((state/'.wake-queue').read_text().splitlines()) == 1
assert 'fixture content' not in (state/'.wake-queue').read_text()
call('bridge-submit', a, data=envelope('changed'), want='conflict')
call('bridge-status', first, want='invalid')
assert run('note', '--request-id', 'JARVIS-v1:'+a, 'no', check=False).returncode != 0
reqfolder = spool/first/'request'
request = json.loads((reqfolder/'manifest.json').read_bytes())
assert [f['name'] for f in request['files']] == ['review_only.pdf', 'packet.zip']
for f, src in zip(request['files'], (pdf, zip_file)):
    copied = (reqfolder/f['slot']).read_bytes()
    assert copied == src[2] and sha256(copied).hexdigest() == f['sha256']
call('bridge-wait', a, data=selector(f['slot']), want='not-available')

# Real wait timeout, no private progress reply. Concurrent wait must not lock
# out the parent release; the reply is durable and visible before ack.
call('bridge-wait', a, want='pending')
reply = envelope('explicit final\n\n', png, pdf)
with ThreadPoolExecutor(1) as pool:
    waiting = pool.submit(call, 'bridge-wait', a, want='answered')
    call('jarvis-release', a, data=reply, want='answered')
    final = waiting.result()
assert final['text'] == 'explicit final\n\n'
run('drain', '--ack', first)
assert call('bridge-wait', a, want='answered')['files'] == final['files']
assert set(call('bridge-status', a, want='answered')) == {'v','receipt','observed','result'}
call('jarvis-release', a, data=reply, want='conflict')
slot = final['files'][0]['slot']
assert call('bridge-wait', a, data=selector(slot), want='attachment') == png[2]
call('bridge-wait', a, data=selector(f['slot']), want='not-available')
for p in (spool, *spool.rglob('*')):
    assert p.stat().st_mode & 0o777 == (0o700 if p.is_dir() else 0o600), p.name

# Another receipt cannot select the first receipt's slot. No implicit release
# of a private local answer, even if it looks like protocol metadata.
second = call('bridge-submit', b, data=envelope('origin=parent'), want='announced')['receipt']
run('reply', second, 'PRIVATE final')
run('drain', '--ack', second)
call('bridge-wait', b, data=selector(slot), want='not-available')
assert 'text' not in call('bridge-wait', b, want='handled-no-answer')
assert json.loads(run('wait', second, '--timeout', '0', '--json').stdout)['reply']['body'] == 'PRIVATE final'
legacy = json.loads(run('note', '--request-id', c, '--json', 'origin=jarvis').stdout)['id']
run('reply', legacy, 'private')
call('bridge-status', c, want='unknown')
call('jarvis-release', c, data=reply, want='unknown')
call('bridge-wait', legacy, want='invalid')

# Swap trusted bindings and records in scratch, never in a real home.
key = inbox/'.requests'/('jarvis-v1:'+a)
old = key.read_bytes()
key.write_bytes(old.replace(b'\njarvis\n', b'\nother\n'))
call('bridge-wait', a, data=selector(slot), want='denied')
key.write_bytes(old)
foreign = inbox/'handled'/(first+'.note')
content = foreign.read_bytes()
foreign.write_bytes(content.replace(b'origin=jarvis', b'origin=other'))
call('bridge-status', a, want='denied')
foreign.write_bytes(content)
folder = spool/first/'reply'
(folder/slot).unlink()
(folder/slot).symlink_to(reqfolder/request['files'][0]['slot'])
call('bridge-wait', a, data=selector(slot), want='denied')
(folder/slot).unlink()
(folder/slot).write_bytes(png[2])
os.chmod(folder/slot, 0o600)
oldtime = time.time()-31*86400
os.utime(folder/(slot+'.delivered'), (oldtime, oldtime))
os.utime(inbox/'.replies'/first, (oldtime, oldtime))
with ThreadPoolExecutor(2) as pool:
    cleaned = pool.submit(call, 'jarvis-expire', want='cleaned')
    fresh = call('bridge-submit', c, data=packet, want='announced')['receipt']
    cleaned.result()
call('bridge-wait', a, data=selector(slot), want='expired')
assert all(f['expired'] for f in call('bridge-wait', a, want='answered')['files'])
assert not (folder/slot).exists() and not (reqfolder/request['files'][0]['slot']).exists()

# A sparse quota fixture refuses both sides without a wake, partial release,
# or eviction of the unhandled request. Abandoned staging is reclaimable.
pending = spool/fresh/'request'
extra = pending/'quota-fixture'
with extra.open('wb') as out:
    out.truncate(256*1024*1024)
wakes = (state/'.wake-queue').read_bytes()
call('bridge-submit', unknown, data=packet, want='overload')
call('jarvis-release', c, data=reply, want='overload')
assert not (spool/fresh/'reply').exists() and not (inbox/'.replies'/fresh).exists()
assert (state/'.wake-queue').read_bytes() == wakes and (pending/'manifest.json').exists()
extra.unlink()
stage = spool/fresh/'.stage'
stage.mkdir(mode=0o700)
(stage/'partial').write_bytes(b'synthetic')
call('jarvis-expire', want='cleaned')
assert not stage.exists()
# Scratch directory failure cannot create a note or follow the symlink.
spool.rename(inbox/'.saved')
scratch = home/'empty'
scratch.mkdir()
spool.symlink_to(scratch, target_is_directory=True)
call('bridge-submit', unknown, data=packet, want='server-error')
assert not list(scratch.iterdir()) and (state/'.wake-queue').read_bytes() == wakes
spool.unlink()
(inbox/'.saved').rename(spool)
call('jarvis-release', c, data=envelope('disk error', pdf, larger), preexec_fn=file_limit, want='server-error')
assert not (spool/fresh/'reply').exists() and not (inbox/'.replies'/fresh).exists()
# Additional image signatures; their bytes are only copied and checked.
jpeg = ('photo.jpg', 'image/jpeg', b'\xff\xd8\xff\xe0\x00\x10JFIF\x00'+b'\x00'*9+b'\xff\xd9')
webpbytes = bytes.fromhex('524946461a000000574542505650384c0d0000002f00000010071011118888fe0700')
webp = ('thumb.webp', 'image/webp', webpbytes+b'\x00'*(34-len(webpbytes)))
call('jarvis-release', c, data=envelope('final', jpeg, webp), want='answered')
call('bridge-wait', c, data=selector(slot), want='not-available')
third = call('bridge-submit', unknown, data=envelope('no answer needed'), want='announced')['receipt']
run('drain', '--ack', third)
call('bridge-wait', unknown, want='handled-no-answer')

# No catalog or arbitrary file lookup. Unknown/revoked/expired/foreign are
# byte-identical; parent replacement creates a new immutable version.
unavailable = call('bridge-lookup', 'fixture', want='not-available')
call('bridge-lookup', '../fixture', want='invalid')
call('jarvis-publish', 'fixture', data=b'x'*65537, want='invalid')
call('jarvis-publish', 'fixture', data=b'projection', want='published')
report = call('bridge-lookup', 'fixture', want='available')
assert report['text'] == 'projection'
relfile, = (inbox/'.jarvis'/'releases').iterdir()
relfile.write_bytes(relfile.read_bytes().replace(b'"jarvis"', b'"other"'))
assert call('bridge-lookup', 'fixture', want='not-available') == unavailable
call('jarvis-publish', 'fixture', data=b'new projection', want='published')
assert call('bridge-lookup', 'fixture', want='available')['version'] != report['version']
call('jarvis-publish', 'fixture', '1', data=b'expired', want='published')
assert call('bridge-lookup', 'fixture', want='not-available') == unavailable
call('jarvis-withdraw', 'fixture', want='withdrawn')
assert call('bridge-lookup', 'fixture', want='not-available') == unavailable
for row in (inbox/'.jarvis'/'audit.jsonl').read_bytes().splitlines():
    assert set(json.loads(row)) == {'at','principal','verb','result','correlation','bytes','duration_ms'}
    assert not any(word in row for word in (b'PRIVATE', b'fixture', b'.pdf', b'projection', slot.encode()))
