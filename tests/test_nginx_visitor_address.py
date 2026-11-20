"""PHP gets the visitor's address from nginx, not from a header the visitor wrote (2026-11-20).

WooCommerce reads X-Real-IP and X-Forwarded-For before REMOTE_ADDR for the address it stores on an order. A script
that placed 42 unpaid orders on a fleet store in an hour could have sent a different X-Real-IP with each of them and
every per-address limit would have counted one order per "visitor". The template therefore hands PHP its own
$remote_addr (already corrected by the real-ip module) under that header's name in every WordPress PHP location."""
import pathlib
import re
import unittest

CONF_DIR = pathlib.Path(__file__).resolve().parents[1] / 'nginx' / 'conf.d'
CONF = CONF_DIR / 'wordpress.conf'
PARAM = 'fastcgi_param HTTP_X_REAL_IP $remote_addr;'


class VisitorAddress(unittest.TestCase):
    def setUp(self):
        self.text = CONF.read_text(encoding='utf-8')
        servers = [m.start() for m in re.finditer(r'^server \{', self.text, re.M)]
        self.site = self.text[servers[0]:servers[1]]

    def php_locations(self):
        # Every location of the site's server block that hands a request to PHP-FPM.
        blocks = re.findall(r'^  location [^\n]*\{\n(?:(?!^  \}).*\n)*?^  \}', self.site, re.M)
        return [b for b in blocks if 'fastcgi_pass' in b]

    def test_every_php_location_passes_nginx_own_address(self):
        locations = self.php_locations()
        self.assertGreaterEqual(len(locations), 2, 'expected the long-running and the generic PHP location')
        for block in locations:
            self.assertIn(PARAM, block, block.splitlines()[0])
            self.assertEqual(block.count('HTTP_X_REAL_IP'), 1, block.splitlines()[0])

    def test_address_is_not_taken_from_a_request_header(self):
        for block in self.php_locations():
            self.assertNotRegex(block, r'HTTP_X_REAL_IP\s+\$http_', block.splitlines()[0])
            self.assertNotRegex(block, r'HTTP_X_FORWARDED_FOR\s+\$http_', block.splitlines()[0])

    def test_real_ip_module_reads_cloudflares_header_from_trusted_peers_only(self):
        realip = (CONF_DIR / 'cloudflare-realip.conf').read_text(encoding='utf-8')
        self.assertIn('real_ip_header CF-Connecting-IP;', realip)
        self.assertNotRegex(realip, r'set_real_ip_from\s+0\.0\.0\.0/0')
        self.assertNotRegex(realip, r'set_real_ip_from\s+::/0')


if __name__ == '__main__':
    unittest.main()
