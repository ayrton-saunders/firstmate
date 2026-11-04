import json, os, pathlib, subprocess
workspace=pathlib.Path.cwd(); lab=workspace/'.validation-primary'; root=lab/'product'
config=lab/'claude-config'; config.mkdir(exist_ok=True)
(config/'.claude.json').write_text(json.dumps({'hasCompletedOnboarding':True, 'theme':'dark'}))
# Reuse the existing normal login in memory; never write or refresh the credential store.
p=subprocess.run(['security','find-generic-password','-s','Claude Code-credentials','-w'],capture_output=True,text=True)
if p.returncode:
    raise SystemExit('Existing normal-login Keychain credential could not be read (no secret logged).')
cred=json.loads(p.stdout)['claudeAiOauth']
env=dict(os.environ)
for k in ['NO_MISTAKES_GATE','FM_GATE_REFUSE_BYPASS','FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','HERDR_ENV','HERDR_SESSION','HERDR_PANE_ID','HERDR_SOCKET_PATH','FM_BACKEND']:
    env.pop(k,None)
env['CLAUDE_CONFIG_DIR']=str(config)
env['CLAUDE_CODE_OAUTH_TOKEN']=cred['accessToken']
env['FM_HOME']=str(lab)
env['TMUX_TMPDIR']=(lab/'state/.fm-lab-tmux-dir').read_text().strip()
subprocess.run(['tmux','-L','fm-lab','new-session','-d','-s','primary','-x','120','-y','40','-c',str(root),'claude','--setting-sources','project,local'],env=env,check=True)
print('Started actual Claude primary with existing normal login, isolated configuration and lab FM_HOME; no credentials saved.')
