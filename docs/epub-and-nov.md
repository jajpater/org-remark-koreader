# EPUB: one source, two renderers

What was measured on the EPUB side, and what follows from it. The reasoning
behind the choices is in `design.md`; what the sidecar holds is in
`koreader-current-format.md`. Here is the other end: what `nov-mode` makes of an
EPUB, and how a KOReader XPointer finds its way in that.

Measured with nov.el `20251213.1501` against the eight EPUB fixtures from the
generator — 41 operations: 28 highlights, 6 annotations, 7 bookmarks.

## The task differs from Markdown

With Markdown, KOReader and Emacs read the same file, so CRengine's tree can be
rebuilt from the source. Not with EPUB: `nov-mode` does not show the XHTML but
what **shr** made of it, and KOReader shows what **CRengine** made of it. One
source, two independent renderers.

Rebuilding a tree would mean predicting another program's rendering. It is also
unnecessary, because the stored text appears verbatim in the nov buffer.

## What org-remark itself does for EPUB

`org-remark-nov.el` is 161 lines and does not touch positions. It solves four
bookkeeping problems: where the notes file goes (beside the `.epub`, not in
nov's temporary unpacking directory), what "source file" means
(`book.epub/chapter`), a two-layer heading structure in the notes file (book →
chapter), and reloading when you turn the page — because nov erases the buffer
and renders the next document in it.

Positions are ordinary buffer positions. There is no translation at all.

## The XPointer has a third shape

```text
/body/DocFragment[3]/body/p[1]/text().26
```

Not `/html/body` (Markdown), not `/FictionBook/body` (plain text).
`DocFragment` is the spine document; CRengine glues the chapters into one DOM
and numbers them.

**`DocFragment[N]` is the Nth spine item, one-based.** Proved with
`006-multichapter-spine`, whose spine is `nav cover c1 c2 c3 c4 c5`:
`DocFragment[3]` yields chapter one, `[5]` chapter three, `[7]` chapter five.

**But nov's numbering is no shift of it.** `nov--content-epub3-files` takes the
navigation document out of the spine and prepends it again:

```elisp
(setq files (seq-remove (lambda (item) (eq (car item) nov-toc-id)) files))
(cons toc-file files)
```

That gives a different relationship per book. With the navigation document
outside the spine (`001-basic`) the nov index equals the spine number; with it
inside and at the front (`006`) they differ by one. Were it to sit halfway
through the spine, it would be a permutation and no piece of arithmetic would
hold.

The coupling therefore runs over the **manifest id**, not over an index. That is
what both sides share: the spine names its items with `idref`, and nov's
`nov-documents` carries that same id.

## The rendered text is clean

With `nov-text-width t` — filling off — nov yields exactly the paragraph text,
separated by blank lines, without markup characters:

```text
EPUB basic fixture

This paragraph contains a unique EPUB highlighted phrase.

The EPUB passage crosses bold words and continues into plain text.
```

That makes the cheap route work: KOReader's stored text sits in the buffer word
for word.

## The filling is a user setting

Measured over the fixtures, with `nov-variable-pitch` at nil so that shr counts
in characters:

```text
nov-text-width   verbatim   loose   lost
t (no filling)         22       0      0
80                     22       0      0
40                     13       9      0
```

"Loose" is a hit in which any run of whitespace may match any other — needed as
soon as shr fills a paragraph and a newline falls where a space stood.

Nothing gets lost, but the **buffer position shifts** with the setting. And it
is worse than a number: nov's default `nov-variable-pitch` is `t`, and then shr
counts in pixels on the strength of the actual font metrics. The same EPUB then
yields different positions on another machine, in another theme or at another
window size.

For a package that stores absolute positions that is a real problem. For this
one it is not: the position finding runs afresh on every load, by way of
`org-remark-highlights-after-load-functions`.

## The chapter is a unit, and that is a gain

nov shows one document at a time in one buffer. Only the annotations of the
current document can be placed; the rest belong to a document that is not on
screen. The `DocFragment` index says which those are, so that is a filter and
not a search problem. Such a mark gets the outcome `elsewhere`: not a failure
but a finding.

**A book-wide duplicate is often unique within a chapter.** In
`006-multichapter-spine` the same sentence stands in chapters one and five. In
KOReader's book-wide DOM those are two candidates; in nov one chapter sits in
the buffer, and there it is unambiguous.

For what the text cannot tell apart — the deliberate duplicates within one
chapter in `002-unicode-duplicates`, where the same sentence occurs three times
— there is the element path. `p[2]` and `p[4]` are different paragraphs even
when their text does not give that away, and by counting the alike predecessors
each of them can be pointed at. Measured: occurrence 1 and occurrence 3,
precisely as the generator set them.

## The renderer writes along

A selection across two list items is not found by searching, because shr
numbers the items itself:

```text
1 First list crossing begins with amber rope
2 Second list crossing ends with a blue knot.
```

KOReader's text is `"...amber rope\nSecond list crossing..."` — without that
`2`. Between the two halves the buffer holds `\n2 `, and a digit is not
whitespace, so the loose route does not help.

That is the same lesson as with Markdown: what the renderer adds is not in the
stored text. Here there is a cheap answer. **Across a block boundary KOReader
always puts a newline in the text.** With Markdown that alternated — now a
space, now a newline — but in EPUB both measured cases (`blockquote` to `p`, and
`li` to `li`) are a newline. The parts can therefore be split on `\n` and
searched for separately; the range then runs from the first to the last hit.
That yields confidence `joined`.

## Bookmarks run by way of the XHTML

A bookmark has no text to search for; its `page` names an element
(`/body/DocFragment[7]/body/p[3]`). Without a rebuilt tree that path cannot be
translated into a buffer position — but the XHTML itself is there, because nov
unpacks it and keeps track of the path. From it one can read *which* text sits
in that place, and that text can then be found again in the rendered buffer. The
XHTML says what is there, the buffer says where.

Three things must not get lost along the way, and that turned out to hold as
soon as there was a fixture for it (`008-bookmark-offsets`):

- **Which of two alike paragraphs.** Text alone is not enough: `p[2]` and `p[4]`
  can be word for word the same. What survives is the order — if this is the
  second alike one in the document, it is also the second in the buffer.
- **Which text node within the paragraph.** `text()[2]` counts inside that one
  node, not inside the whole paragraph. What precedes it — including the text of
  the inline elements in between — has to be measured first.
- **How many characters further on.** A run of whitespace counts as one
  character; that the display makes a newline of it does not change the count.

One thing may not be trimmed away in the process: **a text node that begins with
whitespace counts that whitespace.** The second text node in the fixture begins
with a space, and KOReader's offset counts from there.

## CJK breaks the whitespace route

shr breaks East Asian text **between the characters**, because there are no
spaces there. Measured against shr itself:

```text
shr-width 40:
これは日本語の文章です。これは日本語の文
章です。これは日本語の文章です。

shr-width 20:
これは日本語の文章で
す。これは日本語の文
章です。これは日本語
の文章です。
```

The newline falls in the middle of what KOReader stores as one continuous
string. The loose search route joins words with `[ \t\n\r]+` *between* the
tokens and so does not help here.

Hence a last resort: when every other route fails, a newline may stand between
each pair of characters. That yields confidence `approximate`, because it is
wider than the other routes.

The recognition uses spelled-out Unicode ranges and not Emacs' character
categories: `\cc` and `\cj` turn out to match Greek and `café` as well, and then
this last resort would apply to ordinary text.

The fixtures do not show this: their Japanese fragment is too short to reach a
fill boundary. It is measured against shr, not against the corpus.

## What the full cycle needs

An import in a `nov-mode` buffer walks the whole book: every chapter is brought
on screen, imported and saved, after which the reader returns where they were.
Every chapter gets its own heading in the notes file — `org-remark-nov` sees to
that — and its own reconciliation, because the annotations of another chapter do
not belong to it.

Two things turned out to be needed:

**Overlays survive `erase-buffer`.** `nov-mode` erases the buffer for the next
chapter, but the overlays live on and collapse onto position one. Without
cleaning up, every chapter drags the marks of the previous one along. Normally
`org-remark-highlights-load` sees to that, but it postpones itself as long as
there is no window — so the import may not lean on it and cleans up itself
before turning the page.

**`org-remark-nov-mode` has to be on.** It determines what "source file" means
and where the notes file goes. `org-remark-koreader-mode` therefore switches it
on itself in a `nov-mode` buffer, as it already did with `org-remark-mode`.

## The border cases

The cases in `007-render-boundaries` all resolve, and all by the same text
route. An image yields its alt text in shr and so shifts positions but breaks
nothing; a `pre` block keeps its newlines, in KOReader's stored text as well; a
table is pointed at by way of `table/tbody/tr/td[2]` and shr puts the cell text
plainly in the buffer; and Arabic from right to left yields no peculiarity,
because positions are logical and not visual.

**An offset outside its element is refused.** That became a unit test and not a
fixture: a forged sidecar proves nothing about KOReader. The test laid bare a
real hole at once — the count simply ran on into the next paragraph and yielded
a position that meant nothing. Now the bounds of the element itself apply.

That same test brought a second fault to light. Counting alike predecessors
looked at *every* element, and so at the enclosing `body` as well, which in a
chapter of one paragraph carries word for word the same text. In the fixtures
that stayed hidden because a chapter there has more than one block. Now only
elements of the same kind count.

## The outcome

Walking every document of the seven fixtures:

```text
29  exact
 7  bookmarks, projected
 3  joined across a block boundary
 2  disambiguated with the element path
```

Forty-one of the forty-one. Where `expected.json` gives a ground truth — an
occurrence number, a path, an offset — every placement is tested against it and
not merely against "there is something there".
