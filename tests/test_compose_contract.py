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
        for service, tag in [('nginx', 'nginx:1.30-alpine'),
                             ('db', 'mysql:8.4.13'), ('redis', 'redis:8.10.2-alpine3.23')]:
            image = re.search(r'^    image: (\S+)$', service_block(service), re.MULTILINE).group(1)
            self.assertRegex(image, '^' + re.escape(tag) + r'@sha256:[0-9a-f]{64}$')

    def test_nginx_timeout_covers_both_sequential_http_probes(self):
        block = service_block('nginx')
        probes = [int(value) for value in re.findall(r'wget -T (\d+)', block)]
        self.assertEqual(len(probes), 2)
        timeout = int(re.search(r'^      timeout: (\d+)s$', block, re.MULTILINE).group(1))
        self.assertGreaterEqual(timeout, sum(probes) + 2)


def ini_values(name):
    values = {}
    for line in (ROOT/'php'/name).read_text().splitlines():
        line = line.split(';', 1)[0].strip()
        if '=' in line:
            key, value = (part.strip() for part in line.split('=', 1))
            values[key] = value
    return values


class PhpRuntimeContractTests(unittest.TestCase):
    def test_opcache_is_sized_for_woocommerce_multilingual_stacks(self):
        opcache = ini_values('opcache.ini')
        memory = int(opcache['opcache.memory_consumption'])
        interned = int(opcache['opcache.interned_strings_buffer'])
        self.assertGreaterEqual(memory, 512)
        self.assertEqual(interned, 128)
        # interned strings are carved out of memory_consumption: scripts keep at least half
        self.assertLessEqual(interned * 2, memory)
        self.assertGreaterEqual(int(opcache['opcache.max_accelerated_files']), 20000)

    def test_opcache_keeps_timestamp_validation_and_jit_off(self):
        opcache = ini_values('opcache.ini')
        self.assertEqual((opcache['opcache.validate_timestamps'], opcache['opcache.revalidate_freq']), ('1', '60'))
        self.assertEqual((opcache['opcache.jit'], opcache['opcache.jit_buffer_size']), ('0', '0'))
