#!/usr/bin/env python3
"""Builds Orbit/Resources/Localizable.xcstrings.

Keys come from two places:
  1. SwiftUI literals the compiler extracts (build with SWIFT_EMIT_LOC_STRINGS=YES first).
  2. Plain string literals in Swift sources that reach the UI through `.loc`.
Translations live in tools/i18n/ko.json (English key → Korean). Run with --missing to list untranslated keys.
"""
import glob, json, os, re, sys

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(root)
import subprocess
subprocess.run([sys.executable, 'tools/settings_index.py'], check=True)  # the search index reads the same strings

extracted = set()
for f in glob.glob('build/Build/Intermediates.noindex/Orbit.build/**/*.stringsdata', recursive=True):
    data = json.load(open(f))
    for entry in data.get('tables', {}).get('Localizable', []):
        extracted.add(entry['key'])

literal = re.compile(r'"((?:[^"\\\n]|\\.)*)"')
def looks_like_ui(s):
    if not re.search(r'[A-Za-z]', s) or '\\(' in s: return False
    if re.fullmatch(r'[a-z0-9_.\-]+', s): return False          # SF Symbols, identifiers
    if re.fullmatch(r'[a-zA-Z]+[A-Z][a-zA-Z]*', s) and s[0].islower(): return False  # camelCase ids
    if s.startswith(('com.', '/', 'http', 'public.', 'NS', 'AX', 'kAX')) or '.app' in s: return False
    return True

sources = set()
for f in glob.glob('Orbit/**/*.swift', recursive=True):
    if f.startswith('Orbit/App/Generated/'): continue  # the search index: keywords, not UI
    for m in literal.finditer(open(f).read()):
        s = m.group(1).replace('\\n', '\n').replace('\\"', '"')
        if looks_like_ui(s): sources.add(s)

ko = {}
for f in sorted(glob.glob('tools/i18n/ko*.json')):
    ko.update(json.load(open(f)))  # ko.json plus per-module files (ko-sound.json, …)
keys = sorted(extracted | sources | set(ko))

if '--missing' in sys.argv:
    for k in keys:
        if k not in ko: print(json.dumps(k, ensure_ascii=False))
    sys.exit(0)

strings = {}
for k in keys:
    entry = {}
    if k in ko and ko[k] is not None:
        entry['localizations'] = {'ko': {'stringUnit': {'state': 'translated', 'value': ko[k]}}}
    if k not in extracted:
        entry['extractionState'] = 'manual'
    strings[k] = entry

catalog = {'sourceLanguage': 'en', 'strings': strings, 'version': '1.0'}
json.dump(catalog, open('Orbit/Resources/Localizable.xcstrings', 'w'), ensure_ascii=False, indent=2, sort_keys=True)
done = sum(1 for k in keys if ko.get(k))
print(f'{len(keys)} keys, {done} translated to Korean')
