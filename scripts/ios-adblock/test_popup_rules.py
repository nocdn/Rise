import importlib.util
from pathlib import Path
import re
import unittest

spec = importlib.util.spec_from_file_location('popup_rules', Path(__file__).with_name('popup_rules.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class PopupRuleTests(unittest.TestCase):
    def matches(self, pattern, url):
        return re.search(module.pattern_regex(pattern), url, re.I) is not None

    def test_domain_anchors_and_separator_boundaries(self):
        for url in ['https://ads.example/', 'http://sub.ads.example:80/ad', 'https://ads.example?x=1']:
            self.assertTrue(self.matches('||ads.example^', url), url)
        for url in ['https://notads.example/', 'https://ads.example.evil/', 'https://safe.test/ads.example/', 'https://safe.test/?u=https://ads.example/']:
            self.assertFalse(self.matches('||ads.example^', url), url)

    def test_wildcards_exact_anchors_and_raw_regex(self):
        self.assertEqual(module.pattern_regex(''), '.*', 'ICU rejects an empty regex; an empty filter matches every popup')
        self.assertTrue(self.matches('|https://example.com/ad*|', 'https://example.com/advert'))
        self.assertFalse(self.matches('|https://example.com/ad|', 'https://example.com/advert'))
        self.assertTrue(self.matches('/^https?:\\/\\/ads[0-9]+\\.test\\//', 'https://ads12.test/'))

    def test_scopes_exceptions_case_and_party(self):
        rules = module.extract(['||ads.test^$popup,third-party,domain=example.com|~safe.example.com',
                                '@@||ads.test/good$popup,match-case', '||resource.test^$script'])
        self.assertEqual(len(rules), 2)
        self.assertEqual(rules[0]['include'], ['example.com'])
        self.assertEqual(rules[0]['exclude'], ['safe.example.com'])
        self.assertEqual(rules[0]['party'], 1)
        self.assertTrue(rules[1]['exception'])
        self.assertTrue(rules[1]['matchCase'])

    def test_badfilter_cancels_regardless_of_modifier_order(self):
        rules = module.extract(['||ads.test^$popup,third-party',
                                '||ads.test^$third-party,badfilter,popup',
                                '||kept.test^$popup', '||kept.test^$popup'])
        self.assertEqual(len(rules), 1)
        self.assertIn('kept', rules[0]['pattern'])

    def test_unknown_modifiers_fail_instead_of_silently_broadening(self):
        with self.assertRaises(ValueError):
            module.extract(['||ads.test^$popup,unsupported=scope'])

    def test_every_pinned_popup_filter_is_understood_and_compiles(self):
        sources = sorted((module.ROOT / 'Filters/iOS/Sources').glob('*.txt'))
        rules = module.extract(line for p in sources for line in p.read_text().splitlines())
        self.assertGreater(len(rules), 3000)
        self.assertGreater(sum(r['exception'] for r in rules), 60)
        for rule in rules:
            re.compile(rule['pattern'])


if __name__ == '__main__':
    unittest.main()
