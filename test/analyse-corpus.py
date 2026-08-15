#!/usr/bin/env python3
"""Measure the properties of a set of KOReader sidecars.

Reads the Lua files purely as text; no Lua is executed and no external
interpreter is called.  The point is to establish what the sidecar format
actually contains, rather than what it is assumed to contain.

Usage:

    python3 test/analyse-corpus.py                 # the corpus in this repo
    python3 test/analyse-corpus.py DIRECTORY ...   # your own sidecars

Every DIRECTORY is walked recursively for `*.sdr` directories.  Beside each
sidecar the source file is looked for, named after the sidecar with the
extension the metadata file carries: `source.sdr` holding `metadata.md.lua`
belongs to `source.md`.

Sources that are not plain text -- an EPUB is an archive -- are still counted
for everything that follows from the sidecar alone.  Only the comparisons
against the source text are skipped for them, and reported separately, so that
the verbatim counts stay honest.

The script fails hard when an annotation lacks one of the expected fields,
rather than yielding a count that looks right.
"""

import collections
import os
import re
import sys

# A string value runs to the first double quote not preceded by a backslash.
# re.S is needed: KOReader writes backslash-plus-newline as a line
# continuation inside a string.
KEY = re.compile(r'\["(\w+)"\] = ("(?:[^"\\]|\\.)*"|[^,\n]+),[ \t]*$', re.M | re.S)
BLOCK = re.compile(r'\n        \[\d+\] = \{(.*?)\n        \},', re.S)
XP = re.compile(r'^(?P<node>.*)\.(?P<off>\d+)$')
METADATA = re.compile(r'\Ametadata\.(?P<ext>.+)\.lua\Z')

ESCAPES = {'n': '\n', 't': '\t', 'r': '\r', '"': '"', '\\': '\\', '\n': '\n'}

# Bookmarks and text ranges have different schemas.  A bookmark lacks
# `drawer`, `color`, `pos0` and `pos1`; KOReader does not count it in stats
# either.  `chapter` and `text` are demanded of ranges only: a bookmark set
# before the first heading carries neither, so requiring them everywhere
# would reject valid data.
COMMON_REQUIRED = ('datetime', 'page', 'pageno')
RANGE_REQUIRED = ('chapter', 'color', 'drawer', 'pos0', 'pos1', 'text')

# Extensions whose source file can be compared against the stored text as it
# stands.  Anything else is an archive or a binary and is counted, but not
# searched.
TEXT_EXTENSIONS = ('md', 'txt', 'markdown', 'text', 'org', 'html', 'htm', 'fb2')


class CorpusError(Exception):
    pass


def unescape(s):
    """Turn a Lua string literal (without its surrounding quotes) into text."""
    out, i = [], 0
    while i < len(s):
        if s[i] == '\\' and i + 1 < len(s):
            out.append(ESCAPES.get(s[i + 1], s[i + 1]))
            i += 2
        else:
            out.append(s[i])
            i += 1
    return ''.join(out)


def annotations(path):
    text = open(path, encoding='utf-8').read()
    region = annotation_region(path, text)
    if not region:
        return []
    blocks = BLOCK.findall(region)

    # A missing field inside a recognised block is caught below, but a block
    # the regexp skips altogether would stay invisible.  Count the numeric
    # keys independently, and check against the statistics KOReader keeps
    # itself.
    declared = len(re.findall(r'\n        \[\d+\] = \{', region))
    if declared != len(blocks):
        raise CorpusError(
            '%s: %d annotation keys declared, %d blocks recognised.\n'
            'The block pattern is skipping annotations.' % (path, declared, len(blocks)))

    out = []
    for n, block in enumerate(blocks, 1):
        entry = {}
        for m in KEY.finditer(block):
            raw = m.group(2)
            entry[m.group(1)] = unescape(raw[1:-1]) if raw.startswith('"') else raw.strip()
        required = COMMON_REQUIRED + (() if 'drawer' not in entry else RANGE_REQUIRED)
        missing = [k for k in required if k not in entry]
        if missing:
            raise CorpusError(
                '%s annotation [%d]: expected fields missing: %s\n'
                'A silently missing field makes every derived count wrong.'
                % (path, n, ', '.join(missing)))
        out.append(entry)

    stats = re.search(r'\["stats"\] = \{(.*?)\n    \},', text, re.S)
    if stats:
        counted = 0
        for key in ('highlights', 'notes'):
            m = re.search(r'\["%s"\] = (\d+)' % key, stats.group(1))
            if m:
                counted += int(m.group(1))
        ranged = sum('drawer' in entry for entry in out)
        if counted != ranged:
            raise CorpusError(
                '%s: stats reports %d annotations with a range, but %d blocks '
                'have a drawer.\nBookmarks should count on neither side.'
                % (path, counted, ranged))
    return out


def annotation_region(path, text=None):
    """Return the literally serialised annotations block."""
    if text is None:
        text = open(path, encoding='utf-8').read()
    start = text.find('["annotations"]')
    if start < 0:
        return ''
    end = re.search(r'\n    \},\n', text[start:])
    if not end:
        raise CorpusError('%s: annotations table is not closed' % path)
    return text[start:start + end.end()]


def sidecars(roots):
    """Yield (metadata path, source path or None, label) for every sidecar.

    The source is None when there is no file beside the sidecar, and when the
    source is not plain text.  The label names the sidecar in a way that stays
    distinguishable: every fixture directory holds a `source.sdr`, so the name
    of the sidecar alone says nothing.
    """
    found = []
    for root in roots:
        if not os.path.isdir(root):
            raise CorpusError('%s: no such directory' % root)
        for base, dirs, _files in os.walk(root):
            for name in sorted(dirs):
                if name.endswith('.sdr'):
                    found.append(os.path.join(base, name))
    for sdr in sorted(found):
        metadata = None
        extension = None
        for name in sorted(os.listdir(sdr)):
            m = METADATA.match(name)
            if m:
                metadata, extension = os.path.join(sdr, name), m.group('ext')
                break
        if not metadata:
            continue
        parent = os.path.dirname(sdr)
        stem = os.path.basename(sdr)[:-len('.sdr')]
        candidate = os.path.join(parent, '%s.%s' % (stem, extension))
        source = candidate if os.path.exists(candidate) else None
        if source and extension.lower() not in TEXT_EXTENSIONS:
            source = None
        yield metadata, source, os.path.join(os.path.basename(parent), stem)


def count_escapes(path):
    r"""Count the escape forms in a sidecar: \" and line continuation."""
    text = open(path, encoding='utf-8').read()
    quote = newline = 0
    for m in re.finditer(r'\\(.)', text, re.S):
        if m.group(1) == '"':
            quote += 1
        elif m.group(1) == '\n':
            newline += 1
    return quote, newline


def measure(roots):
    """Walk ROOTS and return the tallies, key sets, path shapes and anomalies."""
    tally = collections.Counter()
    keysets = collections.Counter()
    xpath_shapes = collections.Counter()
    anomalies = []

    for lua, source_path, where in sidecars(roots):
        source = open(source_path, encoding='utf-8').read() if source_path else None

        quote, newline = count_escapes(lua)
        tally['escape \\"'] += quote
        tally['escape line continuation'] += newline

        for a in annotations(lua):
            tally['annotations'] += 1
            keysets[tuple(sorted(a))] += 1
            if a.get('page') == a.get('pos0'):
                tally['page == pos0'] += 1
            if 'note' in a:
                tally['with a note'] += 1
            if 'datetime_updated' in a:
                tally['with datetime_updated'] += 1
            if '\n' in a.get('text', ''):
                tally['text holds a line break'] += 1
            if 'drawer' not in a:
                tally['bookmarks without a drawer'] += 1
                continue
            tally['colour %s' % a['color']] += 1

            m0, m1 = XP.match(a.get('pos0', '')), XP.match(a.get('pos1', ''))
            if not (m0 and m1):
                anomalies.append(('unparseable xpointer', where, a.get('pos0')))
                continue

            xpath_shapes[re.sub(r'\d+', 'N', m0.group('node'))] += 1
            text = a.get('text', '')
            same_node = m0.group('node') == m1.group('node')
            comparable = source is not None
            found = comparable and bool(text) and text in source

            if same_node:
                tally['pos0/pos1 same text node'] += 1
                if comparable:
                    tally['  same node: text verbatim in source'] += found
                    # Present verbatim is not the same as unambiguously
                    # locatable: repeated text yields several candidates.
                    hits = source.count(text) if text else 0
                    if hits == 1:
                        tally['    of which unique'] += 1
                    elif hits > 1:
                        tally['    of which several candidates'] += 1
                        anomalies.append(('%d candidates' % hits, where, text[:60]))
                else:
                    tally['  same node: source not comparable'] += 1
                delta = int(m1.group('off')) - int(m0.group('off'))
                if delta == len(text):
                    tally['  offset delta == characters'] += 1
                elif delta == len(text.encode()):
                    tally['  offset delta == bytes'] += 1
                else:
                    tally['  offset delta deviates'] += 1
                    anomalies.append(('offset delta %d vs %d characters'
                                      % (delta, len(text)), where, text[:60]))
            else:
                tally['pos0/pos1 across node boundaries'] += 1
                if comparable:
                    tally['  cross-node: text verbatim in source'] += found
                    if not found:
                        normalise = lambda s: re.sub(r'\s+', ' ', s)
                        if text and normalise(text) in normalise(source):
                            tally['  cross-node: rescued by whitespace normalisation'] += 1
                else:
                    tally['  cross-node: source not comparable'] += 1

    return tally, keysets, xpath_shapes, anomalies


def report(tally, keysets, xpath_shapes, anomalies):
    if not tally:
        print('no sidecars found')
        return
    width = max(len(k) for k in tally)
    for k, v in tally.items():
        print('%-*s : %d' % (width, k, v))

    print('\nkey sets per annotation:')
    for keys, n in keysets.most_common():
        print('  %3d  %s' % (n, ', '.join(keys)))

    print('\nxpointer path shapes:')
    for shape, n in xpath_shapes.most_common():
        print('  %3d  %s' % (n, shape))

    if anomalies:
        print('\nexceptions:')
        for kind, where, detail in anomalies:
            print('  [%s] %s: %r' % (kind, where, detail))


def validate_controlled_fixture(repo_root):
    """Check the hand-made, reproducible v2026.07 fixture against its promises."""
    fixture = os.path.join(repo_root, 'test', 'fixtures',
                           'koreader-v2026.07-basic', 'source.sdr',
                           'metadata.md.lua')
    export = os.path.join(os.path.dirname(fixture), 'source.md.annotations.lua')
    entries = annotations(fixture)
    bookmarks = [a for a in entries if 'drawer' not in a]
    highlights = [a for a in entries if 'drawer' in a and 'note' not in a]
    notes = [a for a in entries if 'drawer' in a and 'note' in a]

    actual = (len(entries), len(bookmarks), len(highlights), len(notes))
    expected = (4, 1, 2, 1)
    if actual != expected:
        raise CorpusError(
            '%s: expected total/bookmark/highlight/note %r, got %r'
            % (fixture, expected, actual))

    by_text = {a.get('text'): a for a in entries}
    # The selected strings are Dutch because the fixture document is.
    expected_colors = {
        'unieke ankerlicht': 'yellow',
        'donkere horizon': 'green',
        'kalme noorderwind': 'yellow',
    }
    for selected, color in expected_colors.items():
        actual_color = by_text.get(selected, {}).get('color')
        if actual_color != color:
            raise CorpusError(
                '%s: %r should have colour %r, got %r'
                % (fixture, selected, color, actual_color))

    if annotation_region(fixture) != annotation_region(export):
        raise CorpusError(
            '%s: annotations block deviates from metadata.md.lua' % export)
    export_text = open(export, encoding='utf-8').read()
    for key in ('datetime', 'device_id'):
        if not re.search(r'\["%s"\] = "[^"]+",' % key, export_text):
            raise CorpusError('%s: top-level %s missing' % (export, key))

    print('\ncontrolled v2026.07 fixture:')
    print('  1 bookmark without a drawer')
    print('  1 yellow highlight')
    print('  1 green highlight')
    print('  1 yellow highlight with a note')
    print('  annotations export is byte-identical and has datetime + device_id')


def main():
    repo_root = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))
    own_corpus = len(sys.argv) == 1
    roots = sys.argv[1:] or [os.path.join(repo_root, 'test', 'corpus')]

    report(*measure(roots))

    if own_corpus:
        validate_controlled_fixture(repo_root)


if __name__ == '__main__':
    try:
        main()
    except CorpusError as e:
        sys.exit('ERROR: %s' % e)
