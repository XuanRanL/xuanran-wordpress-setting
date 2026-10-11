"""The nginx template serves Rank Math's sitemap routes itself (2026-10-11).

A WordPress rewrite-rule rebuild inside a Heartbeat request (Rank Math loads no modules there) saved the rules without
Rank Math's routes and /sitemap_index.xml answered 404 for a day (camelliapour 2026-10-10, verdacre 2026-09-28). The
template's managed block passes the same query vars to WordPress directly, so the stored rules no longer matter."""
import pathlib
import re
import unittest

CONF = pathlib.Path(__file__).resolve().parents[1] / 'nginx' / 'conf.d' / 'wordpress.conf'
# Rank Math 1.0.280 includes/modules/sitemap/class-router.php (sitemap base empty, index slug "sitemap_index").
RANK_MATH = [
    ('sitemap_index\\.xml$', 'index.php?sitemap=1'),
    ('([^/]+?)-sitemap([0-9]+)?\\.xml$', 'index.php?sitemap=$matches[1]&sitemap_n=$matches[2]'),
    ('([a-z]+)?-?sitemap\\.xsl$', 'index.php?xsl=$matches[1]'),
]


class SitemapRoutes(unittest.TestCase):
    def setUp(self):
        self.text = CONF.read_text(encoding='utf-8')
        servers = [m.start() for m in re.finditer(r'^server \{', self.text, re.M)]
        self.first = self.text[servers[0]:servers[1]]

    def block(self):
        m = re.search(r'^ *# BEGIN xr-rankmath-sitemap.*?^ *# END xr-rankmath-sitemap\n', self.first, re.M | re.S)
        self.assertIsNotNone(m, 'managed block missing from the main server block')
        return m

    def test_block_follows_index_line(self):
        m = self.block()
        self.assertTrue(self.first[:m.start()].rstrip().endswith('index index.php;'))
        self.assertEqual(self.text.count('# BEGIN xr-rankmath-sitemap'), 1)

    def test_rewrites_mirror_rank_math_rules(self):
        rules = re.findall(r'^ *rewrite (\S+) (\S+) last;$', self.block().group(0), re.M)
        self.assertEqual(len(rules), len(RANK_MATH))
        for (rx, to), (wp_rx, wp_q) in zip(rules, RANK_MATH):
            self.assertEqual(rx, '^/' + wp_rx)
            self.assertEqual(to, '/' + re.sub(r'\$matches\[(\d)\]', r'$\1', wp_q))

    def test_paths(self):
        rules = [re.compile(rx) for rx, _ in re.findall(r'^ *rewrite (\S+) (\S+) last;$', self.block().group(0), re.M)]
        hit = lambda p: [i for i, r in enumerate(rules) if r.match(p)]
        self.assertEqual(hit('/sitemap_index.xml'), [0])
        self.assertEqual(hit('/product-sitemap3.xml'), [1])
        self.assertEqual(hit('/main-sitemap.xsl'), [2])
        for p in ('/sitemap.xml', '/shop/', '/a/post-sitemap.xml', '/sitemap_index.xml.bak', '/robots.txt'):
            self.assertEqual(hit(p), [], p)


if __name__ == '__main__':
    unittest.main()
