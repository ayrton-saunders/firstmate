"""Binary-protocol cases for fm-inbox.test.sh. All state belongs to this fixture."""
import base64
from concurrent.futures import ThreadPoolExecutor
from hashlib import sha256
import io
import json
import os
import re
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


def pdf_document(padding=0):
    doc = b'%PDF-1.4\n%' + b' '*padding + b'\n'
    offsets = [b'0000000000 65535 f \n']
    for i, body in enumerate((b'<< /Type /Catalog /Pages 2 0 R >>', b'<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
                              b'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 1 1] >>'), 1):
        offsets.append(f'{len(doc):010d} 00000 n \n'.encode())
        doc += f'{i} 0 obj\n'.encode() + body + b'\nendobj\n'
    return (doc + b'xref\n0 4\n' + b''.join(offsets) + b'trailer\n<< /Size 4 /Root 1 0 R >>\n'
            + f'startxref\n{len(doc)}\n%%EOF\n'.encode())


pdf = ('review only.pdf', 'application/pdf', pdf_document())
png = ('sample.png', 'image/png', base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII='))
webp = ('thumb.webp', 'image/webp', bytes.fromhex('524946461a000000574542505650384c0d0000002f00000010071011118888fe0700'))
huffman = b'\x01' + b'\x00'*16
jpeg = ('photo.jpg', 'image/jpeg', b'\xff\xd8\xff\xdb\x00\x43\x00' + b'\x01'*64
        + b'\xff\xc0\x00\x0b\x08\x00\x01\x00\x01\x01\x01\x11\x00'
        + b'\xff\xc4\x00\x26\x00' + huffman + b'\x10' + huffman
        + b'\xff\xda\x00\x08\x01\x01\x00\x00\x3f\x00\x3f\xff\xd9')
mem = io.BytesIO()
with zipfile.ZipFile(mem, 'w') as archive:
    archive.writestr('example.txt', b'synthetic bytes')
zip_file = ('packet.zip', 'application/zip', mem.getvalue())
mem = io.BytesIO()
with zipfile.ZipFile(mem, 'w', compression=zipfile.ZIP_BZIP2) as archive:
    archive.writestr('example.txt', b'synthetic bytes')
bzip = ('compressed.zip', 'application/zip', mem.getvalue())
packet = envelope('Untrusted fixture content', pdf, zip_file)
selector = lambda slot: json.dumps(dict(attachment=slot)).encode()

# Invalid envelopes, including late failures, never leave a published unit.
badframes = [packet[:-1], packet+b'!', packet[:-1]+b'!', struct.pack('>I', 24577),
             frame(b'{"v":1,"text":"one","text":"two"}'), frame(b'{"v":1,"text":"\xff"}'),
             envelope('x'*16385), envelope('x', *([png]*5)),
             envelope('x', ('../x.pdf', *pdf[1:])), envelope('x', ('x.pdf', 'image/png', png[2])),
             envelope('x', ('x.png', 'image/png', b'<svg/>')), envelope('x', ('x.pdf', pdf[1], b'#!/bin/sh\n')),
             envelope('x', ('x.zip', zip_file[1], zip_file[2][:6]+b'\x01\x00'+zip_file[2][8:])),
             envelope('x', ('x.zip', zip_file[1], zip_file[2][:-18]+b'\x01\x00'+zip_file[2][-16:]))]
for filename, mime, blob in (
    (*png[:2], png[2][:29] + png[2][-12:]),
    (*jpeg[:2], jpeg[2][:20] + jpeg[2][-2:]),
    (*webp[:2], webp[2][:16] + b'\xff\x00\x00\x00' + webp[2][20:]),
    (*pdf[:2], pdf[2].split(b'xref\n', 1)[0] + b'%%EOF\n'),
    (*zip_file[:2], zip_file[2][:28] + b'\xff\x00' + zip_file[2][30:]),
):
    badframes.append(envelope('malformed container', (filename, mime, blob)))
for bad in badframes:
    call('bridge-submit', a, data=bad, want='invalid')
eight_size = 8*1024*1024
padding = eight_size-len(pdf[2])-6
while len(eight := pdf_document(padding)) != eight_size:
    padding += eight_size-len(eight)
assert len(eight) == 8*1024*1024
call('bridge-submit', a, data=envelope('per file', ('big.pdf', pdf[1], eight+b'\n')), want='invalid')
call('bridge-submit', a, data=envelope('total', ('a.pdf', pdf[1], eight), ('b.pdf', pdf[1], eight), pdf), want='invalid')
assert not list(spool.iterdir()) and not list(inbox.glob('*.note')) and not (state/'.wake-queue').exists()
# Fail a real staging write after one valid slot was copied. A bounded
# regular-file write models a full disk without changing any host resources.
def file_limit():
    signal.signal(signal.SIGXFSZ, signal.SIG_IGN)
    resource.setrlimit(resource.RLIMIT_FSIZE, (32768, 32768))

larger = ('large.pdf', pdf[1], pdf_document(65536))
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
(copy/'fm-wake-lib.sh').write_text(
    f'FM_WAKE_QUEUE="{state}/.wake-queue"\nFM_WAKE_QUEUE_LOCK="$FM_WAKE_QUEUE.lock"\n'
    'fm_lock_acquire_wait() { :; }\nfm_lock_release() { :; }\n'
    'fm_wake_append_locked() { printf "123\\t" >> "$FM_WAKE_QUEUE"; }\n'
)
call('bridge-submit', a, data=packet, binary=copy/script.name, want='saved-not-announced')
assert (state/'.wake-queue').read_bytes() == b'123\t'
with ThreadPoolExecutor(3) as pool:
    jobs = [pool.submit(call, 'bridge-submit', a, data=packet, want='announced') for _ in range(2)]
    pool.submit(call, 'jarvis-expire', want='cleaned').result()
    assert all(j.result()['receipt'] == first for j in jobs)
partial, repaired = (state/'.wake-queue').read_bytes().splitlines(keepends=True)
assert partial == b'123\t\n' and repaired.endswith(b'\n')
epoch, seq, kind, key, payload = repaired.split(b'\t')
assert epoch.isdigit() and seq.isdigit() and kind == b'check' and key == f'inbox:{first}'.encode()
assert b'fixture content' not in payload
assert len(list(inbox.glob('*.note'))) == 1

lost = 'e'*32
lost_packet = envelope('response discarded', pdf, pdf, bzip)
with open(os.devnull, 'wb') as sink:
    p = subprocess.run([str(script), 'bridge-submit', lost], input=lost_packet, stdout=sink,
                       stderr=subprocess.PIPE, env=env, timeout=45)
assert p.returncode == 0 and not p.stderr
lost_note = call('bridge-submit', lost, data=lost_packet, want='announced')['receipt']
assert len(list(inbox.glob('*.note'))) == 2
assert len((state/'.wake-queue').read_bytes().splitlines()) == 3
slots = json.loads((spool/lost_note/'request'/'manifest.json').read_bytes())['files']
assert [f['name'] for f in slots] == ['review_only.pdf', 'review_only.pdf', 'compressed.zip']
assert len({f['slot'] for f in slots}) == 3

(inbox/'.announced'/first).unlink()
drain = script.with_name('fm-wake-drain.sh')
p = run(binary=drain, check=False)
assert p.returncode == 0, p.stderr
ack = re.search(rb'--ack-through ([0-9]+) --recovery-generation ([A-Za-z0-9._-]+)', p.stderr)
assert ack, p.stderr
run('--ack-through', ack[1].decode(), '--recovery-generation', ack[2].decode(), binary=drain, check=False)
assert not (state/'.wake-queue').read_bytes()
assert (inbox/(first+'.note')).exists()
call('bridge-status', a, want='announced')
call('bridge-submit', a, data=packet, want='announced')
assert not (state/'.wake-queue').read_bytes()


def publisher_limit():
    signal.signal(signal.SIGXFSZ, signal.SIG_IGN)
    resource.setrlimit(resource.RLIMIT_FSIZE, (8192, 8192))


cut = '1'*32
long_packet = envelope('x'*12000 + '\n')
call('bridge-submit', cut, data=long_packet, preexec_fn=publisher_limit, want='server-error')
assert len(list(inbox.glob('*.note'))) == 2 and not (state/'.wake-queue').read_bytes()
assert call('bridge-status', cut, want='saved-not-announced')['receipt']
call('jarvis-release', lost, data=long_packet, preexec_fn=publisher_limit, want='server-error')
assert not (inbox/'.replies'/lost_note).exists() and not (spool/lost_note/'reply').exists()
for parent in (inbox, inbox/'.replies'):
    scratch = parent/'.jarvis-writing'
    if not scratch.exists():
        scratch.write_bytes(b'interrupted publisher')
call('jarvis-expire', want='cleaned')
assert not any(inbox.rglob('.jarvis-writing'))
cut_note = call('bridge-submit', cut, data=long_packet, want='announced')['receipt']
assert (inbox/(cut_note+'.note')).read_bytes().partition(b'\n--\n')[2] == b'x'*12000 + b'\n'
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
undelivered_slot = final['files'][1]['slot']
with subprocess.Popen([str(script), 'bridge-wait', a], env=env, stdin=subprocess.PIPE,
                      stdout=subprocess.PIPE, stderr=subprocess.PIPE) as p:
    p.stdout.close()
    p.communicate(selector(undelivered_slot), timeout=45)
assert not (spool/first/'reply'/(undelivered_slot+'.delivered')).exists()
assert len(final['files']) == 2
for metadata, (_, mime, original) in zip(final['files'], (png, pdf)):
    assert metadata['mime'] == mime and metadata['length'] == len(original)
    assert metadata['sha256'] == sha256(original).hexdigest()
    assert call('bridge-wait', a, data=selector(metadata['slot']), want='attachment') == original
(spool/first/'reply'/(undelivered_slot+'.delivered')).unlink()
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
day = 86400
now = time.time()
reply_record = inbox/'.replies'/first
os.utime(folder/(slot+'.delivered'), (now-6*day,)*2)
os.utime(reply_record, (now-29*day,)*2)
call('jarvis-expire', want='cleaned')
assert (folder/slot).exists() and (folder/undelivered_slot).exists()
os.utime(folder/(slot+'.delivered'), (now-8*day,)*2)
upload = envelope('simultaneous upload', ('large.pdf', pdf[1], pdf_document(2*1024*1024)))
with subprocess.Popen([str(script), 'bridge-submit', c], env=env, stdin=subprocess.PIPE,
                      stdout=subprocess.PIPE, stderr=subprocess.PIPE) as p:
    try:
        p.stdin.write(upload[:-1])
        p.stdin.flush()
        call('jarvis-expire', want='cleaned')
        assert p.poll() is None and not (folder/slot).exists() and (folder/undelivered_slot).exists()
        out, err = p.communicate(upload[-1:], timeout=45)
        assert p.returncode == 0 and not err
    finally:
        if p.poll() is None:
            p.kill()
answer = json.loads(out)
assert answer['result'] == 'announced'
fresh = answer['receipt']
os.utime(reply_record, (now-31*day,)*2)
call('jarvis-expire', want='cleaned')
call('bridge-wait', a, data=selector(slot), want='expired')
call('bridge-wait', a, data=selector(undelivered_slot), want='expired')
assert all(f['expired'] for f in call('bridge-wait', a, want='answered')['files'])
assert not (folder/slot).exists() and not (reqfolder/request['files'][0]['slot']).exists()

# A sparse quota fixture refuses both sides without a wake, partial release,
# or eviction of the unhandled request. Abandoned staging is reclaimable.
pending = spool/fresh/'request'
pending_slot = json.loads((pending/'manifest.json').read_bytes())['files'][0]['slot']
extra = pending/pending_slot
original = extra.read_bytes()
with extra.open('r+b') as out:
    out.truncate(256*1024*1024)
wakes = (state/'.wake-queue').read_bytes()


def audit_limit():
    signal.signal(signal.SIGXFSZ, signal.SIG_IGN)
    resource.setrlimit(resource.RLIMIT_FSIZE, (1, 1))


call('bridge-submit', unknown, data=packet, preexec_fn=audit_limit, want='overload')
call('bridge-status', c, preexec_fn=audit_limit, want='announced')
call('jarvis-release', c, data=reply, want='overload')
assert not (spool/fresh/'reply').exists() and not (inbox/'.replies'/fresh).exists()
assert (state/'.wake-queue').read_bytes() == wakes and (pending/'manifest.json').exists()
text_only = 'f'*32
call('bridge-submit', text_only, data=envelope('text only at quota'), want='announced')
long_text = '\n'*8100 + 'a'*8284
call('jarvis-release', text_only, data=envelope(long_text), want='answered')
assert call('bridge-wait', text_only, want='answered')['text'] == long_text
wakes = (state/'.wake-queue').read_bytes()
extra.write_bytes(original)
stage = spool/fresh/'.stage'
stage.mkdir(mode=0o700)
(stage/'partial').write_bytes(b'synthetic')
call('jarvis-expire', want='cleaned')
assert not stage.exists()
orphan = spool/('jarvis-'+sha256(('jarvis-v1:'+unknown).encode()).hexdigest()[:32])
orphan.mkdir(mode=0o700)
shutil.copytree(pending, orphan/'request')
manifest_path = orphan/'request'/'manifest.json'
manifest = json.loads(manifest_path.read_bytes())
manifest.update(request=unknown, receipt=orphan.name)
manifest_path.write_text(json.dumps(manifest))
call('jarvis-expire', want='cleaned')
assert not orphan.exists()
call('jarvis-publish', 'spool-independent', data=b'published without attachments', want='published')
# Scratch directory failure cannot create a note or follow the symlink.
spool.rename(inbox/'.saved')
scratch = home/'empty'
scratch.mkdir()
spool.symlink_to(scratch, target_is_directory=True)
assert call('bridge-lookup', 'spool-independent', want='available')['text'] == 'published without attachments'
call('jarvis-withdraw', 'spool-independent', want='withdrawn')
call('bridge-submit', unknown, data=packet, want='server-error')
assert not list(scratch.iterdir()) and (state/'.wake-queue').read_bytes() == wakes
spool.unlink()
(inbox/'.saved').rename(spool)
call('jarvis-release', c, data=envelope('disk error', pdf, larger), preexec_fn=file_limit, want='server-error')
assert not (spool/fresh/'reply').exists() and not (inbox/'.replies'/fresh).exists()
call('jarvis-release', c, data=badframes[-1], want='invalid')
call('jarvis-release', c, data=envelope('final', jpeg, webp, bzip), want='answered')
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
call('jarvis-publish', 'fixture', data=b'current projection', want='published')
assert call('bridge-lookup', 'fixture', want='available')['text'] == 'current projection'
call('jarvis-withdraw', 'fixture', want='withdrawn')
assert call('bridge-lookup', 'fixture', want='not-available') == unavailable
for row in (inbox/'.jarvis'/'audit.jsonl').read_bytes().splitlines():
    assert set(json.loads(row)) == {'at','principal','verb','result','correlation','bytes','duration_ms'}
    assert not any(word in row for word in (b'PRIVATE', b'fixture', b'.pdf', b'projection', slot.encode()))
