"""Whole-script regression with real filesystem/tar/hash work and a fake Docker boundary."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

from test_hardening import ROOT, BASH, config


@unittest.skipIf(os.name=='nt', 'Linux filesystem/ownership integration; run in isolated Linux checkout')
class RestoreFlowTests(unittest.TestCase):
    def run_flow(self, failure):
        temp=tempfile.TemporaryDirectory(prefix='setting-restore-flow-')
        self.addCleanup(temp.cleanup)
        project=Path(temp.name)
        for directory in ['scripts','nginx','php']:
            shutil.copytree(ROOT/directory,project/directory)
        shutil.copy(ROOT/'docker-compose.yml',project/'docker-compose.yml')
        (project/'html/wp-content').mkdir(parents=True)
        (project/'html/wp-content/old.txt').write_text('original content')
        (project/'.env').write_text('mock credentials; never interpreted as shell')
        (project/'archive.daf').write_text('trusted archive fixture')
        (project/'installer.php').write_text('trusted installer fixture')
        value=config(); value['name']='fixture'
        for service in ['wordpress','wpcli','nginx']:
            value['services'][service]['volumes'][0]['source']=str(project/'html')
        (project/'config.json').write_text(json.dumps(value))
        env={**os.environ,'MOCK_PROJECT':str(project),'MOCK_FAILURE':failure,
             'MOCK_DOCKER':str(ROOT/'tests/fake_restore_docker.py'), 'TEST_PYTHON':sys.executable,
             'NEW_URL':'https://new.example.test','OLD_URL':'https://old.example.test',
             'MAINTENANCE_CONFIRMED':'1','SKIP_CONFIRM':'1','FORCE':'1'}
        shell='''docker() { "$TEST_PYTHON" "$MOCK_DOCKER" "$@"; }
curl() { if [[ "$MOCK_FAILURE" == http ]]; then printf 302; else printf 200; fi; }
# Only UID ownership is skipped: changing host fixture ownership is not part of these regressions.
chown() { return 0; }
export -f docker curl chown
bash "$MOCK_PROJECT/scripts/restore-from-duplicator.sh" "$MOCK_PROJECT/archive.daf" "$MOCK_PROJECT/installer.php"
'''
        result=subprocess.run([BASH,'-c',shell],env=env,capture_output=True,text=True,timeout=30)
        calls=[json.loads(x) for x in (project/'calls.jsonl').read_text().splitlines()]
        return project,result,calls

    def test_success_retains_snapshot_archive_and_completion_marker(self):
        project,result,calls=self.run_flow('')
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertEqual(len(list((project/'.restore-backups').glob('*/.restore-complete'))),1)
        self.assertTrue((project/'archive.daf').exists())
        self.assertTrue((project/'installer.php').exists())
        self.assertTrue((project/'html/wp-content/new.txt').exists())

    def test_backup_failure_never_replaces_files_or_resets_database(self):
        project,result,calls=self.run_flow('backup')
        self.assertNotEqual(result.returncode,0)
        self.assertTrue((project/'html/wp-content/old.txt').exists())
        self.assertFalse(any('reset' in call for call in calls))
        self.assertNotIn('RESTORE COMPLETE:',result.stdout)

    def test_actual_cli_database_identity_mismatch_stops_before_backup_or_reset(self):
        project,result,calls=self.run_flow('identity')
        self.assertNotEqual(result.returncode,0)
        self.assertTrue((project/'html/wp-content/old.txt').exists())
        self.assertFalse(any('reset' in call or 'stop' in call for call in calls))
        self.assertFalse((project/'.restore-backups').exists())

    def test_import_failure_keeps_recovery_snapshot_and_web_stopped(self):
        project,result,calls=self.run_flow('import')
        self.assertNotEqual(result.returncode,0)
        self.assertEqual(len(list((project/'.restore-backups').glob('*/.snapshot-complete'))),1)
        self.assertFalse(list((project/'.restore-backups').glob('*/.restore-complete')))
        self.assertEqual(calls[-1],['compose','stop','nginx','wordpress'])

    def test_partial_start_and_redirect_fail_closed(self):
        for failure in ['start','http']:
            with self.subTest(failure=failure):
                project,result,calls=self.run_flow(failure)
                self.assertNotEqual(result.returncode,0)
                self.assertEqual(calls[-1],['compose','stop','nginx','wordpress'])
                self.assertFalse(list((project/'.restore-backups').glob('*/.restore-complete')))


if __name__=='__main__': unittest.main()
