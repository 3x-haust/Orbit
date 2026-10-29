#!/usr/bin/env python3
"""Builds Orbit/App/Generated/SettingsIndex.swift, the index behind the app window's search.

It reads the page sources the way a person reads the window: every page, every group card, every
row's title and subtitle, and the labels of the controls in a row (so "Empty Trash…" finds the Trash
row). Each entry carries its Korean translation (tools/i18n/ko*.json) and keywords from
tools/settings_synonyms.json: other words for the same thing, and other apps' names.

Run on every build (an Xcode pre-build phase) and from tools/i18n.py; the file is only rewritten
when its content changes, so an unchanged index doesn't recompile.
"""
import glob, json, os, re

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(root)
OUT = 'Orbit/App/Generated/SettingsIndex.swift'

ko = {}
for f in sorted(glob.glob('tools/i18n/ko*.json')):  # same order as tools/i18n.py, so the same winner
    ko.update(json.load(open(f)))
syn = json.load(open('tools/settings_synonyms.json'))
# Words too common to say which group a text belongs to ("screen" is in half the titles).
no_trigger = {w.lower() for w in syn.get('noTrigger', [])}

literal = re.compile(r'"((?:[^"\\\n]|\\.)*)"')

def ui(s):
    if not s or not re.search(r'[A-Za-z가-힣]', s) or '\\(' in s: return False
    if re.fullmatch(r'[a-z0-9_.\-]+', s): return False  # SF Symbols, identifiers
    if s.startswith(('com.', '/', 'http', 'public.')): return False
    return True

def clean(s):
    return s.replace('\\n', ' ').replace('\\"', '"').replace('%@', '').replace('%ld', '').replace('%d', '').strip(' ·…')

def balanced(src, i, open_, close):
    """Index just past the bracket matching src[i] (an opening bracket), skipping strings."""
    depth, n, in_str = 0, len(src), False
    while i < n:
        c = src[i]
        if in_str:
            if c == '\\': i += 1
            elif c == '"': in_str = False
        elif c == '"': in_str = True
        elif c == open_: depth += 1
        elif c == close:
            depth -= 1
            if depth == 0: return i + 1
        i += 1
    return n

def arg(args, name, stop):
    """Literals of one labelled argument (both sides of a ternary count)."""
    m = re.search(r'\b' + name + r':', args)
    if not m: return []
    rest = args[m.end():]
    s = re.search(r',\s*(?:' + stop + r'):', rest)
    rest = rest[:s.start()] if s else rest
    # A formatted string ("Connected as %@") is a status line, not a name.
    return [clean(x) for x in literal.findall(rest) if ui(x) and not re.search(r'%(@|l?d|\.\d*f|s)', x)]

# Page enum: case → English title and symbol; routing: page struct → case; sidebar order.
main = open('Orbit/App/MainWindow.swift').read()
def switch_block(name):
    i = main.index('var ' + name)
    return main[i:balanced(main, main.index('{', i), '{', '}')]
titles = {c: t for c, t in re.findall(r'case \.(\w+): "([^"]+)"', switch_block('englishTitle'))}
symbols = {c: t for c, t in re.findall(r'case \.(\w+): "([^"]+)"', switch_block('symbol'))}
routes = {}
for c, s in re.findall(r'case \.(\w+): (\w+)\(', main[main.index('private var page: some View'):]):
    routes.setdefault(s, c)
order = re.findall(r'\.(\w+)', main[main.index('static let sections'):main.index(']\n}', main.index('static let sections'))])

# Every view struct in the app and which others it uses; pages reach their sections through it.
structs = {}
for f in sorted(glob.glob('Orbit/**/*.swift', recursive=True)):
    if f.startswith(('Orbit/Design/', 'Orbit/App/Generated/')) or f.endswith('MainWindow.swift'): continue
    src = open(f).read()
    for m in re.finditer(r'^\s*(?:(?:private|fileprivate|public|internal)\s+)?struct (\w+)[^{\n]*\{', src, re.M):
        end = balanced(src, m.end() - 1, '{', '}')
        structs[m.group(1)] = src[m.start():end]
uses = {name: {o for o in structs if o != name and re.search(r'\b' + o + r'\s*[({]', body)} for name, body in structs.items()}
owner = {}
for name, page in sorted(routes.items(), key=lambda kv: order.index(kv[1]) if kv[1] in order else 99):
    queue = [name]
    while queue:
        s = queue.pop(0)
        if s in owner.setdefault('_seen_' + page, set()): continue
        owner['_seen_' + page].add(s)
        owner.setdefault(s, [])
        if page not in owner[s]: owner[s].append(page)
        queue += sorted(uses.get(s, ()))

def keywords_for(*texts):
    """Synonym groups the entry's own words belong to, minus the words it already has."""
    blob = ' '.join(t.lower() for t in texts if t)
    flat = blob.replace(' ', '')
    def has(w):
        w = w.lower()
        if re.search(r'[가-힣]', w): return w in blob or w.replace(' ', '') in flat
        return re.search(r'(?<![a-z])' + re.escape(w) + r'(?![a-z])', blob) is not None  # "lid" isn't in "slides"
    out = []
    for group in syn['groups']:
        if any(has(w) for w in group if len(w) >= 2 and w.lower() not in no_trigger):
            out += [w for w in group if w.lower() not in blob]
    return out

entries, seen = [], set()
def add(kind, page, group, titles_, subtitle, symbol, labels=(), extra=()):
    title = titles_[0]
    key = (kind, page, title)
    if key in seen: return
    seen.add(key)
    # Other words for the title count almost as much as the title; for the rest, less.
    extra = list(extra) + keywords_for(title, ko.get(title))
    related = [w for w in dict.fromkeys(keywords_for(title, ko.get(title), subtitle, ko.get(subtitle or ''), *labels)) if w not in extra]
    entries.append(dict(kind=kind, page=page, group=group or '', groupKo=ko.get(group or '', '') or '',
                        title=title, titleKo=ko.get(title) or '', subtitle=subtitle or '', subtitleKo=ko.get(subtitle or '') or '',
                        symbol=symbol or '', anchors=titles_,
                        labels=list(dict.fromkeys(l for l in labels if l != title))[:8],
                        labelsKo=list(dict.fromkeys(ko[l] for l in labels if ko.get(l)))[:8],
                        keywords=list(dict.fromkeys(extra))[:24], related=related[:24]))

# Only real settings: rows and cards that are always there. Banners, warnings, empty states and
# status lines live in `if` branches on runtime state (a conflicting app running, a permission
# missing, an error) — searching for them finds things that may not exist right now.
STATE = re.compile(r'conflict|overlap|isRunning|running|installed|permission|granted|trusted|authorized|denied|missing|'
                   r'error|failed|failure|unavailable|isEmpty|== *nil|!= *nil|needs|warning|banner|notice|status|'
                   r'busy|scanning|loading|phase|helper|systemOverflow|clash|takenBy|managing|tucked|crowded|full', re.I)
WARNING_SYMBOLS = re.compile(r'exclamationmark|xmark\.octagon|bolt\.trianglebadge|questionmark|hand\.raised|lock\.trianglebadge')
CONTROLS = re.compile(r'\b(Toggle|Picker|ChipPicker|Slider|Stepper|Menu|TextField|ShortcutRecorder|ColorPicker|DatePicker|\w+Picker|\w+Slider|SegmentedControl)\s*[\(<{]')
GENERIC = {'on', 'off', 'yes', 'no', 'ok', 'done', 'cancel', 'empty', 'none', 'loading', 'never', 'always', 'show', 'hide',
           'open', 'start', 'stop', 'new', 'add', 'remove', 'edit', 'more', 'less', 'other', 'custom', 'default', 'app', 'apps',
           'add app', 'add apps', 'choose', 'choose app', 'browse', 'try it'}
explicit_skip = set(syn.get('skip', []))
# Kept although they sit in a state branch (always there in practice).
explicit_keep = set(syn.get('keep', []))
skipped_titles = []

def conditional_blocks(body):
    """(start, end) of every `if`/`else` branch whose condition is runtime state."""
    out = []
    for m in re.finditer(r'\bif\s+([^{}\n]*?)\{', body):
        cond = m.group(1)
        start = m.end() - 1
        end = balanced(body, start, '{', '}')
        if STATE.search(cond):
            out.append((start, end))
            rest = body[end:].lstrip()
            if rest.startswith('else'):
                e = body.index('{', end)
                out.append((e, balanced(body, e, '{', '}')))
    return out

def useful(t):
    """Something a person would search for: not a format, a placeholder or a lone generic word."""
    t = t.strip()
    if not t or t.lower() in GENERIC: return False
    # Empty states and progress ("No schedules yet", "Waiting for Last.fm").
    if re.match(r'(No|Nothing|Waiting|Connected|Loading|Checking|Scanning|Searching|Looking)\b', t): return False
    if re.fullmatch(r'[\W\d_]+', t): return False
    return True

def label_ok(l):
    """A control label worth matching: not an identifier, a date format, a placeholder or an alert's text."""
    if re.fullmatch(r'[a-z]+[A-Z]\w*', l) or '%' in l or 'xxxx' in l: return False
    if re.fullmatch(r'[yMdEHhmsa .:/,\-()년월일]+', l): return False  # "yyyy.MM.dd", "M월 d일 (E)"
    if len(re.sub(r'[^A-Za-z가-힣]', '', l)) < 2: return False         # ")s", "L", "M"
    if l.endswith(('?', '.', '요.')) or l.lower() in ('unavailable',): return False
    return True

def skipped(body, pos, args, states):
    line_start = body.rfind('\n', 0, pos) + 1
    before = body[max(0, body.rfind('\n', 0, line_start - 1)):pos]
    line_end = body.find('\n', pos)
    if 'search:skip' in before or 'search:skip' in body[pos:line_end]: return True
    title = (arg(args, 'title', 'subtitle|symbol|icon|footer') or [''])[0]
    if title in explicit_skip: return True
    if title in explicit_keep: return False
    sym = re.search(r'symbol:\s*"([^"]+)"', args)
    if sym and WARNING_SYMBOLS.search(sym.group(1)): return True
    # A message, not a setting ("Barbee is managing the menu bar", "Orbit can't see the keys yet").
    if re.search(r"\b(is managing|is running|isn’t|isn't|can’t|can't|couldn’t|couldn't|needs|is not|not found|failed)\b", title) \
            or re.search(r'[.!]$', title): return True
    if not any(a < pos < b for a, b in states): return False
    # Inside a state branch, a row that sets something is still a setting (options that appear once
    # Tavi is installed); one that only offers a button is a banner ("Quit Barbee").
    close = balanced(body, body.index('(', pos), '(', ')')
    rest = body[close:].lstrip()
    if not rest.startswith('{'): return True
    start = body.index('{', close)
    accessory = body[start:balanced(body, start, '{', '}')]
    return not CONTROLS.search(accessory)

# Pages first, with their header subtitle and the apps they replace.
page_apps = {}
for app, page in syn['apps'].items(): page_apps.setdefault(page, []).append(app)
for page in order:
    struct = next((s for s, c in routes.items() if c == page), None)
    sub = ''
    if struct and struct in structs:
        m = re.search(r'PageHeader\(title:\s*"[^"]*"\s*,\s*subtitle:\s*"((?:[^"\\]|\\.)*)"', structs[struct])
        sub = clean(m.group(1)) if m else ''
    if page in titles:
        add('page', page, '', [titles[page]], sub, symbols.get(page), extra=page_apps.get(page, []) + syn.get('pages', {}).get(page, []))

for name in sorted(structs, key=lambda s: (min((order.index(p) for p in owner.get(s, []) if p in order), default=99), s)):
    pages = owner.get(name)
    if not pages or name.startswith('_'): continue
    body = structs[name]
    states = conditional_blocks(body)
    marks = [(m.start(), 'group', m) for m in re.finditer(r'SettingsGroup\(\s*title:', body)]
    marks += [(m.start(), 'row', m) for m in re.finditer(r'SettingsRow\(\s*title:', body)]
    group = ''
    for pos, kind, m in sorted(marks, key=lambda t: t[0]):
        open_ = body.index('(', pos)
        close = balanced(body, open_, '(', ')')
        args = body[open_ + 1:close - 1]
        if skipped(body, pos, args, states):
            skipped_titles.append((name, (arg(args, 'title', 'subtitle|symbol|icon|footer') or ['?'])[0]))
            continue
        if kind == 'group':
            g = arg(args, 'title', 'footer')
            group = g[0] if g else ''
            if group:
                footer = (arg(args, 'footer', 'title') or [''])[0]
                for p in pages: add('group', p, '', [group], footer, '')
            continue
        # `paused ? "Recording is paused" : "Recording"`: the usual wording comes last.
        t = [x for x in reversed(arg(args, 'title', 'subtitle|symbol|icon')) if useful(x)]
        if not t: continue
        sub = arg(args, 'subtitle', 'symbol|icon')
        sym = re.search(r'symbol:\s*"([^"]+)"', args)
        labels = []
        rest = body[close:].lstrip()
        if rest.startswith('{'):
            start = body.index('{', close)
            accessory = body[start:balanced(body, start, '{', '}')]
            labels = [clean(x) for x in literal.findall(accessory) if ui(x) and not re.fullmatch(r'[a-z.]+', x)]
            labels = [l for l in labels if useful(l) and label_ok(l)]
        for p in pages: add('row', p, group, t, ' '.join(sub[:1]), sym.group(1) if sym else '', labels)

# OrbitAction titles: searchable and runnable from the results.
act = open('Orbit/Core/OrbitAction.swift').read()
i = act.index('private var englishTitle')
block = act[i:balanced(act, act.index('{', i), '{', '}')]
actions = []
for case, rhs in re.findall(r'case \.(\w+): (.+)', block):
    lits = [clean(x) for x in literal.findall(rhs) if ui(x)]
    if lits:
        actions.append(dict(id=case, titles=lits, ko=[ko.get(l) or '' for l in lits],
                            keywords=syn.get('actions', {}).get(case, []),
                            related=list(dict.fromkeys(keywords_for(*lits, *[ko.get(l) for l in lits])))[:16]))

def q(s): return json.dumps(s, ensure_ascii=False)
def arr(xs): return '[' + ', '.join(q(x) for x in xs) + ']'
lines = ['// Generated by tools/settings_index.py on every build — edit the pages or tools/settings_synonyms.json instead.',
         '', 'enum SettingsIndex {', '    static let entries: [SettingsEntry] = [']
for e in entries:
    lines.append(f'        SettingsEntry(kind: .{e["kind"]}, page: {q(e["page"])}, group: {q(e["group"])}, groupKo: {q(e["groupKo"])}, '
                 f'title: {q(e["title"])}, titleKo: {q(e["titleKo"])}, subtitle: {q(e["subtitle"])}, subtitleKo: {q(e["subtitleKo"])}, '
                 f'symbol: {q(e["symbol"])}, anchors: {arr(e["anchors"])}, labels: {arr(e["labels"] + e["labelsKo"])}, keywords: {arr(e["keywords"])}, related: {arr(e["related"])}),')
lines += ['    ]', '', '    static let actions: [SettingsActionEntry] = [']
for a in actions:
    lines.append(f'        SettingsActionEntry(id: {q(a["id"])}, titles: {arr(a["titles"])}, titlesKo: {arr(a["ko"])}, keywords: {arr(a["keywords"])}, related: {arr(a["related"])}),')
lines += ['    ]', '}', '']
text = '\n'.join(lines)
os.makedirs(os.path.dirname(OUT), exist_ok=True)
if not os.path.exists(OUT) or open(OUT).read() != text:
    open(OUT, 'w').write(text)
print(f'settings index: {len(entries)} entries, {len(actions)} actions, {len(skipped_titles)} conditional left out')
if '--verbose' in __import__('sys').argv:
    for n, t in skipped_titles: print('  skipped', n, '·', t)
