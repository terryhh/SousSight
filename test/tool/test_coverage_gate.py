"""Tests for tool/coverage/coverage_gate.py (SS-088).

Run: python3 -m unittest discover -s test/tool -p 'test_*.py'
Each test builds a throwaway repository tree; nothing touches the real one.
"""

import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / 'tool/coverage/coverage_gate.py'


def lcov(records):
    """records: {path: {line: hits}} -> lcov text in Flutter's format."""
    chunks = []
    for path, lines in records.items():
        body = [f'SF:{path}'] + [f'DA:{line},{hits}' for line, hits in lines.items()]
        body += [f'LF:{len(lines)}', f'LH:{sum(1 for h in lines.values() if h)}', 'end_of_record']
        chunks.append('\n'.join(body))
    return '\n'.join(chunks) + '\n'


def hits(covered, missed):
    """Line map with `covered` hit lines followed by `missed` unhit lines."""
    return {i + 1: (1 if i < covered else 0) for i in range(covered + missed)}


class CoverageGateTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        self.app_lcov = self.root / 'coverage/lcov.info'
        self.plugin_lcov = self.root / 'packages/ai_logic_hybrid/coverage/lcov.info'
        self.baseline = self.root / 'tool/coverage/baseline.json'
        self.report = self.root / 'build/verify/coverage.txt'
        self.merged = self.root / 'build/verify/lcov.info'

    def tearDown(self):
        self._tmp.cleanup()

    def source(self, *paths):
        for path in paths:
            file = self.root / path
            file.parent.mkdir(parents=True, exist_ok=True)
            file.write_text('// test source\n')

    def write(self, app=None, plugin=None, baseline=None):
        if app is not None:
            self.app_lcov.parent.mkdir(parents=True, exist_ok=True)
            self.app_lcov.write_text(app if isinstance(app, str) else lcov(app))
        if plugin is not None:
            self.plugin_lcov.parent.mkdir(parents=True, exist_ok=True)
            self.plugin_lcov.write_text(plugin if isinstance(plugin, str) else lcov(plugin))
        if baseline is not None:
            self.baseline.parent.mkdir(parents=True, exist_ok=True)
            self.baseline.write_text(baseline if isinstance(baseline, str) else json.dumps(baseline))

    def gate(self, *extra):
        result = subprocess.run(
            [sys.executable, '-I', str(SCRIPT), '--root', str(self.root), *extra],
            capture_output=True, text=True, check=False)
        return result.returncode, result.stdout + result.stderr

    def minimums(self):
        return json.loads(self.baseline.read_text())['minimum_line_coverage']

    def standard(self, lib_min=80, plugin_min=50):
        self.write(app={'lib/ai/a.dart': hits(9, 1), 'lib/trust/t.dart': hits(8, 2)},
                   plugin={'lib/src/contract.dart': hits(3, 1)},
                   baseline={'minimum_line_coverage': {'lib': lib_min, 'plugin': plugin_min}})

    def test_passes_at_or_above_the_minimum_and_writes_both_reports(self):
        self.standard(lib_min=85, plugin_min=75)
        code, out = self.gate()
        self.assertEqual(code, 0, out)
        self.assertRegex(out, r'lib \(lib/\)\s+17/20\s+85\.0%\s+85%\s+pass')
        self.assertRegex(out, r'plugin \(packages/ai_logic_hybrid/lib/\)\s+3/4\s+75\.0%\s+75%\s+pass')
        self.assertIn('Gate: PASS', out)
        self.assertEqual(self.report.read_text(), out)
        merged = self.merged.read_text()
        self.assertIn('SF:packages/ai_logic_hybrid/lib/src/contract.dart', merged)
        self.assertIn('SF:lib/ai/a.dart\nDA:1,1', merged)

    def test_fails_below_the_minimum_and_names_the_root(self):
        # 17/20 = 85%; even with one line of jitter forgiven (90%) it is below 91.
        self.standard(lib_min=91)
        code, out = self.gate()
        self.assertEqual(code, 1, out)
        self.assertIn('Gate: FAIL', out)
        self.assertIn('lib: 85.0% is below the minimum 91%', out)
        self.assertNotIn('plugin: ', out.split('Gate: FAIL')[1])

    def test_one_line_of_jitter_is_forgiven_but_not_two(self):
        # 89/100 lines against a 90% minimum passes (one line short); 88/100 fails.
        for covered, expected in ((90, 0), (89, 0), (88, 1)):
            with self.subTest(covered=covered):
                self.write(app={'lib/a.dart': hits(covered, 100 - covered)},
                           plugin={'lib/p.dart': hits(1, 0)},
                           baseline={'minimum_line_coverage': {'lib': 90, 'plugin': 100}})
                code, out = self.gate()
                self.assertEqual(code, expected, out)
                if expected:
                    self.assertIn('lib: 88.0% is below the minimum 90% (even allowing 1 line', out)

    def test_plugin_root_is_gated_independently(self):
        self.write(app={'lib/ai/a.dart': hits(9, 1)}, plugin={'lib/src/contract.dart': hits(2, 2)},
                   baseline={'minimum_line_coverage': {'lib': 80, 'plugin': 76}})
        code, out = self.gate()
        self.assertEqual(code, 1, out)
        self.assertIn('plugin: 50.0% is below the minimum 76%', out)
        self.assertNotIn('lib: ', out.split('Gate: FAIL')[1])

    def test_update_baseline_raises_to_the_floor_of_the_measurement(self):
        self.write(app={'lib/ai/a.dart': hits(2, 1)}, plugin={'lib/src/c.dart': hits(7, 1)},
                   baseline={'minimum_line_coverage': {'lib': 10, 'plugin': 10}, 'note': 'keep'})
        code, out = self.gate('--update-baseline')
        self.assertEqual(code, 0, out)
        # 66.67% -> 66, 87.5% -> 87: rounded down, never up.
        self.assertEqual(self.minimums(), {'lib': 66, 'plugin': 87})
        self.assertEqual(json.loads(self.baseline.read_text())['note'], 'keep')
        self.assertIn('Baseline updated: lib 10 -> 66, plugin 10 -> 87', out)

    def test_update_baseline_never_lowers_and_still_fails(self):
        self.standard(lib_min=95, plugin_min=10)
        code, out = self.gate('--update-baseline')
        self.assertEqual(code, 1, out)
        self.assertEqual(self.minimums(), {'lib': 95, 'plugin': 75})
        self.assertIn('lib: 85.0% is below the minimum 95%', out)

    def test_missing_baseline_requires_update_flag_then_creates_it(self):
        self.write(app={'lib/a.dart': hits(1, 1)}, plugin={'lib/p.dart': hits(1, 0)})
        code, out = self.gate()
        self.assertEqual(code, 2, out)
        self.assertIn('--update-baseline', out)
        self.assertFalse(self.baseline.exists())
        code, out = self.gate('--update-baseline')
        self.assertEqual(code, 0, out)
        self.assertEqual(self.minimums(), {'lib': 50, 'plugin': 100})

    def test_missing_lcov_is_an_input_error_not_a_pass(self):
        self.write(app={'lib/a.dart': hits(1, 0)},
                   baseline={'minimum_line_coverage': {'lib': 0, 'plugin': 0}})
        code, out = self.gate()
        self.assertEqual(code, 2, out)
        self.assertIn('lcov file not found', out)
        self.assertFalse(self.report.exists())

    def test_root_without_data_fails_even_at_a_zero_minimum(self):
        self.write(app={'lib/a.dart': hits(1, 0)}, plugin='',
                   baseline={'minimum_line_coverage': {'lib': 0, 'plugin': 0}})
        code, out = self.gate()
        self.assertEqual(code, 1, out)
        self.assertIn('plugin: no coverage data', out)

    def test_update_refuses_without_data_for_every_root(self):
        self.write(app={'lib/a.dart': hits(1, 0)}, plugin='')
        code, out = self.gate('--update-baseline')
        self.assertEqual(code, 2, out)
        self.assertFalse(self.baseline.exists())

    def test_generated_and_out_of_scope_files_are_excluded(self):
        self.write(app={
            'lib/a.dart': hits(1, 0),
            'lib/firebase_options.dart': hits(0, 50),
            'lib/data/model.g.dart': hits(0, 50),
            'lib/data/model.freezed.dart': hits(0, 50),
            'test/helper.dart': hits(0, 50),
            '/somewhere/else/lib/x.dart': hits(0, 50),
        }, plugin={'lib/p.dart': hits(1, 0)},
            baseline={'minimum_line_coverage': {'lib': 100, 'plugin': 100}})
        code, out = self.gate()
        self.assertEqual(code, 0, out)
        self.assertNotIn('firebase_options', out)
        self.assertNotIn('.g.dart', self.merged.read_text())

    def test_duplicate_records_merge_by_max_hits_across_files(self):
        app = ('SF:lib/a.dart\nDA:1,0\nDA:2,0\nend_of_record\n'
               'SF:lib/a.dart\nDA:1,3\nend_of_record\n')
        self.write(app=app, plugin={'lib/p.dart': hits(1, 0)},
                   baseline={'minimum_line_coverage': {'lib': 50, 'plugin': 0}})
        code, out = self.gate()
        self.assertEqual(code, 0, out)
        self.assertRegex(out, r'lib \(lib/\)\s+1/2\s+50\.0%')

    def test_absolute_paths_inside_the_root_are_made_relative(self):
        absolute = str((self.root / 'lib/live/x.dart').resolve())
        self.write(app={absolute: hits(1, 1)}, plugin={'lib/p.dart': hits(1, 0)},
                   baseline={'minimum_line_coverage': {'lib': 0, 'plugin': 0}})
        code, out = self.gate()
        self.assertEqual(code, 0, out)
        self.assertRegex(out, r'lib/live\s+1\s+1/2\s+50\.0%')

    def test_per_area_table_lists_every_named_area_and_extra_areas(self):
        self.write(app={'lib/ai/a.dart': hits(1, 0), 'lib/genui/g.dart': hits(1, 3),
                        'lib/main.dart': hits(0, 1)},
                   plugin={'lib/p.dart': hits(1, 1)},
                   baseline={'minimum_line_coverage': {'lib': 0, 'plugin': 0}})
        code, out = self.gate()
        self.assertEqual(code, 0, out)
        for area in ('lib/ai', 'lib/trust', 'lib/watch', 'lib/pantry', 'lib/coach_lite',
                     'lib/label', 'lib/live', 'lib/learner', 'lib/data', 'plugin'):
            self.assertRegex(out, rf'(?m)^{area}\s')
        self.assertRegex(out, r'(?m)^lib/trust\s+0\s+0/0\s+-')
        self.assertRegex(out, r'(?m)^lib/genui\s+1\s+1/4\s+25\.0%')
        self.assertRegex(out, r'(?m)^lib \(top level\)\s+1\s+0/1\s+0\.0%')

    def test_bottom_list_is_sorted_lowest_first_and_limited(self):
        self.write(app={'lib/a.dart': hits(9, 1), 'lib/b.dart': hits(0, 4),
                        'lib/c.dart': hits(1, 1), 'lib/d.dart': hits(0, 9)},
                   plugin={'lib/p.dart': hits(1, 0)},
                   baseline={'minimum_line_coverage': {'lib': 0, 'plugin': 0}})
        code, out = self.gate('--bottom', '3')
        self.assertEqual(code, 0, out)
        bottom = out.split('bottom 3')[1].split('Without lcov lines')[0]
        listed = [line.split()[-1] for line in bottom.strip().splitlines()[1:]]
        # Equal coverage: more missed lines first.
        self.assertEqual(listed, ['lib/d.dart', 'lib/b.dart', 'lib/c.dart'])

    def test_files_no_test_loaded_are_listed_not_ignored(self):
        self.source('lib/a.dart', 'lib/never.dart', 'lib/firebase_options.dart',
                    'packages/ai_logic_hybrid/lib/src/web/web_only.dart')
        self.write(app={'lib/a.dart': hits(1, 0)}, plugin={'lib/p.dart': hits(1, 0)},
                   baseline={'minimum_line_coverage': {'lib': 0, 'plugin': 0}})
        code, out = self.gate()
        self.assertEqual(code, 0, out)
        unloaded = out.split('Without lcov lines')[1]
        self.assertIn('(2 files', unloaded)
        self.assertIn('lib/never.dart', unloaded)
        self.assertIn('packages/ai_logic_hybrid/lib/src/web/web_only.dart', unloaded)
        self.assertNotIn('firebase_options', unloaded)

    def test_malformed_input_exits_2(self):
        cases = [
            ('DA:1,1\n', 'DA record before SF'),
            ('SF:lib/a.dart\nDA:x,1\n', 'Malformed DA record at line 2'),
            ('SF:lib/a.dart\nDA:1,-4\n', 'Malformed DA record'),
        ]
        for text, message in cases:
            with self.subTest(text=text):
                self.write(app=text, plugin={'lib/p.dart': hits(1, 0)},
                           baseline={'minimum_line_coverage': {'lib': 0, 'plugin': 0}})
                code, out = self.gate()
                self.assertEqual(code, 2, out)
                self.assertIn(message, out)

    def test_invalid_baseline_exits_2(self):
        for baseline in ('not json', json.dumps({'minimum_line_coverage': {'lib': 50}}),
                         json.dumps({'minimum_line_coverage': {'lib': 50.5, 'plugin': 1}}),
                         json.dumps({'minimum_line_coverage': {'lib': True, 'plugin': 1}}),
                         json.dumps({'minimum_line_coverage': {'lib': 101, 'plugin': 1}}),
                         json.dumps([])):
            with self.subTest(baseline=baseline):
                self.write(app={'lib/a.dart': hits(1, 0)}, plugin={'lib/p.dart': hits(1, 0)},
                           baseline=baseline)
                code, out = self.gate()
                self.assertEqual(code, 2, out)
                self.assertIn('Baseline', out)


class RepositoryBaselineTest(unittest.TestCase):
    def test_checked_in_baseline_is_valid(self):
        data = json.loads((ROOT / 'tool/coverage/baseline.json').read_text())
        minimums = data['minimum_line_coverage']
        self.assertEqual(set(minimums), {'lib', 'plugin'})
        for value in minimums.values():
            self.assertIsInstance(value, int)
            self.assertGreater(value, 0)
            self.assertLessEqual(value, 100)


if __name__ == '__main__':
    unittest.main()
