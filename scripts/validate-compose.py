#!/usr/bin/env python3
"""Validate resolved Compose JSON from stdin; emit only the nginx port, never secrets.

Compose performs .env quoting/interpolation itself. Do not source .env as shell code.
Compatible with existing per-site Compose files using the standard service names.
"""
import json
import argparse
from pathlib import Path
import shlex
import sys


def required(env, name):
    value = str(env.get(name) or '')
    if not value or value.lower().startswith(('change_me', 'changeme', 'your_password', '<')):
        raise ValueError(f'{name} is missing or still a placeholder')
    return value


def networks(service):
    value = service.get('networks') or {'default': None}
    return value if isinstance(value, dict) else {name: None for name in value}


def database_port(db):
    command = db.get('command') or []
    if isinstance(command, str):
        command = shlex.split(command)
    port = '3306'
    for index, word in enumerate(command):
        if word.startswith('--port='):
            port = word.split('=', 1)[1]
        elif word == '--port':
            port = command[index + 1]
    if not str(port).isascii() or not str(port).isdecimal() or not 1 <= int(port) <= 65535:
        raise ValueError('db service has an invalid MySQL port')
    return int(port)


def validate(document, project_root=None):
    services = document['services']
    db = services['db'].get('environment') or {}
    required(db, 'MYSQL_ROOT_PASSWORD')
    root = Path(project_root or Path.cwd()).resolve()
    expected_html = (root/'html').resolve()
    if expected_html.parent != root:
        raise ValueError('project html directory escapes the project root')
    db_networks = networks(services['db'])
    db_port = database_port(services['db'])
    for service_name in ('wordpress', 'wpcli', 'nginx'):
        volumes = services[service_name].get('volumes', [])
        if any(m.get('target', '').rstrip('/').startswith('/var/www/html/') for m in volumes):
            raise ValueError(f'{service_name} has a nested document-root mount outside the snapshot boundary')
        mounts = [m for m in volumes if m.get('target', '').rstrip('/') == '/var/www/html']
        if len(mounts) != 1 or mounts[0].get('type') != 'bind' or Path(mounts[0].get('source', '')).resolve() != expected_html:
            raise ValueError(f'{service_name} must bind this project html directory at /var/www/html')
    for service_name in ('wordpress', 'wpcli'):
        service = services[service_name]
        app_env = service.get('environment') or {}
        for app, mysql in [('WORDPRESS_DB_NAME', 'MYSQL_DATABASE'), ('WORDPRESS_DB_USER', 'MYSQL_USER'),
                           ('WORDPRESS_DB_PASSWORD', 'MYSQL_PASSWORD')]:
            if required(app_env, app) != required(db, mysql):
                raise ValueError(f'{service_name} {app} and db {mysql} disagree')
        shared = set(networks(service)) & set(db_networks)
        aliases = {'db'} if shared else set()
        for network in shared:
            aliases.update((db_networks[network] or {}).get('aliases') or [])
        host, separator, port = required(app_env, 'WORDPRESS_DB_HOST').partition(':')
        if host not in aliases or (separator and port != str(db_port)) or (not separator and db_port != 3306):
            raise ValueError(f'{service_name} DB_HOST must identify the db service on its shared network and MySQL port')
    ports = [p for p in services['nginx'].get('ports', []) if str(p.get('target')) == '80']
    if len(ports) != 1:
        raise ValueError('nginx must publish exactly one port for container port 80')
    port = ports[0]
    if port.get('host_ip') != '127.0.0.1':
        raise ValueError('nginx port 80 must bind to 127.0.0.1')
    value = str(port.get('published') or '')
    if not value.isascii() or not value.isdecimal() or not 1 <= int(value) <= 65535:
        raise ValueError('nginx published port must be an integer from 1 to 65535')
    return str(int(value))


if __name__ == '__main__':
    try:
        parser = argparse.ArgumentParser(description=__doc__)
        parser.add_argument('--project-root', default=str(Path.cwd()))
        parser.add_argument('--wpcli-image', action='store_true')
        arguments = parser.parse_args()
        document = json.load(sys.stdin)
        port = validate(document, arguments.project_root)
        if arguments.wpcli_image:
            cli = document['services']['wpcli']
            image = cli.get('image') or (document['name'] + '-wpcli')
            print(image)
        else:
            print(port)
    except (ValueError, KeyError, IndexError, TypeError, AttributeError) as error:
        print(f'ERROR: invalid Compose configuration: {error}', file=sys.stderr)
        sys.exit(1)
