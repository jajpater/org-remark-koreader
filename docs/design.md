# Why it is built this way

This document records the trade-offs. What the package *does* is in the
README; what the sidecar format actually *is* is in
`koreader-current-format.md`; how org-remark fits together is in
`org-remark-current-api.md`. Here is why the choices fell the way they did —
including the ones that turned out differently than expected.

## The rule that drives everything

**A wrongly placed mark is worse than an unresolved one.**

A mark that is missing you notice at once, and the note that goes with it is
still there in the Org file. A mark in the wrong place looks like a good one.
It colours a sentence the reader never pointed at, and nothing in the display
gives away that anything is wrong.

That is why `confidence` is not a side issue but a first-class notion. Every
mark carries *how* its position was determined, every route has a name of its
own, and an estimated position is never presented as an exact one. What cannot
be placed reliably gets no overlay but a line in the report, with the stored
text, the KOReader position and the observations that led to the decision.

It is also why there is nowhere a fallback to "the nearest place". A path that
does not exist in the reconstructed tree yields nil, not a guess. An offset
reaching beyond its element yields nil. Two candidates that neither can be
ruled out yield nil. That feels meagre, but it is the only answer that does not
lie.

## Fixtures before design

For every new source format the fixture set comes first, and only then the
design of the coupling. That is not caution but a lesson learned three times.

The DOM model that translates KOReader's XPointers into source positions was
not thought up in advance but derived from measured data: the path shapes were
counted, the collapsing of whitespace was traced back from a deviation of one
character, and the joining rule across block boundaries came out of three cases
that did not fit.

After that, every new fixture set produced something nobody had guessed:

- **In a `pre` the offsets count the source untouched**, not the collapsed
  text. In the HTML tree it is precisely the other way round. Without a
  plain-text source in the corpus that difference would never have been found.
- **`DocFragment[N]` is the Nth spine item, but nov's numbering is no shift of
  it.** nov removes the navigation document from the spine and prepends it
  again, so the relationship differs per book. Without an EPUB with several
  chapters *and* a navigation document inside the spine, a piece of arithmetic
  would have been built in here that happens to be right for most books.
- **A bookmark with an offset in the middle of a text node** laid bare that the
  element was being searched for by its text and the first hit taken — three
  out of three ended up in the wrong place, and were reported with confidence.

The negative cases do not belong in the fixtures. An invalid offset or a
mangled sidecar becomes a unit test: a forged sidecar proves nothing about
KOReader.

## Three document families

KOReader does not render every file the same way, and that shows in its
XPointers:

```text
Markdown       /html/body/p[2]/text().26
plain text     /FictionBook/body/pre[9]/text().42
EPUB           /body/DocFragment[3]/body/p[1]/text().0
```

**The choice follows from the sidecar, not from the file name.** KOReader picks
its renderer by file type and then states in its own XPointers which tree that
produced. That is the most reliable signal there is: it sits in the data
itself, and it keeps holding when someone renames a file.

`-match.el` knows only the families that rest on a reconstructed tree. A family
for which that does not hold registers itself in a registry instead of being
built in. That keeps the knowledge of nov.el in one file, which does not have
to require nov in order to be loaded.

### Markdown and plain text: rebuilding the tree

KOReader and Emacs read the same file here. The stored text is rendered —
markup gone, blocks run together — so it is not always in the source verbatim.
But the source *is* there, so the tree CRengine saw can be rebuilt, and then an
XPointer translates back into a source position.

The projection is never taken at its word. The projected range has to reproduce
the stored text — including the joining rules across block boundaries — and
only then does it count. So `text` remains the verification on this route too,
exactly as with searching for the text.

### EPUB: no tree

Here KOReader and Emacs read the same XHTML, but Emacs does not show that
source: `nov-mode` shows what **shr** made of it, KOReader what **CRengine**
made of it. One source, two independent renderers.

Rebuilding a tree makes no sense there — we would have to predict another
program's rendering. Nor is it necessary, because measurement shows the stored
text appears verbatim in the nov buffer. The XPointer is therefore not the
route to the position but the indication of *which* chapter and *which*
element; the text does the rest.

That the chapter is fixed is a gain, not a limitation. KOReader sees the whole
book as one DOM, so a sentence occurring twice yields two candidates there. In
`nov-mode` one chapter sits in the buffer, and within it that same sentence is
often unambiguous.

For what the text cannot tell apart — two paragraphs alike word for word in one
chapter — there is the structure: how many alike elements of the same kind
precede this element in the document? That is the second one in the buffer if
it is the second one in the document. Only elements of the same kind count; an
enclosing element carries the same text as soon as it contains nothing else.

## The ladder

The order is deliberate: all the unambiguous cases first, the ambiguous ones
only afterwards. Otherwise a narrowing would rest on bounds that are not yet
settled.

1. **Unambiguous text** — searched for literally. The stored text is data, not
   a pattern; it goes through `regexp-quote`. (That org-remark itself does not
   do this is a bug reported separately.)
2. **Ambiguous text** — narrowed with hard bounds: the position of a
   neighbouring mark that is itself resolved as *exact*, the section of a
   heading that occurs only once, and the independent signal from the XPointer.
   If more than one survives, a report follows.
3. **Across node boundaries** — the projection (Markdown, plain text) or
   assembly from the parts (EPUB).
4. **Bookmarks** — by way of `page`, because there is no text.

A bound comes only from a mark resolved as `exact`. Taking a bound from a
disambiguated or estimated mark would let a guess carry on further along as
though it were a fact.

The assumption underneath — that KOReader writes annotations in document order
— has not stayed an assumption: there is a function that checks it.

## The bookmark

A bookmark has no text range. It becomes a **point marker of zero length**,
which is a supported pattern in org-remark: `org-remark-line` uses the same
one.

That costs two methods. Without `housekeep-delete-p` → `nil` org-remark cleans
the zero-length overlay away and the note loses its link. And the headline
cannot quote the marked text, because there is none; it comes from the line the
bookmark sits on.

**What `page` means is the most important thing to know.** It is not the place
the reader pointed at but the first character of the rendered page on which the
bookmark sits. The proof is in the cases that coincide: four bookmarks in four
documents, set in four different places, all four yield the start of the
document — all four were on page 1. The position is therefore exact, but it
means "this page" and not "this sentence". It also depends on the layout with
which KOReader broke the document.

That is stated explicitly in the README and in the report, because otherwise a
user reads a meaning into it that is not there.

There is something on the other side of the ledger: that same XPointer makes a
bookmark more robust than a highlight. On reload it is derived from its path
again instead of being searched for by text, so a change elsewhere in the
source simply shifts it along.

## Notes: the baseline

An imported note goes into the Org file in full, and a later import must not
overwrite your edit. The naive rule — "fill the body if it is empty" — fails on
the case that matters most: a note you deliberately emptied then gets filled
again on every import.

Hence a baseline: on every successful import the hash of the imported note is
stored. That turns it into a three-way comparison — last imported, current in
KOReader, current in Org — which makes visible who changed something. The
deciding signal is not whether the body is empty but whether there is a
baseline.

Body and baseline are always written in the same operation, so that an
interruption never leaves a baseline without a body.

The canonicalisation before hashing may only undo what the Org storage itself
does: normalising line endings and removing trailing whitespace. Any
transformation beyond that makes a genuine user edit invisible; any
transformation too few makes a note count as changed while in fact only the
storage threw something away.

## Identity

An annotation has to be recognised as the same one on a second import. KOReader
supplies no identifier with it, so one is derived from fields that **do not
change through editing**:

```text
document identity | kind | pos0 | pos1 | datetime
```

`note`, `datetime_updated` and `text` are deliberately left out: KOReader lets
all three change without it becoming a different annotation. Were `text` to
count, a correction to the text in KOReader would make it a new annotation —
and you would lose the note attached to it.

The fields are separated with a NUL character, because that character cannot
occur in any field and the hash is therefore unambiguous.

## Reload is a full reconciliation

Importing is not an add operation but a comparison of two sides, with every
state named: new, unchanged, changed in KOReader only, changed locally only,
changed on both sides, gone from KOReader, no longer resolvable.

When an annotation disappears from the sidecar, the Emacs side is **not
silently removed** but reported. The note you wrote alongside it would
otherwise disappear with it.

`reload` differs from `import` in what happens beforehand: import lays its
outcome beside what is there, reload first throws the marks away and reads them
back from the notes file. Without that difference it would be a second name for
the same thing.

## The sidecar is read, never executed

A sidecar is a Lua file. The tempting answer is `load`; that is also the
dangerous one, because a file from an e-reader is input from outside.

Hence a reader of our own that accepts precisely the subset of data KOReader's
serializer writes, and refuses everything else: function calls, identifiers as
values, non-finite numbers, text after the table. Limits on file size, nesting
depth, number of fields and string length rule out memory exhaustion.

There is no external Lua interpreter and no shell call. The package is pure
Emacs Lisp and needs nothing else on a user's system.

## Dependent on org-remark, not a fork

Four properties of org-remark stood in the way of a coupling. Three are worked
around with choices described above, the fourth needs no change:

| property | our route |
|---|---|
| the stored text goes into the search unquoted, as a regexp | `adjust-positions-p` → `nil` per type; the mechanism does not run for us |
| the note body is truncated at 200 characters when read | we read the complete body ourselves from the Org file |
| the storage is tied to Org headlines | deliberately kept outside the first version |
| there is no public API to set a note body | an adapter function of our own using `org-find-property` and `org-end-of-meta-data`, both public in Org |

A fork would mean becoming the distributor of a modified org-remark, keeping it
in step, and having users install a drop-in replacement. That does not weigh up
against four properties one can work around. The regexp bug has been reported
upstream as a separate improvement.

What the package does rest on is four extension points and one hook:

| extension point | what for |
|---|---|
| `org-remark-highlight-make-overlay` | the bookmark as a point marker of zero length |
| `org-remark-highlight-headline-text` | a bookmark has no text to quote |
| `org-remark-highlights-adjust-positions-p` | switching off org-remark's own repositioning |
| `org-remark-highlights-housekeep-delete-p` | leaving the zero-length bookmark alone |
| `org-remark-highlights-after-load-functions` | running our own resolver after loading |

Besides that, one pen per kind-colour combination. That is not decoration: on
reload org-remark looks the pen up by the stored label. If that pen does not
exist it falls back to `org-remark-mark` and `org-remark-type` disappears —
with which none of the methods above apply any more.

## What deliberately does not happen

**Nothing is written to the sidecar.** Not because it is impossible, but
because preserving all the unknown sidecar data has to be proven first. Besides
annotations a sidecar holds a great deal of reader state — font size, margins,
reading position — and an import must never lose it.

**Nothing is scanned.** `org-remark-koreader-mode` is buffer-local and requires
explicit activation. No search across the file system for sidecars.

**An unknown colour does not quietly get the face of a known one.** The mark
would then claim something other than what KOReader says. It gets a display of
its own, and the original name is kept.
