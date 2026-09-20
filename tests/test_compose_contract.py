"""Offline checks for the template's image and readiness contracts."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]


def service_block(name):
    document = (ROOT/'docker-compose.yml').read_text()
    return re.search(r'^  ' + name + r':\n(.*?)(?=^  \w+:|\Z)',
                     document, re.MULTILINE | re.DOTALL).group(1)


class ComposeContractTests(unittest.TestCase):
    def test_runtime_images_are_digest_pinned_without_version_change(self):
        for service, tag in [('nginx', 'nginx:1.27-alpine'),
                             ('db', 'mysql:8.4.8'), ('redis', 'redis:7-alpine')]:
            image = re.search(r'^    image: (\S+)$', service_block(service), re.MULTILINE).group(1)
            self.assertRegex(image, '^' + re.escape(tag) + r'@sha256:[0-9a-f]{64}$')

    def test_nginx_timeout_covers_both_sequential_http_probes(self):
        block = service_block('nginx')
        probes = [int(value) for value in re.findall(r'wget -T (\d+)', block)]
        self.assertEqual(len(probes), 2)
        timeout = int(re.search(r'^      timeout: (\d+)s$', block, re.MULTILINE).group(1))
        self.assertGreaterEqual(timeout, sum(probes) + 2)
