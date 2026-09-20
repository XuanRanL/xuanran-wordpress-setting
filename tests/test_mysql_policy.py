import os
from pathlib import Path
import shutil
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]
BASH = shutil.which('bash') if os.name != 'nt' else 'C:/Program Files/Git/bin/bash.exe'


class MysqlPolicyTests(unittest.TestCase):
    def eligible(self, *args, defaults=True):
        if defaults:
            args = ('--no-defaults', *args)
        # Pass arguments as process arguments, never build shell code from them.
        result = subprocess.run([BASH, '-c', '. "$POLICY_PATH"; local_mysql_tls_policy "$@"',
                                 'test', *args],
                                env={**os.environ, 'MYSQL_TCP_PORT': '3306',
                                     'POLICY_PATH': str(ROOT/'php/mysql-client-policy.sh').replace('\\', '/')},
                                capture_output=True, text=True)
        self.assertIn(result.returncode, (0, 1), result.stderr)
        return result.returncode == 0

    def test_standard_compose_host(self):
        for args in [('--host=db',), ('-h', 'db', '-P3306'),
                     ('--host', 'db', '--port=3306', '--protocol=tcp'),
                     ('--no-defaults', '--host=db', '--batch')]:
            self.assertTrue(self.eligible(*args), args)
        self.assertFalse(self.eligible('--host=db', defaults=False))
        self.assertTrue(self.eligible('--no-auto-rehash', '--batch', '--skip-column-names',
                                      '--execute=SELECT @@SESSION.sql_mode', '--host=db', '--user=wordpress'))

    def test_external_or_ambiguous_connection_is_unchanged(self):
        for args in [(), ('--host=external',), ('--host=db', '--port=3307'),
                     ('--host=db', '--host=other'), ('--host=db', '--socket=/tmp/mysql.sock'),
                     ('--host=db', '--defaults-file=/tmp/client.cnf'),
                     ('--host=db', '--defaults-extra-file=/tmp/client.cnf'),
                     ('--host=db', '--protocol=socket')]:
            self.assertFalse(self.eligible(*args), args)

    def test_explicit_tls_options_always_win(self):
        for option in ['--ssl', '--skip-ssl', '--ssl-verify-server-cert',
                       '--skip-ssl-verify-server-cert', '--skip_ssl_verify_server_cert', '--ssl-ca=/tmp/ca.pem',
                       '--ssl-cert=/tmp/client.pem', '--tls-version=TLSv1.3']:
            self.assertFalse(self.eligible('--host=db', option), option)

    def test_aliases_unknown_options_and_option_values_cannot_change_scope(self):
        for args in [('--host=db', '--loose-host=external'),
                     ('--host=db', '--loose-port=3307'),
                     ('--host=db', '--loose-ssl-verify-server-cert'),
                     ('--host=db', '--hos=external'), ('--host=db', '--por=3307'),
                     ('--execute', '--host=db'), ('--user', '--host=db'),
                     ('--host=db', '--unknown-option'), ('-uh', 'db')]:
            self.assertFalse(self.eligible(*args), args)
        self.assertTrue(self.eligible('--host=db', '--execute', '--host=external', '--user=wordpress'))
