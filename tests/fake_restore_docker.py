"""Docker boundary for restore regression tests. Only operates on the test's private fixture."""
import json
import os
from pathlib import Path
import sys

root = Path(os.environ['MOCK_PROJECT'])
args = sys.argv[1:]
with (root/'calls.jsonl').open('a') as output:
    output.write(json.dumps(args)+'\n')
scenario = os.environ.get('MOCK_FAILURE', '')
if args[:4] == ['compose','config','--format','json']:
    print((root/'config.json').read_text())
elif args[:4] == ['compose','ps','-q','wordpress']:
    print('fixture-wordpress')
elif args[0] == 'inspect':
    print(str(root/'html'))
elif 'mysqldump' in ' '.join(args):
    if scenario == 'backup': sys.exit(3)
    print('-- mock consistent database backup\nCREATE TABLE backup_fixture(id int);')
elif args[:4] == ['compose','exec','-T','db']:
    query=sys.stdin.read()
    print('fixture-db\twordpress' if '@@server_uuid' in query else ('3' if 'COUNT(*)' in query else '1'))
elif args and args[0] == 'run' and '/extract.php' in args:
    mount=next(arg for arg in args if arg.endswith(':/output'))
    target=Path(mount[:-8]); (target/'dup-installer').mkdir(parents=True)
    (target/'wp-content').mkdir()
    (target/'wp-content/new.txt').write_text('new restored content')
    (target/'dup-installer/dup-database__fixture.sql').write_text(
        'CREATE TABLE `wp_options` (id int);\nINSERT INTO `wp_options` VALUES (1);\n')
elif 'wpcli' in args:
    command=args[args.index('wpcli')+1:]
    if command[:4] == ['wp','config','get','table_prefix']: print('wp_')
    elif command[:3] == ['wp','db','query'] and '@@server_uuid' in ' '.join(command):
        print(('other-db' if scenario=='identity' else 'fixture-db')+'\twordpress')
    elif command[:3] == ['wp','db','import'] and scenario == 'import': sys.exit(4)
    elif command[:3] == ['wp','option','get']: print('https://new.example.test')
elif args[:3] == ['compose','up','-d'] and scenario == 'start':
    sys.exit(5)
