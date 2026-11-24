#!/usr/bin/env python3
"""Check generated search metadata for ambiguous notch labels."""
import runpy
from pathlib import Path

root = Path(__file__).resolve().parents[2]
entries = runpy.run_path(str(root / 'tools/settings_index.py'))['entries']


def entry(title, kind):
    return next(e for e in entries if e['page'] == 'notch' and e['title'] == title and e['kind'] == kind)


def synonyms(e):
    return set(e['keywords'] + e['related'])


for title, kind, unwanted in [
    ('AI Usage', 'group', {'디스크', '캐시', 'docker', 'cpu', 'gpu', 'ram', 'memory', 'monitor'}),
    ('Home layout', 'group', {'스냅', '분할', 'snap'}),
    ('Limit windows', 'row', {'스냅', '분할', 'snap'}),
]:
    assert not synonyms(entry(title, kind)) & unwanted, title
home = entry('Home', 'row')
for keyword in ['캘린더', '음악']:
    assert keyword in ' '.join([home['subtitleKo'], *synonyms(home)]), 'Home widget discovery'
print('PASS: notch search excludes storage/window synonyms and retains calendar/music discovery')
