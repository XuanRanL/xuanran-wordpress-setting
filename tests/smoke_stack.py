#!/usr/bin/env python3
"""Opt-in isolated Linux/Docker smoke test; never mounts production directories.

Build xr-ci:fpm and xr-ci:cli first, or set FPM_TEST_IMAGE/CLI_TEST_IMAGE.
Temporary fixture/log directory is printed for diagnosis; all fixture services
are removed in finally. Do not pass production Compose environment overrides.
"""
import hashlib,json,os,pathlib,secrets,shutil,socket,subprocess,sys,tempfile
source=pathlib.Path(__file__).resolve().parents[1]
root=pathlib.Path(tempfile.mkdtemp(prefix='xr-setting-bootstrap-'))
(root/'tmp').mkdir()
(root/'tmp').chmod(0o1777)
for directory in ['scripts','php','nginx']:
    shutil.copytree(source/directory,root/directory)
shutil.copy(source/'docker-compose.yml',root/'docker-compose.yml')
project='xrsetting'+secrets.token_hex(5)
with socket.socket() as probe:
    probe.bind(('127.0.0.1',0)); port=probe.getsockname()[1]
envfile=root/'.env'
envfile.write_text(f'COMPOSE_PROJECT_NAME={project}\nNGINX_PORT={port}\nDB_ROOT_PASSWORD={secrets.token_hex(24)}\nWP_DB_PASSWORD={secrets.token_hex(24)}\nWP_DB_NAME=wordpress\nWP_DB_USER=wordpress\n')
envfile.chmod(0o600)
override={'services':{
    'wordpress':{'image':os.environ.get('FPM_TEST_IMAGE','xr-ci:fpm'),'pull_policy':'never','mem_limit':'512m','cpus':0.25},
    'wpcli':{'image':os.environ.get('CLI_TEST_IMAGE','xr-ci:cli'),'pull_policy':'never','mem_limit':'128m','cpus':0.25,
             'volumes':[str(root/'tmp')+':/tmp']},
    'db':{'mem_limit':'1024m','cpus':0.5},
    'redis':{'mem_limit':'128m','cpus':0.1},
    'nginx':{'mem_limit':'64m','cpus':0.1}}}
(root/'compose.override.json').write_text(json.dumps(override))
env={k:v for k,v in os.environ.items() if not k.startswith('COMPOSE_') and
     k not in {'DB_ROOT_PASSWORD','WP_DB_NAME','WP_DB_USER','WP_DB_PASSWORD','NGINX_PORT','SITE_DOMAIN'}}
env['COMPOSE_FILE']=str(root/'docker-compose.yml')+':'+str(root/'compose.override.json')
result={'root':str(root),'project':project,'port':port,'runs':[]}
digest=lambda:hashlib.sha256(envfile.read_bytes()).hexdigest()
initial=digest()
def run(args,timeout=240):
    return subprocess.run(args,cwd=root,env=env,capture_output=True,text=True,timeout=timeout)
try:
    effective=run(['docker','compose','config','--format','json'])
    assert effective.returncode==0,effective.stderr
    for service in json.loads(effective.stdout)['services'].values():
        for volume in service.get('volumes',[]):
            if volume.get('type')=='bind':
                assert pathlib.Path(volume['source']).resolve().is_relative_to(root.resolve()),'fixture bind escapes isolated root'
    for index in range(2):
        process=run(['bash','scripts/bootstrap-wordpress.sh'])
        (root/f'bootstrap-{index+1}.log').write_text(process.stdout+process.stderr)
        result['runs'].append({'rc':process.returncode,'env_unchanged':digest()==initial,
                              'log':str(root/f'bootstrap-{index+1}.log')})
        if process.returncode: raise RuntimeError('bootstrap failed: '+process.stderr[-2500:])
        assert digest()==initial,'bootstrap changed existing credentials'
        http=run(['curl','--silent','--show-error','--max-time','10','--output','/dev/null','--write-out','%{http_code}',f'http://127.0.0.1:{port}/'])
        result['runs'][-1]['http']=http.stdout
        assert http.returncode==0 and http.stdout in ('200','302'),'fresh installation is not reachable over HTTP'
    before=run(['docker','compose','exec','-T','db','sh','-c',
                'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysql -u root -N --batch "$MYSQL_DATABASE" -e "SELECT @@server_uuid, DATABASE();"'])
    after=run(['docker','compose','run','--rm','--no-deps','-T','--entrypoint','','wpcli',
               'wp','db','query','SELECT @@server_uuid, DATABASE();','--skip-column-names','--batch','--skip-plugins','--skip-themes'])
    result['identity_check']={'db_rc':before.returncode,'cli_rc':after.returncode,
                              'same':before.stdout.strip()==after.stdout.strip(),'cli_error':after.stderr[-1000:]}
    assert before.returncode==after.returncode==0 and result['identity_check']['same']
    cli=['docker','compose','run','--rm','--no-deps','-T','--entrypoint','','wpcli','wp']
    cipher=run(cli+['db','query',"SHOW SESSION STATUS LIKE 'Ssl_cipher';",'--skip-column-names','--batch'])
    result['tls_check']={'rc':cipher.returncode,'cipher':cipher.stdout.strip()}
    assert cipher.returncode==0 and len(cipher.stdout.strip().split())==2
    create=run(cli+['db','query','CREATE TABLE xr_hardening_probe (id INT); INSERT INTO xr_hardening_probe VALUES (42);'])
    assert create.returncode==0,create.stderr
    dump=run(cli+['db','export','-','--tables=xr_hardening_probe'])
    result['dump_check']={'rc':dump.returncode,'contains_table': 'xr_hardening_probe' in dump.stdout,
                          'error':dump.stderr[-1000:]}
    assert dump.returncode==0 and result['dump_check']['contains_table']
    check=run(cli+['db','check'])
    result['integrity_check']={'rc':check.returncode,'error':check.stderr[-1000:]}
    assert check.returncode==0,check.stderr
    result['services']=run(['docker','compose','ps','--format','json']).stdout
except Exception as error:
    result['error']=str(error)
finally:
    cleanup=run(['docker','compose','down','--volumes','--remove-orphans'])
    result['cleanup_rc']=cleanup.returncode
    (root/'bootstrap-result.json').write_text(json.dumps(result,indent=2))
    print(json.dumps(result,indent=2),flush=True)

if result.get("error") or result.get("cleanup_rc") != 0:
    sys.exit(1)
