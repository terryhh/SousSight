#!/usr/bin/env python3
"""SousSight line-coverage report and gate (SS-088).

    python3 -I tool/coverage/coverage_gate.py [--update-baseline] [options]

Reads the lcov files written by `flutter test --coverage` for the app
(coverage/lcov.info) and for the ai_logic_hybrid plugin
(packages/ai_logic_hybrid/coverage/lcov.info), merges them, and measures line
coverage for two gated roots:

    lib      the app's lib/
    plugin   packages/ai_logic_hybrid/lib/

Generated files (lib/firebase_options.dart, *.g.dart, *.freezed.dart,
*.mocks.dart) are excluded. Coverage is the share of instrumented lines (lcov
DA records) with a hit count above zero. A Dart file that no VM test loads
produces no DA records, so it cannot be part of the percentage; such files
are listed separately ("Without lcov lines") rather than silently ignored;
export-only barrel files also land there because they have no executable
lines.

The gate compares each root's coverage with the integer minimum stored in
tool/coverage/baseline.json and fails when a root is below it. With
--update-baseline each minimum is raised to the current measurement rounded
down; it is never lowered. A missing baseline file is created only with
--update-baseline.

Writes a plain-text report (default build/verify/coverage.txt), a merged lcov
file with repository-relative paths (default build/verify/lcov.info), and
prints the report. Exit codes: 0 gate passed, 1 gate failed, 2 bad input or
usage. Standard library only.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PLUGIN_DIR = 'packages/ai_logic_hybrid'
GATED_ROOTS = {'lib': 'lib/', 'plugin': PLUGIN_DIR + '/lib/'}
# Areas always printed, even when nothing in them was measured.
NAMED_AREAS = ('lib/ai', 'lib/trust', 'lib/watch', 'lib/pantry', 'lib/coach_lite',
               'lib/label', 'lib/live', 'lib/learner', 'lib/data', 'plugin')
EXCLUDED = (
    re.compile(r'^lib/firebase_options\.dart$'),
    re.compile(r'\.g\.dart$'),
    re.compile(r'\.freezed\.dart$'),
    re.compile(r'\.mocks\.dart$'),
)


class InputError(Exception):
    """Unreadable or malformed input: exit code 2."""


def excluded(path: str) -> bool:
    return any(pattern.search(path) for pattern in EXCLUDED)


def normalize(source: str, package_dir: str, root: Path) -> str:
    """Repository-relative POSIX path for an lcov SF entry.

    Flutter writes paths relative to the package it tested (lib/x.dart);
    other tools write absolute paths. Both map to the repository root.
    """
    source = source.strip().replace('\\', '/')
    if os.path.isabs(source):
        try:
            return Path(source).resolve().relative_to(root.resolve()).as_posix()
        except ValueError:
            return source  # Outside the repository: filtered out later.
    if package_dir:
        return f'{package_dir}/{source}'
    return source


def parse_lcov(text: str, package_dir: str, root: Path) -> dict[str, dict[int, int]]:
    """Map of repository path -> {line: hits}. Repeated records merge by max."""
    files: dict[str, dict[int, int]] = {}
    current: dict[int, int] | None = None
    for number, raw in enumerate(text.splitlines(), start=1):
        line = raw.strip()
        if line.startswith('SF:'):
            path = normalize(line[3:], package_dir, root)
            current = files.setdefault(path, {})
        elif line.startswith('DA:'):
            if current is None:
                raise InputError(f'DA record before SF at line {number}')
            parts = line[3:].split(',')
            try:
                line_no, hits = int(parts[0]), int(parts[1])
            except (IndexError, ValueError):
                raise InputError(f'Malformed DA record at line {number}') from None
            if line_no < 1 or hits < 0:
                raise InputError(f'Malformed DA record at line {number}')
            current[line_no] = max(current.get(line_no, 0), hits)
        elif line == 'end_of_record':
            current = None
    return files


def merge(target: dict[str, dict[int, int]], extra: dict[str, dict[int, int]]) -> None:
    for path, lines in extra.items():
        merged = target.setdefault(path, {})
        for line_no, hits in lines.items():
            merged[line_no] = max(merged.get(line_no, 0), hits)


def gated_root(path: str) -> str | None:
    for name, prefix in GATED_ROOTS.items():
        if path.startswith(prefix):
            return name
    return None


def area_of(path: str) -> str:
    if path.startswith(GATED_ROOTS['plugin']):
        return 'plugin'
    parts = path.split('/')
    if len(parts) > 2:
        return f'lib/{parts[1]}'
    return 'lib (top level)'


def source_files(root: Path) -> list[str]:
    found = []
    for prefix in GATED_ROOTS.values():
        base = root / prefix
        if not base.is_dir():
            continue
        for file in sorted(base.rglob('*.dart')):
            path = file.relative_to(root).as_posix()
            if not excluded(path):
                found.append(path)
    return found


def pct(hit: int, found: int) -> float:
    return 100.0 * hit / found if found else 0.0


def floor_pct(hit: int, found: int) -> int:
    return (100 * hit) // found if found else 0


def fmt_pct(hit: int, found: int) -> str:
    return f'{pct(hit, found):5.1f}%' if found else '    - '


def load_baseline(path: Path) -> dict | None:
    if not path.exists():
        return None
    try:
        data = json.loads(path.read_text(encoding='utf-8'))
    except (OSError, ValueError) as error:
        raise InputError(f'Baseline {path} is not readable JSON: {error}') from None
    minimums = data.get('minimum_line_coverage') if isinstance(data, dict) else None
    if not isinstance(minimums, dict):
        raise InputError(f'Baseline {path} has no minimum_line_coverage object')
    for name in GATED_ROOTS:
        value = minimums.get(name)
        if not isinstance(value, int) or isinstance(value, bool) or not 0 <= value <= 100:
            raise InputError(f'Baseline {path}: minimum for {name!r} must be an integer 0-100')
    return data


def build_report(files, all_sources, minimums, bottom) -> tuple[list[str], dict, list[str]]:
    """Returns (report lines, per-root (hit, found), gate failures)."""
    roots = {name: [0, 0] for name in GATED_ROOTS}
    areas: dict[str, list[int]] = {name: [0, 0, 0] for name in NAMED_AREAS}  # hit, found, files
    per_file = []
    for path, lines in sorted(files.items()):
        root_name = gated_root(path)
        if root_name is None or excluded(path):
            continue
        found = len(lines)
        hit = sum(1 for hits in lines.values() if hits > 0)
        roots[root_name][0] += hit
        roots[root_name][1] += found
        area = areas.setdefault(area_of(path), [0, 0, 0])
        area[0] += hit
        area[1] += found
        area[2] += 1
        if found:
            per_file.append((pct(hit, found), found - hit, path, hit, found))

    measured = {path for path in files if gated_root(path) and not excluded(path)}
    unloaded = [path for path in all_sources if path not in measured]

    out = ['SousSight line coverage (lcov DA records; generated files excluded)', '']
    out.append(f'{"Gated root":<40} {"Lines":>13} {"Cover":>7} {"Minimum":>8}  Result')
    failures = []
    for name, prefix in GATED_ROOTS.items():
        hit, found = roots[name]
        minimum = minimums.get(name) if minimums else None
        if not found:
            result = 'FAIL (no coverage data)'
            failures.append(f'{name}: no coverage data for {prefix}')
        elif minimum is None:
            result = 'no baseline'
        elif pct(hit, found) + 1e-9 >= minimum:
            result = 'pass'
        else:
            result = 'FAIL'
            failures.append(f'{name}: {pct(hit, found):.1f}% is below the minimum {minimum}%')
        min_text = f'{minimum}%' if minimum is not None else '-'
        out.append(f'{name + " (" + prefix + ")":<40} {hit:>6}/{found:<6} {fmt_pct(hit, found):>7} '
                   f'{min_text:>8}  {result}')
    total_hit = sum(v[0] for v in roots.values())
    total_found = sum(v[1] for v in roots.values())
    out.append(f'{"combined":<40} {total_hit:>6}/{total_found:<6} {fmt_pct(total_hit, total_found):>7}')

    out += ['', f'{"Area":<20} {"Files":>5} {"Lines":>13} {"Cover":>7}']
    named = [name for name in NAMED_AREAS]
    others = sorted(name for name in areas if name not in NAMED_AREAS)
    for name in named + others:
        hit, found, count = areas[name]
        out.append(f'{name:<20} {count:>5} {hit:>6}/{found:<6} {fmt_pct(hit, found):>7}')

    per_file.sort(key=lambda item: (item[0], -item[1], item[2]))
    out += ['', f'Lowest-covered loaded files (bottom {bottom}, by line coverage):']
    for value, missed, path, hit, found in per_file[:bottom]:
        out.append(f'  {value:5.1f}%  {hit:>5}/{found:<5} {path}')

    out += ['', f'Without lcov lines ({len(unloaded)} files; outside the percentages above). Either no VM '
            'test loads them, or they have nothing executable (export-only barrels):']
    out += [f'  {path}' for path in unloaded] or ['  (none)']
    return out, {name: tuple(v) for name, v in roots.items()}, failures


def write_lcov(path: Path, files) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    chunks = []
    for source, lines in sorted(files.items()):
        if gated_root(source) is None or excluded(source):
            continue
        body = [f'SF:{source}']
        body += [f'DA:{line_no},{hits}' for line_no, hits in sorted(lines.items())]
        body.append(f'LF:{len(lines)}')
        body.append(f'LH:{sum(1 for hits in lines.values() if hits > 0)}')
        body.append('end_of_record')
        chunks.append('\n'.join(body))
    path.write_text('\n'.join(chunks) + ('\n' if chunks else ''), encoding='utf-8')


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    parser.add_argument('--root', type=Path, default=ROOT, help='repository root')
    parser.add_argument('--app-lcov', type=Path, help='default: ROOT/coverage/lcov.info')
    parser.add_argument('--plugin-lcov', type=Path,
                        help=f'default: ROOT/{PLUGIN_DIR}/coverage/lcov.info')
    parser.add_argument('--baseline', type=Path, help='default: ROOT/tool/coverage/baseline.json')
    parser.add_argument('--report', type=Path, help='default: ROOT/build/verify/coverage.txt')
    parser.add_argument('--merged-lcov', type=Path, help='default: ROOT/build/verify/lcov.info')
    parser.add_argument('--bottom', type=int, default=15, help='lowest-covered files to list')
    parser.add_argument('--update-baseline', action='store_true',
                        help='raise (never lower) the stored minimums to the current floor')
    args = parser.parse_args(argv)

    root = args.root.resolve()
    app_lcov = args.app_lcov or root / 'coverage/lcov.info'
    plugin_lcov = args.plugin_lcov or root / PLUGIN_DIR / 'coverage/lcov.info'
    baseline_path = args.baseline or root / 'tool/coverage/baseline.json'
    report_path = args.report or root / 'build/verify/coverage.txt'
    merged_path = args.merged_lcov or root / 'build/verify/lcov.info'

    try:
        files: dict[str, dict[int, int]] = {}
        for lcov, package_dir in ((app_lcov, ''), (plugin_lcov, PLUGIN_DIR)):
            if not lcov.is_file():
                raise InputError(f'lcov file not found: {lcov} (run flutter test --coverage)')
            merge(files, parse_lcov(lcov.read_text(encoding='utf-8'), package_dir, root))
        baseline = load_baseline(baseline_path)
    except (InputError, OSError) as error:
        print(f'coverage_gate: {error}', file=sys.stderr)
        return 2

    if baseline is None and not args.update_baseline:
        print(f'coverage_gate: no baseline at {baseline_path}; '
              'run with --update-baseline to record one', file=sys.stderr)
        return 2
    minimums = dict(baseline['minimum_line_coverage']) if baseline else {}

    report, roots, failures = build_report(files, source_files(root), minimums, args.bottom)

    if args.update_baseline:
        if any(found == 0 for _, found in roots.values()):
            print('coverage_gate: refusing to update the baseline without data for every root',
                  file=sys.stderr)
            return 2
        raised = {name: max(minimums.get(name, 0), floor_pct(*roots[name])) for name in GATED_ROOTS}
        data = baseline or {}
        data['minimum_line_coverage'] = raised
        data.setdefault('note', 'Integer line-coverage minimums enforced by '
                        'tool/coverage/coverage_gate.py. Raised with --update-baseline; never lowered.')
        baseline_path.parent.mkdir(parents=True, exist_ok=True)
        baseline_path.write_text(json.dumps(data, indent=2, sort_keys=True) + '\n', encoding='utf-8')
        changes = ', '.join(f'{name} {minimums.get(name, "-")} -> {raised[name]}' for name in raised)
        # Re-evaluate against the raised minimums. A raised minimum never
        # exceeds the measurement, but a stored one that was already higher
        # (never lowered) can still fail the gate.
        report, _, failures = build_report(files, source_files(root), raised, args.bottom)
        report += ['', f'Baseline updated: {changes}']

    report += ['', 'Gate: ' + ('PASS' if not failures else 'FAIL')]
    report += [f'  {failure}' for failure in failures]
    text = '\n'.join(report) + '\n'
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(text, encoding='utf-8')
    write_lcov(merged_path, files)
    sys.stdout.write(text)
    return 1 if failures else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
