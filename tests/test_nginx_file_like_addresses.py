"""An address that only looks like a static file must not reach WordPress (2026-11-20).

A Cloudflare challenge rule leaves static extensions unchallenged. "/index.php;.txt?rest_route=/wp/v2/..." has the
extension txt for that rule, is no file for nginx, so `try_files $uri $uri/ /index.php?$args` hands it to WordPress,
and WordPress answers rest_route on any path. "/robots.txt?rest_route=..." and "/sitemap_index.xml?rest_route=..."
reached the REST API the same way. The site's server block refuses these shapes before any location is chosen.
The regular expressions are copied out of the configuration and run here against the addresses seen in the scan."""
import pathlib
import re
import unittest

CONF = pathlib.Path(__file__).resolve().parents[1] / 'nginx' / 'conf.d' / 'wordpress.conf'


class FileLikeAddresses(unittest.TestCase):
    def setUp(self):
        text = CONF.read_text(encoding='utf-8')
        servers = [m.start() for m in re.finditer(r'^server \{', text, re.M)]
        self.site = text[servers[0]:servers[1]]
        self.block = self.site[self.site.index('# BEGIN xr-file-like-addresses'):self.site.index('# END xr-file-like-addresses')]
        self.ext = re.compile(re.search(r'if \(\$uri ~\* "([^"]+)"\) \{ set \$xr_file_like "f"; \}', self.block).group(1), re.I)
        self.arg = re.compile(re.search(r'if \(\$args ~\* "([^"]+)"\) \{ set \$xr_file_like "\$\{xr_file_like\}r"; \}', self.block).group(1), re.I)

    def refused(self, uri, args=''):
        """What the block does with a decoded path and a raw query string."""
        if ';' in uri:
            return True
        return bool(self.ext.search(uri)) and bool(self.arg.search(args))

    def test_block_runs_before_the_sitemap_rewrites_and_before_any_location(self):
        self.assertLess(self.site.index('# BEGIN xr-file-like-addresses'), self.site.index('# BEGIN xr-rankmath-sitemap'))
        self.assertLess(self.site.index('# END xr-file-like-addresses'), self.site.index('  location '))
        self.assertIn('if ($uri ~ ";") { return 404; }', self.block)
        self.assertIn('if ($xr_file_like = "fr") { return 404; }', self.block)
        self.assertIn('set $xr_file_like "";', self.block)

    def test_addresses_seen_in_the_scan_are_refused(self):
        # nginx decodes %3B before $uri is compared, so both spellings arrive here as ";"
        self.assertTrue(self.refused('/index.php;.txt', 'rest_route=/wc/store/v1/checkout'))
        self.assertTrue(self.refused('/wp-login.php;.txt'))
        self.assertTrue(self.refused('/robots.txt', 'rest_route=/wp/v2/types'))
        self.assertTrue(self.refused('/sitemap_index.xml', 'rest_route=/wp/v2/users'))
        self.assertTrue(self.refused('/a/b/photo.JPG', 'x=1&rest_route=/wp/v2/users'))
        self.assertTrue(self.refused('/llms.txt', 'REST_ROUTE=/'))

    def test_spellings_php_reads_as_rest_route(self):
        for query in ('rest.route=/', 'rest+route=/', 'rest%20route=/', 'rest%5Broute=/', 'rest[route=/', 'rest%2Eroute=/',
                      'rest%5Froute=/', 'a=1&rest.route=/', '+rest_route=/', '%20rest_route=/'):
            self.assertTrue(self.refused('/robots.txt', query), query)

    def test_ordinary_addresses_pass(self):
        for uri, args in (('/', 'rest_route=/wc/store/v1/cart'), ('/index.php', 'rest_route=/wp/v2/posts'), ('/wp-json/wc/store/v1/checkout', ''),
                          ('/robots.txt', ''), ('/sitemap_index.xml', ''), ('/product-sitemap2.xml', ''), ('/llms.txt', ''),
                          ('/wp-content/themes/x/style.css', 'ver=8.6.8'), ('/wp-includes/js/jquery/jquery.min.js', 'ver=3.7.1'),
                          ('/shop/some-product/', 'a=1;b=2'), ('/en/', 'rest_route=/'), ('/wp-admin/admin-ajax.php', 'action=x&forest_routes=1'),
                          ('/robots.txt', 'interest_router=1'), ('/feed.xml', 'arrest=1&route=2')):
            self.assertFalse(self.refused(uri, args), (uri, args))

    def test_extension_list_covers_what_the_edge_rule_leaves_unchallenged(self):
        for ext in ('css', 'js', 'mjs', 'map', 'woff', 'woff2', 'ttf', 'otf', 'eot', 'svg', 'png', 'jpg', 'jpeg', 'gif', 'webp',
                    'avif', 'ico', 'bmp', 'mp4', 'webm', 'txt', 'xml'):
            self.assertTrue(self.ext.search('/x.' + ext), ext)
        self.assertFalse(self.ext.search('/index.php'))
        self.assertFalse(self.ext.search('/shop/'))


if __name__ == '__main__':
    unittest.main()
