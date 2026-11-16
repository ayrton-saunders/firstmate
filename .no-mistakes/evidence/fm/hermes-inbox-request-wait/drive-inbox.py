"""Drive real inbox CLI with synthetic state, no model or primary substitute.
Oracle: fm-inbox-wait.v1 documented outcomes and author's nonblocking/path-free errors.
"""
import hashlib
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import time

root = Path.cwd()
home = Path(tempfile.mkdtemp(prefix='private-inbox-', dir=root / '.test-local-tmp'))
env = {k: v for k, v in os.environ.items() if not k.startswith('FM_') and not k.startswith('HERDR_')}
env.update(FM_HOME=str(home), FM_STATE_OVERRIDE=str(home/'state'), FM_DATA_OVERRIDE=str(home/'data'), FM_CONFIG_OVERRIDE=str(home/'config'))
cli = str(root / 'bin/fm-inbox.sh')
for d in ('state', 'data', 'config'):
    (home/d).mkdir()

def run(*args, expected=0):
    start = time.monotonic()
    p = subprocess.run([cli, *args], env=env, capture_output=True, text=True, timeout=5)
    elapsed = time.monotonic()-start
    print('$ fm-inbox.sh', ' '.join(args), flush=True)
    print(f'exit={p.returncode}; elapsed={elapsed:.3f}s', flush=True)
    print(p.stdout or p.stderr, end='' if (p.stdout or p.stderr).endswith('\n') else '\n', flush=True)
    assert p.returncode == expected, (p.returncode, expected)
    return p, elapsed

def note(body, request):
    p, _ = run('note', '--request-id', request, '--json', body)
    return json.loads(p.stdout)['id']

def result(*args, code=0):
    p, elapsed = run('wait', *args, expected=code)
    return json.loads(p.stdout), elapsed

try:
    print('SCENARIO 1: Submit once, wait concurrently, record durable final reply, then acknowledge and retry.')
    nid = note('Calculate six times seven and report the final result.', 'local-outside-1')
    assert note('Calculate six times seven and report the final result.', 'local-outside-1') == nid
    queue = home/'state/.wake-queue'
    saved_queue = queue.read_bytes()
    waiter = subprocess.Popen([cli, 'wait', nid, '--timeout', '5', '--json'], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        time.sleep(.3)
        assert waiter.poll() is None, 'wait returned before an answer existed'
        body = 'Result: 42\nQuoted "value"; unicode café; slash \\.'
        run('reply', nid, body)
        stdout, stderr = waiter.communicate(timeout=3)
        print('$ fm-inbox.sh wait <id> --timeout 5 --json [already running when reply recorded]')
        print('exit=' + str(waiter.returncode)); print(stdout, end='')
        data = json.loads(stdout)
        assert waiter.returncode == 0 and data['outcome'] == 'answered'
        assert data['reply']['body'] == body and data['acknowledged'] is False
    finally:
        if waiter.poll() is None:
            waiter.kill(); waiter.communicate()
    run('drain', '--ack', nid)
    data, _ = result(nid, '--timeout', '0', '--json')
    assert data['outcome'] == 'answered' and data['acknowledged'] is True
    assert data['reply']['body'] == body
    run('wait', nid, '--timeout', '0')
    assert queue.read_bytes() == saved_queue
    print('Observed: final answer persisted; no extra caller prompt or wait-generated notification. Local manual consumer only, not autonomous primary pickup.\n')

    print('SCENARIO 2: Pending deadline, repeatable snapshot, bare handled and unknown outcomes remain distinct.')
    pending = note('Unfinished synthetic request', 'local-pending')
    record = home/'state/inbox'/f'{pending}.note'
    before = record.read_bytes()
    data, elapsed = result(pending, '--timeout', '1', '--json', code=3)
    assert data['outcome'] == 'timeout' and .9 <= elapsed < 3
    assert record.read_bytes() == before
    data, _ = result(pending, '--timeout', '0', '--json', code=3)
    assert data['reply'] is None and data['acknowledged'] is False
    run('drain', '--ack', pending)
    data, _ = result(pending, '--timeout', '0', '--json', code=2)
    assert data['outcome'] == 'handled' and data['reply'] is None and data['acknowledged'] is True
    data, _ = result('absent-local-id', '--timeout', '0', '--json', code=4)
    assert data['outcome'] == 'unknown'
    for value in ('-1','1.5','86401','999999999999999999'):
        run('wait', pending, '--timeout', value, expected=1)
    print('Observed: no cancellation or fabricated answer; deadline and documented exit codes hold.\n')

    print('SCENARIO 3: Non-regular reply records cannot block wait, including FIFO with no writer.')
    damaged = note('Damaged record synthetic request', 'local-damaged')
    reply = home/'state/inbox/.replies'/damaged
    for kind in ('fifo', 'directory', 'symlink-to-fifo', 'socket'):
        sock = None
        other = reply.with_name('fifo-target')
        if kind == 'fifo': os.mkfifo(reply)
        elif kind == 'directory': reply.mkdir()
        elif kind == 'symlink-to-fifo':
            os.mkfifo(other); reply.symlink_to(other.name)
        else:
            sock = socket.socket(socket.AF_UNIX)
            os.chdir(reply.parent)
            try: sock.bind(reply.name)
            finally: os.chdir(root)
        try:
            print('record type:', kind)
            p, elapsed = run('wait', damaged, '--timeout', '1', '--json', expected=1)
            assert elapsed < 1, 'damaged record waited beyond timeout'
            assert str(home) not in p.stdout+p.stderr and str(root) not in p.stdout+p.stderr
            assert damaged in p.stderr
            if kind != 'socket': assert 'non-regular reply record' in p.stderr
        finally:
            if sock: sock.close()
            if kind == 'directory': reply.rmdir()
            else: reply.unlink()
            if other.exists(): other.unlink()
    print('Observed: immediate plain error without a writer, directory read, or blocking socket operation.\n')

    print('SCENARIO 4: Damaged regular records, filesystem errors and invalid IDs expose no private paths.')
    for kind in ('malformed', 'symlink-loop', 'replies-parent-is-file'):
        parent = reply.parent
        if kind == 'malformed': reply.write_text('seq=not-a-number\n--\nprivate data\n')
        elif kind == 'symlink-loop': reply.symlink_to(reply.name)
        else:
            parent.rename(parent.with_name('.replies-backup')); parent.write_text('not a directory')
        try:
            print('damage:', kind)
            p, _ = run('wait', damaged, '--timeout', '0', '--json', expected=1)
            assert damaged in p.stderr
            assert str(home) not in p.stdout+p.stderr and str(root) not in p.stdout+p.stderr
            assert 'Traceback' not in p.stderr
        finally:
            if kind == 'replies-parent-is-file':
                parent.unlink(); parent.with_name('.replies-backup').rename(parent)
            else: reply.unlink()
    for value in ('.','../private','x'*256):
        p, _ = run('wait', value, '--timeout', '0', '--json', expected=1)
        assert 'invalid or missing note id' in p.stderr
        assert str(home) not in p.stdout+p.stderr
    print('Observed: note-scoped diagnostics/stable errno, no absolute home/state paths.\n')
finally:
    shutil.rmtree(home)
    print('Disposable home removed; every CLI child awaited.')
