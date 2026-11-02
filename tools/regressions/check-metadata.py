#!/usr/bin/env python3
"""Fast offline metadata checks, not a substitute for macOS compilation/tests."""
import json
import pathlib
import plistlib
import re
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[2]


def read(path):
    return (ROOT / path).read_text()


for path in (ROOT / 'tools/i18n').glob('*.json'):
    json.loads(path.read_text())
for path in ROOT.rglob('Package.resolved'):
    json.loads(path.read_text())
for path in ROOT.rglob('*.plist'):
    plistlib.loads(path.read_bytes())
print('PASS translation/package JSON and XML plists')

catalog = json.loads(read('Orbit/Resources/Localizable.xcstrings'))['strings']
translations = json.loads(read('tools/i18n/ko-regressions.json'))
for key, value in translations.items():
    assert catalog[key]['localizations']['ko']['stringUnit']['value'] == value, key
    assert re.findall(r'%ld|%@', key) == re.findall(r'%ld|%@', value), key
print(f'PASS {len(translations)} regression translations and format arguments')

yaml = read('project.yml')
project = read('Orbit.xcodeproj/project.pbxproj')
version = re.search(r'MARKETING_VERSION: "([^"]+)"', yaml)[1]
build = re.search(r'CURRENT_PROJECT_VERSION: "([^"]+)"', yaml)[1]
assert re.findall(r'MARKETING_VERSION = ([^;]+);', project) == [version] * 2
assert re.findall(r'CURRENT_PROJECT_VERSION = ([^;]+);', project) == [build] * 2
assert project.count('OrbitInstance.swift in Sources') == 2
assert project.count('path = OrbitInstance.swift;') == 1
ids = re.findall(r'^\t\t([A-F0-9]{24})(?: /\*.*?\*/)? = ', project, re.M)
assert len(ids) == len(set(ids)), 'duplicate Xcode object identity'
assert set(re.findall(r'\b[A-F0-9]{24}\b', project)) == set(ids)
print(f'PASS version {version} ({build}) and Xcode source/object references')

tokens = re.sub(r'/\*.*?\*/|//[^\n]*|"(?:[^"\\]|\\.)*"', '', project, flags=re.S)
stack = []
for char in tokens:
    if char in '{(': stack.append(char)
    elif char in '})':
        assert stack and stack.pop() == {'}': '{', ')': '('}[char]
assert not stack
print('PASS Xcode delimiter structure (not xcodebuild validation)')

line = next(line for line in read('Orbit/Core/Localization.swift').splitlines() if 'process.arguments = ' in line)
script = line.split('["-c", "', 1)[1].rsplit('", "sh",', 1)[0].replace('\\"', '"')
subprocess.run(['bash', '-n'], input=script, text=True, check=True)
subprocess.run(['bash', '-n', str(ROOT / 'tools/regressions/run-archive-tests.sh')], check=True)
print('PASS relaunch and archive-runner shell syntax')
