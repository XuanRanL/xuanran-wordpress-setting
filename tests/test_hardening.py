"""Offline regression tests; Docker/network are deliberately not invoked."""
import copy
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
BASH = shutil.which('bash') if os.name != 'nt' else 'C:/Program Files/Git/bin/bash.exe'


def posix(path):
    path = str(path).replace('\\', '/')
    return '/' + path[0].lower() + path[2:] if len(path) > 1 and path[1] == ':' else path


def config():
    return {'services': {
        'wordpress': {'volumes': [{'type':'bind','source':str(ROOT/'html'),'target':'/var/www/html'}],
            'environment': {'WORDPRESS_DB_HOST':'db', 'WORDPRESS_DB_NAME': 'wordpress', 'WORDPRESS_DB_USER': 'wordpress',
            'WORDPRESS_DB_PASSWORD': 'safe-secret', 'WORDPRESS_TABLE_PREFIX': 'wp_'}},
        'wpcli': {'volumes': [{'type':'bind','source':str(ROOT/'html'),'target':'/var/www/html'}],
            'environment': {'WORDPRESS_DB_HOST':'db:3306','WORDPRESS_DB_NAME':'wordpress',
                'WORDPRESS_DB_USER':'wordpress','WORDPRESS_DB_PASSWORD':'safe-secret'}},
        'db': {'environment': {'MYSQL_ROOT_PASSWORD': 'root-secret', 'MYSQL_DATABASE': 'wordpress',
            'MYSQL_USER': 'wordpress', 'MYSQL_PASSWORD': 'safe-secret'}},
        'nginx': {'volumes':[{'type':'bind','source':str(ROOT/'html'),'target':'/var/www/html','read_only':True}],
                  'ports': [{'target': 80, 'published': '9876', 'host_ip': '127.0.0.1'}]}}}


class EffectiveConfigTests(unittest.TestCase):
    def run_config(self, value):
        return subprocess.run([sys.executable, str(ROOT / 'scripts/validate-compose.py')],
            input=json.dumps(value), capture_output=True, text=True, cwd=ROOT)

    def test_resolves_loopback_port_from_effective_compose(self):
        result = self.run_config(config())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), '9876')

    def test_rejects_placeholder_password_before_mutation(self):
        value = config(); value['services']['db']['environment']['MYSQL_ROOT_PASSWORD'] = 'change_me_root'
        result = self.run_config(value)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('safe-secret', result.stderr)

    def test_rejects_application_database_password_mismatch(self):
        value = config(); value['services']['db']['environment']['MYSQL_PASSWORD'] = 'different'
        self.assertNotEqual(self.run_config(value).returncode, 0)

    def test_rejects_cli_credentials_host_or_document_root_pointing_elsewhere(self):
        for service,field,value in [('wordpress','WORDPRESS_DB_HOST','other-db:3306'),
                                    ('wpcli','WORDPRESS_DB_HOST','db:3307'),
                                    ('wpcli','WORDPRESS_DB_NAME','other_database'),
                                    ('wpcli','WORDPRESS_DB_PASSWORD','other-secret')]:
            candidate=config(); candidate['services'][service]['environment'][field]=value
            self.assertNotEqual(self.run_config(candidate).returncode,0,(service,field))
        for service in ['wordpress','wpcli']:
            candidate=config(); candidate['services'][service]['volumes'][0]['source']=str(ROOT.parent/'other/html')
            self.assertNotEqual(self.run_config(candidate).returncode,0,service)

    def test_accepts_shared_db_alias_and_rejects_alias_on_unshared_network(self):
        value=config(); value['services']['db']['networks']={'backend':{'aliases':['database']}}
        for service in ['wordpress','wpcli']:
            value['services'][service]['environment']['WORDPRESS_DB_HOST']='database:3306'
            value['services'][service]['networks']={'backend':None}
        self.assertEqual(self.run_config(value).returncode,0)
        value['services']['wpcli']['networks']={'other':None}
        self.assertNotEqual(self.run_config(value).returncode,0)

    def test_rejects_nested_document_root_mounts_and_wrong_nginx_root(self):
        for service in ['wordpress','wpcli','nginx']:
            value=config()
            value['services'][service]['volumes'].append({'type':'bind','source':'/other/uploads',
                                                       'target':'/var/www/html/wp-content/uploads'})
            self.assertNotEqual(self.run_config(value).returncode,0,service)
        value=config(); value['services']['nginx']['volumes'][0]['source']=str(ROOT.parent/'other/html')
        self.assertNotEqual(self.run_config(value).returncode,0)

    def test_rejects_empty_invalid_and_non_loopback_ports(self):
        for port in ['', '0', '65536', 'oops']:
            value = config(); value['services']['nginx']['ports'][0]['published'] = port
            self.assertNotEqual(self.run_config(value).returncode, 0, port)
        value = config(); value['services']['nginx']['ports'][0]['host_ip'] = '0.0.0.0'
        self.assertNotEqual(self.run_config(value).returncode, 0)


class RestoreSafetyTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='setting-hardening-')
        self.base = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def shell(self, source, *args):
        values = [posix(ROOT), *map(posix, args)]
        env = {**os.environ, **{f'CASE_{i}': value for i, value in enumerate(values)}}
        # Avoid Git Bash's Windows command-line quote rewriting for hostile URL fixtures.
        setup = 'set -- ' + ' '.join(f'"$CASE_{i}"' for i in range(len(values))) + '\n'
        code = setup + 'set -euo pipefail\nsource "$1/scripts/lib/runtime.sh"\n' + source
        return subprocess.run([BASH, '-c', code], env=env, capture_output=True, text=True)

    def test_path_guard_rejects_root_parent_symlink_and_allows_child(self):
        child = self.base / 'child'; child.mkdir()
        good = self.shell('require_child "$2" "$3"', self.base, child)
        self.assertEqual(good.returncode, 0, good.stderr)
        for unsafe in [self.base, self.base.parent]:
            self.assertNotEqual(self.shell('require_child "$2" "$3"', self.base, unsafe).returncode, 0)
        try:
            (self.base / 'link').symlink_to(self.base.parent, target_is_directory=True)
        except OSError:
            return
        self.assertNotEqual(self.shell('require_child "$2" "$3"', self.base, self.base/'link').returncode, 0)

    def test_completion_marker_requires_matching_inputs_and_complete_tree(self):
        extraction = self.base / 'extract'; extraction.mkdir()
        (extraction/'wp-content').mkdir(); (extraction/'dup-installer').mkdir()
        (extraction/'.complete').write_text('hash-a\n', newline='\n')
        self.assertEqual(self.shell('extraction_complete "$2" hash-a', extraction).returncode, 0)
        self.assertNotEqual(self.shell('extraction_complete "$2" hash-b', extraction).returncode, 0)
        (extraction/'.complete').unlink()
        self.assertNotEqual(self.shell('extraction_complete "$2" hash-a', extraction).returncode, 0)

    def test_healthy_redirect_cannot_pass_restore_verification(self):
        code = 'curl() { printf 302; }; verify_origin 9876 https://example.test'
        result = self.shell(code)
        self.assertNotEqual(result.returncode, 0)

    def test_healthy_200_passes_restore_verification(self):
        code = 'curl() { printf 200; }; verify_origin 9876 https://example.test'
        result = self.shell(code)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_url_validation_blocks_shell_metacharacters(self):
        self.assertEqual(self.shell('validate_url https://example.test').returncode, 0)
        for url in ["https://example.test/'x", 'https://x.test/$(id)', 'file:///tmp/a', 'https://x.test/a;id']:
            result = self.shell('validate_url "$2"', url)
            self.assertNotEqual(result.returncode, 0, url)


class BootstrapTests(unittest.TestCase):
    @unittest.skipIf(os.name=='nt', 'requires Unix directory permission bits')
    def test_new_html_directory_is_traversable_by_nginx_uid(self):
        with tempfile.TemporaryDirectory(prefix='setting-bootstrap-perms-') as directory:
            project=Path(directory)
            shutil.copytree(ROOT/'scripts',project/'scripts')
            shutil.copy(ROOT/'docker-compose.yml',project/'docker-compose.yml')
            (project/'.env').write_text('NGINX_PORT=9876\n')
            value=config()
            for service in ['wordpress','wpcli','nginx']: value['services'][service]['volumes'][0]['source']=str(project/'html')
            config_path=project/'config.json'; config_path.write_text(json.dumps(value))
            code='''docker() { if [[ "$*" == *"config --format json"* ]]; then cat "$MOCK_CONFIG"; fi; return 0; }
export -f docker
bash "$MOCK_PROJECT/scripts/bootstrap-wordpress.sh"
'''
            result=subprocess.run([BASH,'-c',code],env={**os.environ,'MOCK_CONFIG':str(config_path),
                                  'MOCK_PROJECT':str(project)},capture_output=True,text=True)
            self.assertEqual(result.returncode,0,result.stderr)
            self.assertEqual((project/'html').stat().st_mode & 0o755,0o755)

    def test_unready_compose_does_not_report_success(self):
        with tempfile.TemporaryDirectory(prefix='setting-bootstrap-') as directory:
            project = Path(directory)
            shutil.copytree(ROOT/'scripts', project/'scripts')
            shutil.copy(ROOT/'docker-compose.yml', project/'docker-compose.yml')
            (project/'.env').write_text('NGINX_PORT=9876\n')
            value=config()
            for service in ['wordpress','wpcli','nginx']: value['services'][service]['volumes'][0]['source']=str(project/'html')
            config_path = project/'mock-config.json'; config_path.write_text(json.dumps(value))
            command = '''set -e
docker() {
  if [[ "$*" == *"config --format json"* ]]; then cat "$MOCK_CONFIG";
  elif [[ "$*" == *"up -d --wait"* ]]; then return 1;
  else return 0; fi
}
python3() { "$TEST_PYTHON" "$@"; }
export -f docker python3
bash "$1/scripts/bootstrap-wordpress.sh"
'''
            env = {**os.environ, 'MOCK_CONFIG': posix(config_path), 'TEST_PYTHON': posix(sys.executable)}
            result = subprocess.run([BASH, '-c', command, 'test', posix(project)], env=env,
                                    capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0, result.stdout)


class RestoreFailureTrapTests(unittest.TestCase):
    def test_partial_start_failure_really_stops_web(self):
        text = (ROOT/'scripts/restore-from-duplicator.sh').read_text()
        start = text.index('finish() {')
        end = text.index('trap finish EXIT', start)
        function = text[start:end]
        code = '''warn() { printf '%s\\n' "$*"; }
docker() { printf 'STOP_CALLED:%s\\n' "$*"; }
BACKUP_DIR=/mock/backup; EXTRACT_DIR=/mock/extract; WEB_STOPPED=1
''' + function + '\ntrap finish EXIT\nexit 7\n'
        result = subprocess.run([BASH, '-c', code],capture_output=True,text=True)
        self.assertEqual(result.returncode, 7)
        self.assertIn('STOP_CALLED:compose stop nginx wordpress', result.stdout)

    def test_failed_stop_is_reported_as_unconfirmed(self):
        text = (ROOT/'scripts/restore-from-duplicator.sh').read_text()
        function = text[text.index('finish() {'):text.index('trap finish EXIT')]
        code = '''warn() { printf '%s\\n' "$*"; }
docker() { return 1; }
BACKUP_DIR=/mock/backup; EXTRACT_DIR=/mock/extract; WEB_STOPPED=1
''' + function + '\ntrap finish EXIT\nexit 7\n'
        result = subprocess.run([BASH, '-c', code],capture_output=True,text=True)
        self.assertEqual(result.returncode, 7)
        self.assertIn('Could not confirm', result.stdout)


if __name__ == '__main__':
    unittest.main()
