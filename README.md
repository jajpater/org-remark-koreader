# org-remark-koreader

Makes KOReader annotations visible and editable in Emacs, as
[org-remark](https://github.com/nobiot/org-remark) marks with marginal notes.
Works on Markdown, plain text and EPUB.

The KOReader sidecar is only ever read. Source file and sidecar stay
byte-identical; that is a test, not a promise.

*Dit document is er ook [in het Nederlands](README-nl.md).*

## Use

The same file sits on the e-reader and on the computer:

```text
reading-notes.md
reading-notes.sdr/
└── metadata.md.lua
```

Open the file in Emacs and call:

```text
M-x org-remark-koreader-import
```

The marks appear as overlays; notes can be opened and edited with the ordinary
org-remark commands (`org-remark-open`, `org-remark-view-next`).

Mind the directory name: the extension drops out of the `.sdr` directory and
stays in the metadata file. So `reading-notes.sdr/metadata.md.lua`, not
`reading-notes.md.sdr/`.

For an EPUB it works just the same, but then in `nov-mode`. Switch
`org-remark-koreader-mode` on and import; the whole book is walked, chapter by
chapter.

## The commands

| command | what it does |
|---|---|
| `org-remark-koreader-import` | reads the sidecar and places what can be placed reliably |
| `org-remark-koreader-reload` | clears the marks first and then builds them up again |
| `org-remark-koreader-report` | what the last import yielded, including what was *not* placed |
| `org-remark-koreader-inspect-mark` | where the mark under your cursor came from |
| `org-remark-koreader-mode` | buffer-local; switches org-remark on, and in an EPUB `org-remark-nov-mode` as well |

Import as often as you like: a second time yields no duplicates, and a note you
have edited in Emacs stays as it is.

`reload` is there for when the buffer no longer matches — after you have changed
the source, for instance, and marks have been left behind that belong to nothing
any more. The notes file then leads: everything is thrown away and read back
from there, and only after that does the sidecar come alongside again.

`inspect-mark` answers the question a coloured piece of text cannot answer
itself: where does this come from? It shows kind, chapter, colour, KOReader's
XPointers, where the mark ended up here and how that place was determined.

## What it places and what it does not

KOReader keeps *rendered* text. `**bold words**` in the source becomes
`bold words` in the sidecar, and a selection across block boundaries is written
together. Because of that the stored text is not always to be found verbatim in
the source file.

Every mark gets a `confidence` that says *how* its position was determined. An
estimated position is never presented as an exact one.

| confidence | meaning |
|---|---|
| `exact` | the stored text was there unambiguously |
| `disambiguated` | several candidates, brought down to one with an independent signal |
| `projected` | determined by way of the XPointer, not by way of the text |
| `joined` | a selection across a block boundary, assembled from its parts |
| `approximate` | found with a wider rule than the other routes |
| `elsewhere` | belongs to a chapter that is not in the buffer at the moment |
| `unresolved` | reported instead of placed |

**Unambiguous text** is searched for literally — the stored text is data, not a
pattern. **Ambiguous text** is narrowed only with hard bounds: the position of a
neighbouring mark that is itself resolved unambiguously, the section of a
heading that occurs only once, and the XPointer. If more than one candidate is
left, the mark is reported instead of placed. A wrongly placed mark is worse
than an unresolved one.

**Text across node boundaries** cannot be searched for. With Markdown and plain
text it goes by way of the projection: the package rebuilds the document
structure KOReader sees and translates the XPointer back into a source position.
That projection is never taken at its word — the projected range has to
reproduce the stored text, and only then does it count.

**Bookmarks** have no text range and therefore nothing to search for. They are
placed on their `page` XPointer, as a point marker without length. Mind what
that place means: `page` is the start of the rendered page the bookmark sits on,
not the sentence you pointed at. Four bookmarks across four fixtures sit on page
1, and all four come out at the top of the document.

That same XPointer is what makes a bookmark resistant to changes in the source.
Where a highlight has to find itself back on its text after a source change, the
XPointer names a block and an offset within it; if text is added elsewhere, the
bookmark simply moves along.

## Three document families

KOReader does not render every file the same way, and that shows in its
XPointers. Which family applies is therefore stated in the sidecar itself — a
more reliable signal than the file name.

| source | XPointer | how the package finds the position |
|---|---|---|
| Markdown | `/html/body/p[2]/text().26` | own tree rebuilt from the source |
| plain text | `/FictionBook/body/pre[9]/text().42` | the same, with one `pre` per non-blank line |
| EPUB | `/body/DocFragment[3]/body/p[1]/text().0` | the XHTML says what is there, the nov buffer says where |

With Markdown and plain text, KOReader and Emacs read the same file, so the tree
can be rebuilt. With EPUB it cannot: `nov-mode` shows what **shr** makes of the
XHTML and KOReader what **CRengine** makes of it. There no tree is built — the
XPointer points out the chapter and the element, and the text does the rest.

In a `pre` the offset counts the source untouched instead of the collapsed text;
in the other two families it counts the rendered text. That difference was
measured, not chosen.

## Notes and local edits

An imported note goes into the Org file in full. If you edit it there
afterwards, a following import leaves it alone — including when you have emptied
it.

That works by way of a baseline: on every successful import the hash of the note
is stored in the property `org-remark-koreader-note-hash`. That baseline turns
it into a three-way comparison — last imported, current in KOReader, current in
Org — so that it becomes visible who changed something:

| who changed something | behaviour |
|---|---|
| nobody | unchanged |
| KOReader only | refresh |
| you only | your text stays |
| both | conflict — your text stays, and you get to see it |

Without a baseline the rule is: an empty body is filled, a filled body stays.
The deciding signal is therefore not whether the body is empty but whether there
is a baseline — a note emptied *after* an import is a deliberate removal and is
not filled again.

Body and baseline are always written in the same operation, so that an
interruption never leaves a baseline without a body.

## Importing again

Importing is not an add operation but a comparison of two sides. The report
states what is new, what KOReader itself changed (colour, text), and what has
disappeared from the sidecar.

An annotation you deleted in KOReader is **not** automatically removed from your
Org file — the note you wrote alongside it would disappear with it. It is
reported, with its ID, so that you can decide yourself.

Annotations you made with org-remark yourself stay outside this comparison.

## Settings

| variable | meaning |
|---|---|
| `org-remark-koreader-sidecar-resolver` | function that finds the sidecar path, for non-standard KOReader layouts |
| `org-remark-koreader-color-faces` | KOReader colour to face |
| `org-remark-koreader-unknown-color-face` | face for an unknown colour |
| `org-remark-koreader-lua-max-*` | bounds for file size, depth, number of fields and string length |

An unknown colour never quietly gets the face of a known colour; the original
name is kept.

## Safety

The sidecar is read, never executed: no `load`, no external Lua interpreter, no
shell call. The reader accepts the subset of data KOReader's serializer writes
and refuses all the rest — function calls, identifiers as values, non-finite
numbers, text after the table. Bounds on file size, nesting depth, number of
fields and string length rule out memory exhaustion.

## Build

```text
org-remark-koreader.el          commands, pens, org-remark adapter
org-remark-koreader-lua.el      restricted Lua reader
org-remark-koreader-lua-write.el  the same format written back, byte for byte
org-remark-koreader-model.el    normalised annotation model, identity
org-remark-koreader-match.el    source position finding, the ladder
org-remark-koreader-dom.el      the source rebuilt as a CRengine tree
org-remark-koreader-epub.el     the EPUB family, by way of nov.el
```

Nothing loads `-lua-write.el`: it produces text and touches no file. It is
there because giving a sidecar back unchanged had to be proven before anything
may ever write one.

The reader knows nothing of Markdown, the model nothing of org-remark, and
`-match.el` nothing of EPUB: that family registers itself in a registry. That
keeps the knowledge of nov.el in one file, which does not have to require nov in
order to be loaded.

## Trying it out without polluting the repo

An import writes a `marginalia.org` beside the source file. To keep that outside
the repo:

```sh
test/sandbox.sh                # show the available documents
test/sandbox.sh fixture        # put one ready in a throwaway directory
```

Open the path that comes out and import there.

## Tests

```sh
test/run-tests.sh
```

Finds org-remark and nov.el by itself; otherwise point at org-remark with
`ORG_REMARK_DIR`. What is not there is skipped rather than missed.

Among other things the suite checks that no placed mark points at the wrong
text, that the rebuilt tree yields the same positions as the sidecar describes,
that a bookmark of zero length survives org-remark's housekeeping, and that
import, saving, closing and reopening preserve both mark and note without
duplicates.

The check for the wrong text is the one that carries the most weight. It runs
the real source position finding on the generated corpus and lays every outcome
beside the byte bounds the generator derives from its own scenario markers —
independent of anything this package does. That is the only check that can see a
mark sitting in the *wrong* place instead of only that it sits somewhere. The
suite holds it as a test in `test/org-remark-koreader-corpus-tests.el`, and
`test/analyse-fixtures.el` prints the same measurement per fixture with the
details of every deviation. Outcome:

```text
Markdown and plain text    47 of the 47 text ranges, 9 of the 9 bookmarks
EPUB                       41 of the 41 operations
```

The corpus comes from
[koreader-fixtures](https://github.com/jajpater/koreader-fixtures), where it is
generated with a pinned KOReader build.

`test/analyse-corpus.py` looks at the other side: not at our matching, but at
the sidecars themselves. It reads the Lua purely as text — nothing is executed —
and counts what the format actually contains.

```sh
python3 test/analyse-corpus.py                 # the corpus in this repo
python3 test/analyse-corpus.py ~/books         # your own sidecars
```

Point it at any directory and it walks that directory for `*.sdr` folders. Turn
it on your own reading corpus to see whether your books hold shapes the fixtures
do not cover — a colour, an XPointer path or an escape form we have not
measured. Sources that are not plain text, an EPUB being an archive, still count
towards everything that follows from the sidecar alone.

## Background

- [`docs/design.md`](docs/design.md) — why the package is built the way it is:
  the choices, the alternatives weighed against them, and what the measurements
  ruled out
- [`docs/koreader-current-format.md`](docs/koreader-current-format.md) — what
  the sidecar format actually is, measured
- [`docs/org-remark-current-api.md`](docs/org-remark-current-api.md) — the
  org-remark API, life cycle and hook points
- [`docs/epub-and-nov.md`](docs/epub-and-nov.md) — the other end of the EPUB
  route: what `nov-mode` makes of a book, and how a KOReader XPointer finds its
  way in that
- [`docs/notes-storage.md`](docs/notes-storage.md) — where org-remark keeps
  its annotations, what constrains moving them, and a running experiment that
  serves them straight out of the sidecar

## Licence

GPL-3.0-or-later.
