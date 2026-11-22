"""Binary-protocol cases for fm-inbox.test.sh. All state belongs to this fixture."""
import base64
from concurrent.futures import ThreadPoolExecutor
from hashlib import sha256
import fcntl
import io
import json
import os
import re
import resource
import shlex
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
call('bridge-submit', a, data=packet, binary=copy/script.name, want='saved-not-announced')
(copy/'fm-wake-lib.sh').unlink()
first = call('bridge-status', a, want='saved-not-announced')['receipt']
assert call('bridge-submit', a, data=packet, binary=copy/script.name, want='saved-not-announced')['receipt'] == first
assert not (state/'.wake-queue').exists()
(copy/'fm-wake-lib.sh').write_text(
    f'. {shlex.quote(str(script.with_name("fm-wake-lib.sh")))}\n'
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

queue = state/'.wake-queue'
old_row = repaired.replace(payload, b'older warning text\n', 1)
queue.write_bytes(queue.read_bytes().replace(repaired, old_row, 1))
(inbox/'.announced'/first).unlink()
queued = queue.read_bytes()
call('bridge-submit', a, data=packet, want='announced')
assert queue.read_bytes() == queued
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
failed_reader = home/'failed-reader'
failed_reader.mkdir()
cat_shim = failed_reader/'cat'
cat_shim.write_text('#!/bin/sh\nprintf "partial body\\n"\nexit 1\n')
cat_shim.chmod(0o700)
original_path = env['PATH']
try:
    env['PATH'] = f'{failed_reader}:{original_path}'
    call('bridge-submit', cut, data=long_packet, want='not-saved')
    call('jarvis-release', lost, data=long_packet, want='server-error')
finally:
    env['PATH'] = original_path
assert len(list(inbox.glob('*.note'))) == 2 and not (state/'.wake-queue').read_bytes()
assert not (inbox/'.replies'/lost_note).exists() and not (spool/lost_note/'reply').exists()
crash_child = copy/script.name
publisher_crashed = home/'publisher-crashed'
publisher_continue = home/'publisher-continue'
crash_child.write_text(f'''#!/usr/bin/env bash
if [ "$1" = bridge-submit ]; then
    exec python3 -IB {shlex.quote(str(copy/'fm-jarvis-bridge.py'))} {shlex.quote(str(inbox))} "$@"
fi
if [ "$1" = note ]; then
    cat >/dev/null
    receipt=$(
        kill -KILL "$$"
        touch {shlex.quote(str(publisher_crashed))}
        while [ ! -f {shlex.quote(str(publisher_continue))} ]; do sleep 0.05; done
    )
    exit 1
fi
exit 2
''')
with subprocess.Popen([str(crash_child), 'bridge-submit', cut], env=env, stdin=subprocess.PIPE,
                      stdout=subprocess.PIPE, stderr=subprocess.PIPE) as crashed:
    try:
        crashed.stdin.write(long_packet)
        crashed.stdin.close()
        crashed.stdin = None
        deadline = time.monotonic() + 10
        while not publisher_crashed.exists() and time.monotonic() < deadline:
            time.sleep(0.02)
        assert publisher_crashed.exists()
        try:
            crashed.wait(timeout=0.5)
        except subprocess.TimeoutExpired:
            pass
        else:
            raise AssertionError('submit returned while its publisher still held scratch')
    finally:
        publisher_continue.touch()
    out, err = crashed.communicate(timeout=10)
    assert crashed.returncode == 0 and not err and json.loads(out)['result'] == 'not-saved'

publisher_crashed.unlink()
publisher_continue.unlink()
with subprocess.Popen([str(crash_child), 'bridge-submit', cut], env=env, stdin=subprocess.PIPE,
                      stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL) as interrupted:
    try:
        interrupted.stdin.write(long_packet)
        interrupted.stdin.close()
        deadline = time.monotonic() + 10
        while not publisher_crashed.exists() and time.monotonic() < deadline:
            time.sleep(0.02)
        assert publisher_crashed.exists()
        interrupted.send_signal(signal.SIGINT)
        assert interrupted.wait(timeout=5) != 0
        scratch = inbox/'.jarvis-writing'
        scratch.write_bytes(b'publisher still active')
        with subprocess.Popen([str(script), 'jarvis-expire'], env=env, stdin=subprocess.DEVNULL,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE) as sweep:
            try:
                try:
                    sweep.wait(timeout=0.5)
                except subprocess.TimeoutExpired:
                    assert scratch.exists()
                else:
                    raise AssertionError('sweep entered before the publisher helper exited')
            finally:
                publisher_continue.touch()
            out, err = sweep.communicate(timeout=10)
            assert sweep.returncode == 0 and not err and json.loads(out)['result'] == 'cleaned'
            assert not scratch.exists()
    finally:
        publisher_continue.touch()
reserved = call('bridge-submit', cut, data=long_packet, preexec_fn=publisher_limit, want='not-saved')['receipt']
assert len(list(inbox.glob('*.note'))) == 2 and not (state/'.wake-queue').read_bytes()
assert call('bridge-status', cut, want='not-saved')['receipt'] == reserved
assert call('bridge-wait', cut, want='not-saved')['receipt'] == reserved
call('bridge-submit', cut, data=envelope('different text'), want='conflict')
call('jarvis-release', lost, data=long_packet, preexec_fn=publisher_limit, want='server-error')
assert not (inbox/'.replies'/lost_note).exists() and not (spool/lost_note/'reply').exists()
for parent in (inbox, inbox/'.replies'):
    scratch = parent/'.jarvis-writing'
    if not scratch.exists():
        scratch.write_bytes(b'interrupted publisher')
call('jarvis-expire', want='cleaned')
assert not any(inbox.rglob('.jarvis-writing'))
cut_note = call('bridge-submit', cut, data=long_packet, want='announced')['receipt']
assert cut_note == reserved
assert (inbox/(cut_note+'.note')).read_bytes().partition(b'\n--\n')[2] == b'x'*12000 + b'\n'
wait_child = copy/script.name
poll_entered = home/'poll-entered'
poll_continue = home/'poll-continue'
wait_child.write_text(f'''#!/usr/bin/env bash
set -eu
inbox={shlex.quote(str(script))}
if [ "$1" = bridge-wait ]; then
    exec python3 -IB {shlex.quote(str(copy/'fm-jarvis-bridge.py'))} {shlex.quote(str(inbox))} "$@"
fi
if [ "$1" = wait ] && [ "$4" = 20 ]; then
    if [ "$2" = {shlex.quote(cut_note)} ]; then
        rc=0
        "$inbox" wait "$2" --timeout 0 --json || rc=$?
        [ "$rc" -eq 3 ]
        "$inbox" drain --ack "$2" >/dev/null
        exit 3
    fi
    touch {shlex.quote(str(poll_entered))}
    while [ ! -f {shlex.quote(str(poll_continue))} ]; do sleep 0.05; done
fi
exec "$inbox" "$@"
''')
assert call('bridge-wait', cut, binary=wait_child, want='handled-no-answer')['receipt'] == cut_note
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
hook_calls = home/'hook-calls'
shim = home/'python-shim'
shim.mkdir()
python = shim/'python3'
python.write_text(f'''#!/bin/sh
case "${{2:-}}" in
    */fm-discord-hook.py) printf '%s\\n' "$3 $4" >> {shlex.quote(str(hook_calls))}; exit 0 ;;
esac
exec {shlex.quote(sys.executable)} "$@"
''')
python.chmod(0o700)
discord_config = home/'config'/'discord-integration.json'
old_path = env['PATH']
with ThreadPoolExecutor(1) as pool:
    waiting = pool.submit(call, 'bridge-wait', a, binary=wait_child, want='answered')
    try:
        deadline = time.monotonic() + 10
        while not poll_entered.exists() and not waiting.done() and time.monotonic() < deadline:
            time.sleep(0.02)
        assert poll_entered.exists() and not waiting.done()
        discord_config.write_text('{}')
        env['PATH'] = f'{shim}:{old_path}'
        call('jarvis-release', a, data=reply, want='answered')
        assert (inbox/'.replies'/first).exists() and not (inbox/'handled'/(first+'.note')).exists()
        assert not waiting.done() and not hook_calls.exists()
        control = json.loads(run('note', '--json', 'Discord hook control').stdout)['id']
        run('reply', control, 'ordinary local reply')
        assert hook_calls.read_text().splitlines() == [f'outcome {control}']
    finally:
        env['PATH'] = old_path
        discord_config.unlink(missing_ok=True)
        poll_continue.touch()
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
    out, err = p.communicate(selector(undelivered_slot), timeout=45)
    assert p.returncode != 0 and not out and not err
log = inbox/'.jarvis'/'audit.jsonl'
failed = json.loads(log.read_bytes().splitlines()[-1])
assert (failed['verb'], failed['result'], failed['bytes']) == (
    'bridge-wait', 'write-failed', len(selector(undelivered_slot)),
)
assert not (spool/first/'reply'/(undelivered_slot+'.delivered')).exists()
assert len(final['files']) == 2
for metadata, (_, mime, original) in zip(final['files'], (png, pdf)):
    assert metadata['mime'] == mime and metadata['length'] == len(original)
    assert metadata['sha256'] == sha256(original).hexdigest()
    selection = selector(metadata['slot'])
    assert call('bridge-wait', a, data=selection, want='attachment') == original
    completed = json.loads(log.read_bytes().splitlines()[-1])
    assert (completed['verb'], completed['result'], completed['bytes']) == (
        'bridge-wait', 'attachment', len(selection) + len(original),
    )
(spool/first/'reply'/(undelivered_slot+'.delivered')).unlink()
streamed_pdf = pdf_document(2*1024*1024)
streaming_file = (*pdf[:2], streamed_pdf)
call('jarvis-release', lost, data=envelope('separate release', jpeg, streaming_file, streaming_file), want='answered')
other_slot, *streaming_slots = (item['slot'] for item in call('bridge-wait', lost, want='answered')['files'])
assert call('bridge-wait', lost, data=selector(other_slot), want='attachment') == jpeg[2]
assert call('bridge-wait', a, data=selector(slot), want='attachment') == png[2]
call('bridge-wait', a, data=selector(other_slot), want='not-available')
call('bridge-wait', lost, data=selector(slot), want='not-available')
reply_record = inbox/'.replies'/lost_note
for streaming_slot, sweep_during_transfer in zip(streaming_slots, (False, True)):
    now = time.time()
    os.utime(reply_record, (now, now))
    with subprocess.Popen([str(script), 'bridge-wait', lost], env=env, stdin=subprocess.PIPE,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0) as p:
        try:
            p.stdin.write(selector(streaming_slot))
            p.stdin.close()
            p.stdin = None
            assert json.loads(p.stdout.readline())['result'] == 'attachment'
            old = time.time()-31*86400
            os.utime(reply_record, (old, old))
            if sweep_during_transfer:
                call('jarvis-expire', want='cleaned')
                call('bridge-wait', lost, data=selector(streaming_slot), want='expired')
            framed, err = p.communicate(timeout=45)
            assert p.returncode == 0 and not err and framed == frame(streamed_pdf)
        finally:
            if p.poll() is None:
                p.kill()
    transfer_dir = spool/lost_note/'reply'
    assert (transfer_dir/(streaming_slot+'.expired')).exists() and not (transfer_dir/streaming_slot).exists()
    assert not (transfer_dir/(streaming_slot+'.delivered')).exists()
for streaming_slot in streaming_slots:
    call('bridge-wait', lost, data=selector(streaming_slot), want='expired')
flush_seen = home/'flush-seen'
flush_continue = home/'flush-continue'
probe = '''
import fcntl, runpy, sys, time
from pathlib import Path
notice, resume, bridge, *args = sys.argv[1:]
flock = fcntl.flock
calls = 0
def observe(fd, op):
    global calls
    calls += 1
    if calls == 2:
        Path(notice).touch()
        deadline = time.monotonic() + 10
        while not Path(resume).exists() and time.monotonic() < deadline:
            time.sleep(0.01)
    return flock(fd, op)
fcntl.flock = observe
sys.argv = [bridge, *args]
runpy.run_path(bridge, run_name='__main__')
'''
with subprocess.Popen([sys.executable, '-IB', '-c', probe, str(flush_seen), str(flush_continue),
                       str(script.with_name('fm-jarvis-bridge.py')), str(inbox), 'bridge-wait', a],
                      env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE) as p:
    p.stdin.write(selector(undelivered_slot))
    p.stdin.close()
    p.stdin = None
    deadline = time.monotonic() + 5
    while not flush_seen.exists() and time.monotonic() < deadline:
        time.sleep(0.01)
    assert flush_seen.exists()
    arrived = time.time()
    control_fd = os.open(inbox/'.jarvis', os.O_RDONLY)
    record = inbox/'.replies'/first
    original_times = record.stat()
    try:
        fcntl.flock(control_fd, fcntl.LOCK_EX)
        expiry = arrived + 0.1
        os.utime(record, (expiry-30*86400,)*2)
        flush_continue.touch()
        while time.time() <= expiry:
            time.sleep(0.01)
    finally:
        os.close(control_fd)
    framed, err = p.communicate(timeout=10)
    os.utime(record, ns=(original_times.st_atime_ns, original_times.st_mtime_ns))
    assert p.returncode == 0 and not err and framed.partition(b'\n')[2] == frame(pdf[2])
assert (spool/first/'reply'/(undelivered_slot+'.delivered')).stat().st_mtime <= arrived
assert call('bridge-wait', a, data=selector(undelivered_slot), want='attachment') == pdf[2]
(spool/first/'reply'/(undelivered_slot+'.delivered')).unlink()
call('bridge-wait', a, data=selector(f['slot']), want='not-available')
for p in (spool, *spool.rglob('*')):
    assert p.stat().st_mode & 0o777 == (0o700 if p.is_dir() else 0o600), p.name

# Another receipt cannot select the first receipt's slot. No implicit release
# of a private local answer, even if it looks like protocol metadata.
second = call('bridge-submit', b, data=envelope('origin=parent', pdf), want='announced')['receipt']
run('reply', second, 'PRIVATE final')
private_reply = inbox/'.replies'/second
os.utime(private_reply, (time.time()-31*86400,)*2)
call('jarvis-expire', want='cleaned')
private_request = spool/second/'request'
private_slot = json.loads((private_request/'manifest.json').read_bytes())['files'][0]['slot']
assert (private_request/private_slot).read_bytes() == pdf[2]
call('bridge-status', b, want='announced')
call('jarvis-release', b, data=reply, want='conflict')
run('drain', '--ack', second)
call('jarvis-expire', want='cleaned')
assert (private_request/private_slot).read_bytes() == pdf[2]
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
release_index = inbox/'.jarvis'/'releases'
call('bridge-lookup', 'spool-independent', want='not-available')
call('jarvis-withdraw', 'spool-independent', want='withdrawn')
assert not release_index.exists()
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

for group, folder in [('pending', inbox), ('handled', inbox/'handled')]:
    receipt_id = json.loads(run('note', '--json', f'newer legacy {group}').stdout)['id']
    if group == 'handled':
        run('drain', '--ack', receipt_id)
    old_ids = [f'jarvis-{i+100:032x}' for i in range(21)]
    for old_id in old_ids:
        (folder/(old_id+'.note')).write_text(f'id={old_id}\nat=2000-01-01T00:00:00Z\nsource=jarvis\n--\nOlder fixture\n')
    bounded = json.loads(run('receipts').stdout)[group]
    assert len(bounded) == 20 and receipt_id in {row['id'] for row in bounded}
    rows = json.loads(run('receipts', f'--all-{group}').stdout)[group]
    assert [row['id'] for row in rows[-21:]] == old_ids[::-1]

scratch_paths = [inbox/'.replies'/'.jarvis-seq', inbox/'.announced'/'.jarvis-writing',
                 inbox/'.jarvis'/'releases'/'.jarvis-writing']
legacy_scratch = inbox/'.replies'/'.seq-legacy'
for scratch in (*scratch_paths, legacy_scratch):
    scratch.write_bytes(b'interrupted fixture write')
call('jarvis-expire', want='cleaned')
assert not any(p.exists() for p in scratch_paths)
assert legacy_scratch.read_bytes() == b'interrupted fixture write'
legacy_scratch.unlink()

interrupted_req = '9'*32
interrupted_note = call('bridge-submit', interrupted_req, data=envelope('recover reply'), want='announced')['receipt']
ordinary_note = json.loads(run('note', '--json', 'ordinary reply contender').stdout)['id']
cursor = json.loads(run('receipts', '--all-replies').stdout)['reply_cursor']
commit_started = home/'commit-started'
commit_continue = home/'commit-continue'
python.write_text(f'''#!/bin/sh
if [ "${{3:-}}" = guarded ] && [ "${{6:-}}" = commit ] && [ "${{8:-}}" = {shlex.quote(str(inbox/'.replies'/interrupted_note))} ]; then
    kill -KILL "$(cat "${{5%.steal}}/pid")" || exit 1
    touch {shlex.quote(str(commit_started))}
    while [ ! -f {shlex.quote(str(commit_continue))} ]; do sleep 0.05; done
fi
exec {shlex.quote(sys.executable)} "$@"
''')
with ThreadPoolExecutor(3) as pool:
    release_env = dict(env, PATH=f'{shim}:{env["PATH"]}')
    release = pool.submit(subprocess.run, [str(script), 'jarvis-release', interrupted_req],
                          input=envelope('interrupted final'), capture_output=True, env=release_env, timeout=30)
    try:
        deadline = time.monotonic() + 10
        while not commit_started.exists() and not release.done() and time.monotonic() < deadline:
            time.sleep(0.02)
        assert commit_started.exists()
        ordinary = pool.submit(run, 'reply', ordinary_note, 'ordinary final')
        same = pool.submit(run, 'reply', interrupted_note, 'must not overwrite', check=False)
        try:
            ordinary.result(timeout=0.5)
        except TimeoutError:
            assert not same.done() and not (inbox/'.replies'/ordinary_note).exists()
        else:
            raise AssertionError('ordinary reply passed an in-flight release commit')
    finally:
        commit_continue.touch()
    ordinary.result()
    assert same.result().returncode != 0
    released = release.result()
    assert released.returncode == 0 and json.loads(released.stdout)['result'] == 'answered'
rows = json.loads(run('receipts', '--after', cursor).stdout)['replies']
assert [(row['body'], int(row['cursor'])) for row in rows] == [
    ('interrupted final', int(cursor)+1), ('ordinary final', int(cursor)+2),
]
assert call('bridge-wait', interrupted_req, want='answered')['text'] == 'interrupted final'
