# KOReader sidecar format: seven sidecars, one fixture and a generated corpus

Description of the `metadata.md.lua` format as it actually sits on disk,
established by measurement against a real corpus.

**Status.** This is an empirical observation, not a specification of the
KOReader format. The statements hold for the seven original files and the
controlled fixture described below. What the serializer *can* emit, which
fields are mandatory and how KOReader behaves on modification or migration
cannot be derived from this; that needs work on the source. Where the upstream
source goes further than corpus and fixture demonstrate, that is stated
explicitly.

## Where these findings come from

Seven Markdown documents with their `.sdr` sidecars, **191 annotations** in
total, read on a Kobo. They are personal reading files; they do not belong to
this package and are here only the source of the counts. What follows from that
corpus and can be reproduced is also stated below for the generated corpus.

| | |
|---|---|
| device | Kobo, going by `doc_path` under `/mnt/onboard/Markdown/` |
| `cre_dom_version` | `20240114` in every sidecar |
| date the sidecars were written | 5 to 9 August 2026 (file mtime) |
| KOReader version/build | `v2026.07`, confirmed by the owner; not present in the sidecars themselves |
| procedure used to create them | **not recorded** |

`cre_dom_version` is a CRengine DOM version, not a KOReader release; the
version therefore does not follow from these files on its own.

`test/fixtures/koreader-v2026.07-basic/` supplements that evidence. This
fixture was made through the normal UI and persistence of the official
`v2026.07` desktop build and records release, commit, asset checksum, source
file and creation procedure. It holds four entries: one bookmark, one yellow
highlight, one green highlight and one yellow highlight with a note.

The **generated corpus** is the third source. A separate generator
(`koreader-fixtures`) runs the same pinned build in a clean environment and with
it makes 14 fixtures holding 56 validated operations between them: 33
highlights, 14 annotations and 9 bookmarks, across thirteen Markdown sources and
one plain-text source. Every fixture carries an `expected.json` with the
requested operations, and where source and rendered text differ also the
zero-based byte bounds in the source. Those bounds come from the declarative
scenario markers and are therefore independent of any matching code.

What that corpus adds is above all the rare case: nine bookmarks instead of
one, the same text three times in one document, all nine colours, text ranges on
the document boundaries, and a source with CRLF and tabs.

Where the corpus does not demonstrate a property, that is stated in the section
[Limits of the evidence](#limits-of-the-evidence).

## File layout

Path convention for a source file `notes.md`:

```text
notes.md
notes.sdr/
├── metadata.md.lua
└── metadata.md.lua.old
```

The extension of the source file is **dropped** in the directory name and
**kept** in the file name:

| | |
|---|---|
| source file | `reading-notes.md` |
| sidecar directory | `reading-notes.sdr` |
| metadata file | `metadata.md.lua` |

This holds in all 7 sidecars of the corpus. The directory name is therefore
`<file name without its last extension>.sdr`, the metadata file
`metadata.<extension>.lua`.

This corpus shows only sidecars sitting beside the source file. KOReader also
knows other storage locations for metadata (a central directory, a hash-based
location); those were not observed here and cannot be derived from the source
path alone.

`metadata.md.lua.old` is KOReader's own previous version; it is present in 2 of
the 7 sidecars in the corpus. It is a full sidecar file with the same
structure, holding older content.

### Optional annotation export file

The controlled fixture holds in addition:

```text
source.sdr/source.md.annotations.lua
```

This file appears because **Export annotations on book closing** was active
during the fixture session. By default KOReader writes it in the sidecar
directory; `annotations_export_folder` can point at another export directory.
It is not a second standard metadata file, and its presence has not been
demonstrated as a difference between `v2026.07` and `v2026.07.1`. The seven
original sidecars lack it; their export setting and any external export
directory were not recorded.

In the fixture the `annotations` block is byte-identical to the one in
`metadata.md.lua`. Besides that, the file holds only:

| key | meaning |
|---|---|
| `datetime` | the moment KOReader wrote the export |
| `device_id` | identity of the exporting KOReader installation |

The pinned `readerannotation.lua` shows the purpose. On closing, KOReader
writes this file only when the export option is active. On opening, a file with
the same `device_id` is ignored. A file from another device is removed after it
has been read in and merged with the local annotations on position and
modification date; **Keep all annotations on import** governs how missing items
are treated in that merge.

So it is an optional export/import transport for exchange between devices, not
simply a second authoritative source. A reader must not import it alongside
`metadata.md.lua` as a duplicate. Future write support does have to detect it
and account for the export/import mode explicitly, because an old file on
another device can be fed back in.

## Lua syntax of the file

Every file has this shape:

```lua
-- /mnt/onboard/Markdown/reading-notes.sdr/metadata.md.lua
return {
    ["annotations"] = {
        [1] = {
            ["chapter"] = "2. The first storm surge",
            ...
        },
    },
    ["doc_pages"] = 6,
    ...
}
```

Constructs occurring in the corpus:

| construct | shape |
|---|---|
| line comment | `-- ...` as the first line, with the absolute path on the device |
| top level | `return { ... }` |
| string keys | only `["name"]`, never `name =` |
| numeric keys | only `[1]`, `[2]`, ... explicitly in bracket form |
| strings | double quotes |
| numbers | integers and decimals (`20240114`, `0.11111111111111`) |
| booleans | `true` / `false` |
| empty table | `{}` (e.g. `performance_in_pages`) |
| nested tables | up to 3 levels deep |
| trailing comma | after every element, the last one included |

Two escape forms occur in the original corpus:

| escape | count | meaning |
|---|---|---|
| `\"` | 111 | double quote in the value |
| backslash followed by a **physical line break** | 5 | line continuation; yields a line break in the value |

The second form means that string values can stretch across several lines of
the file:

```lua
["text"] = "four space code\
second code line",
```

A parser that looks for a string value with a line-bound pattern misses these
cases silently.

The pinned serializer fills out the empirical picture. `LuaSettings:flush` uses
the ordered `dump` serializer; strings go through `string.format("%q")`. A trial
with the runtime from the official `v2026.07` fixture AppImage
(`LuaJIT 2.1.1783773675`) yields among other things `\9` for tab, `\13` for CR
and decimal escapes for other control bytes. Numbers go through `tostring` and
can therefore also use exponent notation. `dump.lua` additionally knows `nil`;
none of these further forms was observed in the 191 original annotations or the
four fixture entries.

The production parser must therefore support the data output of this
serializer, but keep refusing functions, cyclic tables, non-finite numbers and
other executable Lua constructs.

`nil` does not occur: absent values are left out rather than set to nil
explicitly.

## Writing it back

Reading the format is one thing; giving it back unchanged is another, and it is
the harder requirement. Most of a sidecar is reader state — font size, margins,
reading position — plus keys no version of this package has seen. A rewrite may
disturb none of it, so the yardstick is not "valid Lua" but "the same bytes".

The serializer's rules, read off the files it produces:

| | |
|---|---|
| indentation | four spaces per level |
| entries | `["key"] = value,`, always with the trailing comma |
| list keys | `[1]`, in brackets and without quotes |
| empty table | `{}`, on the line of its key |
| strings | Lua's `%q`: `\"` and `\\`; a newline as a backslash followed by a real newline; other control characters as unpadded decimal escapes such as `\9` and `\13` |
| preamble | one comment line naming the file's own path |

Every sidecar in this repository — the twenty-two generated ones over both
document families, plus the two a real KOReader wrote — survives reading and
writing back character for character. The test is
`nothing-changes-in-a-round-trip`.

Two things that test does not settle.

**Key order.** The writer reproduces the order it read. Every sidecar here is
already in sorted key order, so the round trip cannot tell "preserve" from
"sort" apart: replacing one rule with the other changes not a byte in any of
the twenty-four files. Only a list of ten or more entries separates them, since
sorting keys as text puts `[10]` before `[2]`; that case has a test of its own
rather than a fixture.

**A newline written as `\10`.** It would read back as the same character and be
written out as a line continuation, so the file would change while its meaning
did not. No file in the corpus contains it, and no KOReader version is known to
produce it.

Round-tripping the representation is also not the same as modifying a sidecar
safely: an unchanged file staying unchanged says nothing yet about what happens
when an annotation is added, moved or removed.

## Top-level keys

The corpus counts ~57 top-level keys. Only a handful of them touch annotations;
the rest is reader state that by definition has to be preserved on every write.

Relevant to annotation handling:

| key | type | meaning |
|---|---|---|
| `annotations` | table | the annotations, see below |
| `doc_path` | string | absolute path on the reading device |
| `doc_pages` | number | number of pages at the current render settings |
| `partial_md5_checksum` | string | document identity, e.g. `bddb469199955cee0dc9d2960720782b` |
| `cre_dom_version` | number | DOM version of CRengine, e.g. `20240114` |
| `highlight_color` | string | default colour for new highlights |
| `highlight_drawer` | string | default style for new highlights |
| `last_xpointer` | string | reading position, same XPointer shape as `pos0` |
| `doc_props` | table | `{ title = ... }` |
| `summary` | table | `{ modified = "2026-08-08", status = "complete" }` |
| `stats` | table | among others `highlights`, `notes`, `pages`, `title` |

`cre_dom_version` determines how CRengine turns the document into a DOM, and
with that whether the XPointers in `pos0`/`pos1` still point at the same place.

`stats.highlights` counts the annotations **without** a `note`, `stats.notes`
the ones with. Together they equal the number of items in `annotations` in all
7 sidecars:

| sidecar | `highlights` | `notes` | items in `annotations` |
|---|---|---|---|
| 1 | 64 | 0 | 64 |
| 2 | 0 | 0 | 0 |
| 3 | 21 | 0 | 21 |
| 4 | 3 | 0 | 3 |
| 5 | 29 | 2 | 31 |
| 6 | 36 | 1 | 37 |
| 7 | 34 | 1 | 35 |

The seven original sidecars have no bookmarks. The controlled fixture confirms
what the KOReader source indicates: `stats.highlights = 2` and `stats.notes = 1`
with four entries in total; the bookmark without a `drawer` is not counted. The
usable cross-check is therefore:

```text
stats.highlights + stats.notes == number of annotations with a drawer
```

and not the total number of items in `annotations`.

The remaining keys are render settings (`copt_*`, `font_*`, `hyph*`, `css`,
`text_lang`) and UI state (`config_panel_index`, `readermenu_tab_index`,
`page_overlap_style`, `handmade_*`).

## The annotation table

`annotations` is an array with consecutive numeric keys from 1, in document
order.

### Keys per annotation

Measured across 191 annotations:

| key | present | type | content |
|---|---|---|---|
| `chapter` | always | string | heading of the section the annotation falls in |
| `color` | always | string | `"yellow"` throughout the corpus |
| `datetime` | always | string | `"2026-08-08 23:09:32"`, moment of creation |
| `drawer` | always | string | `"lighten"` throughout the corpus |
| `page` | always | string | XPointer, **identical to `pos0`** in 191/191 cases |
| `pageno` | always | number | page number at the current render settings |
| `pos0` | always | string | XPointer to the start of the selection |
| `pos1` | always | string | XPointer to the end of the selection |
| `text` | always | string | the selected text as rendered |
| `note` | 4 of 191 | string | note typed by the user |
| `datetime_updated` | 5 of 191 | string | moment of last modification |

There is **no `kind` or `type` field** and **no stable annotation ID**.

### Where `chapter` comes from

`chapter` is the nearest entry from KOReader's table of contents, which
CRengine builds from the headings of the source file. For Markdown that means:
the values are literally the `##` headings. Measured on a document with four
such headings, all four of the occurring `chapter` values match the headings in
the source character for character.

The `#` heading on line 1 does *not* become an entry in the table of contents;
it counts as the document title. Across all seven sidecars, not a single
`chapter` value matches the `#` heading of its file.

What an annotation before the first `##` gets as its `chapter` cannot be
derived from this corpus: all 191 annotations have a `chapter`, and it is a `##`
heading every time. Such annotations simply do not occur here.

In the controlled fixture these fields stay the same, with two additions: the
green highlight has `color = "green"`, and the bookmark lacks the four range
fields `color`, `drawer`, `pos0` and `pos1`.

### Telling the kinds apart

The distinction follows from which fields are present, not from an explicit
field. Established in this corpus:

```text
drawer present, note absent   → highlight
drawer present, note present  → highlight with a note
```

For the third case the KOReader source
([`readerannotation.lua`](https://github.com/koreader/koreader/blob/master/frontend/apps/reader/modules/readerannotation.lua))
gives:

```text
drawer absent                 → bookmark
```

A bookmark can carry an automatically generated `text`, but that is not a text
range the user selected. The controlled fixture confirms this: the bookmark
lacks `drawer`, `color`, `pos0` and `pos1`, does have `page`, `pageno` and an
automatically generated `text`, and is counted in neither `stats.highlights` nor
`stats.notes`.

### What `page` points at for a bookmark

The nine bookmarks from the generated corpus show that `page` is not the place
the reader pointed at but the **first character of the rendered page** the
bookmark sits on.

The proof is in the cases that come out on the same page. Four bookmarks in four
different documents were set in four different places and all four yield
`"/html/body/h1/text().0"` — the start of the document. All four were on page 1.
Two bookmarks set further along come out at `p[20]/text().49` and
`p[15]/text().107`: in the middle of a paragraph, at precisely the place where
the page break fell.

The position is therefore exact, but it means "this page" and not "this
sentence". It also depends on the layout with which KOReader broke the document;
at another font size the page boundary falls elsewhere. The generator ran into
this itself: after a re-render KOReader chose different page boundaries.

### Fields a bookmark can lack

`chapter` and `text` are both optional. In the plain-text fixture the bookmark
has only `datetime`, `page` and `pageno`:

```lua
[4] = {
    ["datetime"] = "2026-08-15 08:15:12",
    ["page"] = "/FictionBook/body/pre[9]/text().42",
    ["pageno"] = 2,
},
```

The highlights in that same document do have a `chapter`, but as an empty
string. A document without a table of contents therefore yields `""` for a text
range and nothing at all for a bookmark.

`datetime_updated` appears on modification. Of the 5 annotations with a
`datetime_updated`, 4 have a `note`; the fifth is a highlight of which something
else was changed. `datetime_updated` is therefore not a reliable indicator of
"has a note".

## XPointers: `pos0` and `pos1`

These are CRengine XPointers into the HTML DOM that KOReader generated from the
Markdown.

### Shape

```text
/html/body/p[2]/text().221
/html/body/ul[1]/li[1]/strong/text().10
/html/body/p[7]/text()[2].43
/html/body/ul[3]/li[2]/ol/li[1]/em/text().5
```

An XPointer consists of a path to a text node plus an offset after a dot.
`text()[2]` denotes the second text node within an element; that numbering
arises because inline elements (`em`, `strong`) split up the text of their
parent.

Path shapes in the corpus, by frequency:

| pattern | count |
|---|---|
| `/html/body/ul[N]/li[N]/text().N` | 65 |
| `/html/body/p[N]/text()[N].N` | 46 |
| `/html/body/ul[N]/li[N]/text()[N].N` | 19 |
| `/html/body/p[N]/text().N` | 17 |
| `/html/body/ul[N]/li[N]/strong/text().N` | 13 |
| `/html/body/hN[N]/text().N` | 9 |
| `/html/body/ul[N]/li[N]/p/text().N` | 4 |
| `/html/body/p[N]/em[N]/text().N` | 4 |
| `/html/body/ul[N]/li[N]/p/strong/text().N` | 3 |
| `/html/body/ul[N]/li[N]/em/text().N` | 3 |
| remaining (`ol`, nested `ol` in `ul`, `p/em`) | 8 |

The elements that occur — `p`, `ul`, `ol`, `li`, `h1`..`hN`, `em`, `strong` —
correspond one-to-one with Markdown constructs: paragraph, bullet list,
numbered list, heading, italic, bold.

### Plain text gets a different tree

A `.txt` file yields an entirely different path shape. The plain-text fixture
from the generated corpus gives:

```text
/FictionBook/body/pre[2]/text().0
/FictionBook/body/pre[4]/text().4
/FictionBook/body/pre[9]/text().42
```

Not `/html/body` but `/FictionBook/body`, and not `p` but `pre`. The numbering
counts the non-blank lines of the file: `pre[2]` is the second non-blank line,
`pre[4]` and `pre[5]` are two consecutive lines of the same indented block. A
blank line gets no `pre` of its own.

A Markdown source and a plain-text source are therefore two different document
families, even though the same KOReader carries them both.

### Offsets are character offsets

Measured: for the 164 annotations whose `pos0` and `pos1` lie in the same text
node, in **163 cases**:

```text
offset(pos1) - offset(pos0) == number of characters in text
```

Zero cases match the number of *bytes*. The offset therefore counts characters,
not UTF-8 bytes — despite the presence of Greek, accents and arrows in the
corpus.

The one deviating case has a delta of 45 with a `text` of 44 characters, in a
list line (`ul[4]/li[2]`, offsets 86→131). The offset range is one character
wider there than the stored text.

One observation is too few to determine which of the two is authoritative. All
that has been established is that **offset range and stored text can differ**. A
resolver ought to signal that difference rather than silently follow one of the
two, and verify it by way of the projection.

## Text representation

`text` holds the **rendered** text, not the Markdown source.

### Markup is removed

From the generated corpus, fixture `006-markdown-emphasis`. Source:

```markdown
This contains **bold words** in a sentence
```

Stored `text`:

```text
This contains bold words in a sentence
```

The `*` characters are not in `text`. The same goes for `*italic*` and for
`` `code` ``.

Note the consequence for the offsets. With a selection starting halfway through
the markup, `pos0`/`pos1` in that same fixture sit on byte range 71→93 of the
source, which covers `contains *italic words` there — the opening asterisk
counts and the closing one does not. The offset range therefore follows the
source and `text` the representation, and those two diverge on precisely the
markup.

### Block boundaries are joined, in more than one way

With a selection across block boundaries the source markup disappears and the
blocks are written together. The corpus shows two different separators for
that.

**With a space.** In one document a selection of a list line continues into the
paragraph after it — two separate blocks. In `text` the two blocks sit one after
the other with a single space between them, without any trace of the block
boundary.

**With a line break.** A selection across several `li` elements does keep a
separation: there is a line break in `text`. Visible in the generated corpus,
fixture `007-render-boundaries`:

```text
First list crossing begins with amber rope
Second list crossing ends with a blue knot
```

Both observed cases with a line break in `text` run across `li` boundaries; the
observed cases with a space run between a list or heading block and a following
paragraph. Two observations are too few to make a rule of this — all that has
been established is *that* the separator varies, not what varies it.

### In a `pre` the offsets count the source, not the text

With a Markdown source the offsets count the rendered text: `text` and the
offset range are the same length, one deviation aside. In a `pre` that falls
apart. The offsets count the line as it stands in the file, while `text` keeps
the collapsed representation:

```text
source  Multiple   spaces stay visible.     31 characters
text    Multiple spaces stay visible.       29 characters
offsets 0 → 31
```

A selection across two indented lines shows the same thing from the other side.
`pre[4]` offset 4 to `pre[5]` offset 20 runs in the source across
`four space code` plus the complete line `    second code line` — indentation
and all — while `text` makes `"four space code\nsecond code line"` of it. So
across the line boundary the indentation of the following line disappears too.

A no-break space (U+00A0) does not take part in that collapsing: it sits as
U+00A0 in `text`, exactly as in the source. What the renderer joins up is
ordinary whitespace.

Consequence for comparing offset range and text length: in a `pre` a difference
proves nothing. There it is the normal state of affairs.

### Consequence for text matching

Measured: does `text` occur verbatim in the source file?

| situation | found verbatim | not found |
|---|---|---|
| `pos0` and `pos1` in the **same** text node (164) | **164** | 0 |
| `pos0` and `pos1` in **different** text nodes (27) | 0 | **27** |

Found verbatim does not mean found unambiguously. Of the 164 hits, 159 are
unique in the source file; 5 occur more than once and therefore yield several
candidates:

| length of the text | number of occurrences in the source |
|---|---|
| one word | 9 |
| one word | 7 |
| one word | 3 |
| two words | 2 |
| two words | 2 |

The pattern is that short selections become ambiguous and longer ones do not.
That is no law — a long sentence appearing twice in a book is just as ambiguous,
and the generated corpus contains such a case deliberately — but it does explain
why in ordinary prose there are only five of the 164.

The separation is complete in this corpus: annotations within one text node are
always to be found verbatim in the source, annotations crossing a node boundary
never — precisely because there is markup or a block boundary in between that
has dropped out of `text`.

**The generated corpus shows an exception to the first half.** A selection
across two lines of a blockquote stays within one text node:

```text
pos0  /html/body/blockquote/p/text().0
pos1  /html/body/blockquote/p/text().68
text  A quoted passage appears here. It continues on a second quoted line.
```

In the source there is a `> ` at the start of the second line. So the text is
one text node *and* not to be found verbatim. What the seven original documents
showed — the same text node means verbatim in the source — held because there
were no blockquotes in them. One text node means the text is rendered
*contiguously*, not that the source has no characters in between that the
renderer leaves out.

For the resolver that is no disaster: if the text search fails, the projection
is left, and that one does know about the quote markers.

Whitespace normalisation (`\s+` → space, on both sides) rescues **not a single
one** of those 27 cases. What is missing is not one kind of character: emphasis
markup (`*`, `**`), list markers, inline structure, and block separations that
come back now as a space and now as a line break. None of those is whitespace,
and no single substitution rule covers them together.

What follows from this is more modest than it looks: `pos0` and `pos1` tell you
in advance which of the two categories an annotation falls into. That takes only
the comparison of two path strings, no reconstruction of the DOM. *Resolving* an
XPointer to a buffer position is a separate and much heavier step, which does
depend on a block division matching CRengine's.

## Document identity

`partial_md5_checksum` is a checksum over parts of the source file — a content
fingerprint, not a document identity. It changes when the document changes, two
identical files share the same value, and it says nothing about which local path
belongs to the document. Usable as a signal that source and sidecar belong
together; not as a lasting key.

`doc_path` holds the path on the reading device (`/mnt/onboard/Markdown/...`),
which does not match the path on the computer.

Per annotation there is no identifier. `datetime` is stable;
`datetime_updated` changes on modification. `text` is no safe component of an
identity: KOReader lets the highlight text itself be edited too, which would
make a text correction yield a different identity.

## Limits of the evidence

The corpus does not demonstrate the following:

- **Other highlight styles.** All nine colours were observed in the generated
  corpus, but every time with drawer `lighten`. Other drawer values have not
  been measured.
- **Mandatory versus incidental fields.** That a field is present everywhere
  does not make it mandatory; it may depend on the KOReader version used or on
  the document type. The bookmark without a `chapter` and `text` shows how
  quickly such an assumption falls.
- **What a bookmark does on a re-rendered page.** `page` points at the start of
  the rendered page, and that boundary depends on the layout settings. What
  value ends up in the sidecar after a change of font size or margins has not
  been measured here.
- **Other source formats.** The documents are Markdown, one plain-text file
  aside. EPUB, PDF and other formats have different XPointer structures.
- **What the serializer can emit.** Observed are `\"` and line continuation. How
  KOReader serializes backslashes, tabs or other characters, and which number
  forms occur, does not follow from this.
- **Behaviour on re-render and migration.** All sidecars were written under
  `cre_dom_version = 20240114`. What happens to existing XPointers on a DOM
  version change or a format migration does not follow from this.

## Reproduction

The numbers about the seven original sidecars come from `test/analyse-corpus.py`,
which reads the sidecars as text without executing any Lua:

```sh
python3 test/analyse-corpus.py                 # the corpus in this repository
python3 test/analyse-corpus.py DIRECTORY ...   # any other sidecars
```

Those seven sidecars are a private reading corpus and are not part of this
repository, so the block below is a record rather than something the command
above will reproduce. The script itself does run: without an argument on the
generated corpus, and with an argument on any directory holding `*.sdr` folders.
Turning it on a corpus of your own is the way to find out whether your books
contain shapes the fixtures do not cover.

The script reports the counts, the key sets per annotation, the XPointer path
shapes and every deviation separately, so that the derived numbers are checkable
rather than assumed. Measured outcome on that private corpus:

```text
escape \"                                : 111
escape line continuation                 :   5
annotations                              : 191
page == pos0                             : 191
pos0/pos1 same text node                 : 164
  same node: text verbatim in source     : 164
    of which unique                      : 159
    of which several candidates          :   5
  offset delta == characters             : 163
  offset delta deviates                  :   1
text holds a line break                  :   2
pos0/pos1 across node boundaries         :  27
  cross-node: text verbatim in source    :   0
with a note                              :   4
with datetime_updated                    :   5
```

It fails hard when an annotation lacks one of the expected fields, instead of
yielding a count that looks right. That is not a theoretical precaution: an
earlier version of this document held figures polluted by a line-bound pattern
silently skipping five `text` values. Which fields count as expected differs per
kind, and follows the evidence: every annotation has `datetime`, `page` and
`pageno`, but `chapter` and `text` are demanded of text ranges only, because a
bookmark set before the first heading carries neither.

The classification "same text node" is the literal comparison of the part of
`pos0` and `pos1` before the last dot; the offset distance is the difference of
the numbers after it.

Against a source that is not plain text the stored text cannot be looked up, so
for EPUB the verbatim comparisons are reported separately instead of counted as
a miss. Everything that follows from the sidecar alone — key sets, path shapes,
offset distances, escape forms — is counted for those too.

The statements about the generated corpus come from `test/analyse-fixtures.el`.
That script runs our own source position finding on every fixture and lays the
outcome beside `expected.json`:

```sh
emacs --batch -Q -L . -l test/analyse-fixtures.el \
      -f org-remark-koreader-fixtures-main [path-to-corpus]
```

It compares against two truths, neither of which comes out of our own matching:
the byte bounds from the scenario markers, and otherwise the Nth verbatim
occurrence of the stored text. Where the source has a line break and the sidecar
a space, any run of whitespace may match any other.

`test/run-tests.sh` calls the script when the corpus is present, and skips it
otherwise: the corpus lives in a repository of its own and is not among the
conditions for being able to run the suite.
