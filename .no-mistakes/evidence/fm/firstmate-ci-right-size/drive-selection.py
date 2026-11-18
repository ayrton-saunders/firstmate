import collections, json, os, pathlib, shutil, subprocess, tempfile
root = pathlib.Path.cwd()
evidence = pathlib.Path('~/.no-mistakes/evidence/01M7Q347TWJ63EVPVBKV3ZZRJD')
records = []
def run(command, cwd=root, expected=0, env=None):
    p = subprocess.run(command, cwd=cwd, env=env, text=True, capture_output=True, timeout=180)
    records.append(dict(command=command, cwd=str(cwd), exit=p.returncode, stdout=p.stdout, stderr=p.stderr))
    assert p.returncode == expected, records[-1]
    return p.stdout.splitlines()
def runner(*args, cwd=root, env=None, expected=0):
    return run(['bash','bin/fm-test-run.sh',*args],cwd,expected,env)
fixture = pathlib.Path(tempfile.mkdtemp(prefix='.validation-selection-',dir=root))
try:
    (fixture/'bin').mkdir()
    (fixture/'tests').symlink_to(root/'tests',target_is_directory=True)
    for script in ['fm-test-run.sh','fm-lint.sh']:
        content = subprocess.check_output(['git','show','ebd520e74e04ab61fda68d20be71e9b9fa573105:bin/'+script])
        (fixture/'bin'/script).write_bytes(content)
    (fixture/'bin'/'backends').symlink_to(root/'bin'/'backends',target_is_directory=True)
    # Lint selection needs all canonical files and the common library, but invokes no analyzer.
    for path in (root/'bin').glob('*.sh'):
        if not (fixture/'bin'/path.name).exists():
            (fixture/'bin'/path.name).symlink_to(path)
    all_tests = runner('--list','--all')
    lanes = runner('--list-lanes')
    serial_lanes = [x for x in lanes if x.startswith('portable-serial-')]
    parts = {lane:runner('--list','--lane',lane) for lane in ['portable-parallel-1','portable-parallel-2','portable-serial','real-herdr-gated']}
    flattened = sum(parts.values(),[])
    assert collections.Counter(flattened) == collections.Counter(all_tests)
    old_parallel = sum([runner('--list','--lane',lane,cwd=fixture) for lane in ['portable-parallel-1','portable-parallel-2']],[])
    assert set(old_parallel) == set(parts['portable-parallel-1']+parts['portable-parallel-2'])
    assert 'tests/fm-pi-primary-types.test.sh' in parts['portable-parallel-1']
    shards = []
    for lane in serial_lanes:
        current = runner('--list','--lane',lane)
        baseline = runner('--list','--lane',lane,cwd=fixture)
        assert current == baseline, lane
        shards += current
    assert collections.Counter(shards) == collections.Counter(parts['portable-serial'])
    assert runner('--list','--lane',serial_lanes[0]) == runner('--list','--lane',serial_lanes[0])
    runner('--check-coverage')
    print('Complete inventory preserved; parallel union unchanged; Pi typecheck stays in lane 1; all serial assignments exactly match baseline.')
    # Deliberately break an external packing dependency after it emits valid rows.
    fakebin = fixture/'fakebin'; fakebin.mkdir()
    sort = shutil.which('sort')
    (fakebin/'sort').write_text('#!/usr/bin/env bash\n'+json.dumps(sort)+' "$@"\nexit 42\n')
    (fakebin/'sort').chmod(0o755)
    env = dict(os.environ, PATH=str(fakebin)+os.pathsep+os.environ['PATH'])
    p = subprocess.run(['bash','bin/fm-test-run.sh','--list','--lane',serial_lanes[0]],env=env,text=True,capture_output=True,timeout=180)
    records.append(dict(command=['packing failure injection',serial_lanes[0]],exit=p.returncode,stdout=p.stdout,stderr=p.stderr))
    assert p.returncode != 0 and not p.stdout and 'could not pack portable serial shards' in p.stderr
    runner('--list','--lane','portable-serial-1of999',expected=2)
    runner('--lane','portable-serial','--jobs','2',expected=2)
    print('Adversarial packing failure emits no partial schedule; mismatched shard count and concurrent serial invocation refused.')
    # Independent canonical inventory comes from the documented three direct-child directories.
    canonical = sorted(str(p.relative_to(root)) for d in ['bin','bin/backends','tests'] for p in (root/d).glob('*.sh'))
    env = dict(os.environ,CI='true')
    full = run(['bash','bin/fm-lint.sh','--list-files'],env=env)
    assert sorted(full) == canonical
    for n in [2,4]:
        union = []
        weights = []
        expected_parts = [[] for _ in range(n)]
        expected_loads = [0]*n
        for path in sorted(full, key=lambda p: (-(root/p).stat().st_size,full.index(p))):
            dest = min(range(n),key=lambda i: expected_loads[i])
            expected_loads[dest] += (root/path).stat().st_size
            expected_parts[dest].append(path)
        for i in range(1,n+1):
            args = ['bash','bin/fm-lint.sh','--partition',f'{i}of{n}','--list-files']
            current = run(args,env=env)
            assert current == [p for p in full if p in expected_parts[i-1]]
            union += current
            weights.append(sum((root/p).stat().st_size for p in current))
        assert collections.Counter(union) == collections.Counter(canonical)
        print(f'{n}-way lint selection: {len(canonical)} canonical roots, documented byte-weight LPT membership; byte loads={weights}')
    run(['bash','bin/fm-lint.sh','--partition','1of4','--fast','--list-files'],expected=2,env=env)
    print('Partition selection rejects weakened fast mode. No linters or static analyzers were run.')
finally:
    (evidence/'selection-transcript.json').write_text(json.dumps(records,indent=2)+'\n')
    shutil.rmtree(fixture)
