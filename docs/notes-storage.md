# The notes store, and what it would take to move it

This package writes every annotation twice. KOReader has it in the sidecar;
org-remark wants it in a marginalia file. The second copy is the reason for
the reconciliation machinery — the note baseline, the three-way comparison,
the identity tuple — because two stores can disagree and something has to
decide who is right.

So: does org-remark need that second file, or could the sidecar be the store?

This is a reading of org-remark, plus one experiment that runs. Nothing here
is implemented in the package.

## What the store actually is

Three properties constrain any answer, and none of them is the file format.

**It is a buffer visiting a file.** `org-remark-notes-get-file-name` returns a
name; `find-file-noselect` opens it. org-remark never reads or writes a file
itself — after that call everything happens in a buffer.

**It is also the user interface.** `org-remark-open` shows the notes as a
cloned indirect buffer (`make-indirect-buffer ... :clone`) and the user edits
it as ordinary Org. The store is not an implementation detail behind an API;
it is a document that a person types in.

**Persistence is `save-buffer`, and the loop back is `after-save-hook`.**
`org-remark-save` calls `save-buffer` on the notes buffer;
`org-remark-notes-sync-with-source` re-reads it into every source buffer that
is registered against it. Both directions run through Emacs's ordinary file
machinery.

## How much Org there is

Seventeen functions in `org-remark.el` call something from Org. Eight of them
work in the notes buffer; the other nine are in the source buffer or use
buffer-agnostic macros. The store's whole vocabulary is fifteen functions:

| | |
|---|---|
| find an entry | `org-find-property`, `org-at-heading-p`, `org-next-visible-heading`, `org-back-to-heading` |
| bound an entry | `org-narrow-to-subtree`, `org-with-wide-buffer`, `org-end-of-subtree`, `org-end-of-meta-data`, `org-show-children` |
| read and write fields | `org-entry-get`, `org-set-property`, `org-entry-delete`, `org-delete-property`, `org-entry-properties` |
| place a new entry | `org-current-level` |

The eight functions are `org-remark-highlights-get` and `org-remark-open` on
the way in, `org-remark-highlight-add`,
`org-remark-highlight-add-or-update-highlight-headline`,
`org-remark-notes-new-headline`, `org-remark-notes-set-properties` and
`org-remark-notes-remove` on the way out, and `org-remark-notes-get-body`
for the text.

That is a small surface. It is also an inseparable one: there is no seam
between "which entry" and "how an entry is stored", so nothing can be
replaced piecemeal.

## Pointing the name somewhere else

`org-remark-notes-get-file-name` is a `cl-defgeneric`, and `org-remark-nov.el`
specialises it on `major-mode`. It looks like the extension point for a
different store. It is not: it chooses *which file*, never *what is in it*.

Handing it the sidecar path directly was tried. org-remark opens
`metadata.md.lua` in `fundamental-mode` and:

- the read side reports "No highlights or annotations found for ../source.md"
  and carries on. Not an error — a message. Every annotation is silently
  absent, and the relative path in the message shows a second problem:
  `org-remark-source-file-name` defaults to `file-relative-name`, so the key
  a source is filed under depends on where the notes file sits.
- the write side warns `‘org-element-at-point’ cannot be used in non-Org
  buffer` and then fails inside `org-fold-core-region` with a message that
  names nothing recognisable.

So the first route ends here, and it ends badly: not with a refusal, but with
silence.

## The route that works

If org-remark only ever asks Emacs for a file, then Emacs is where the answer
can be changed. A file-name handler — the mechanism that makes a TRAMP path
behave like a local one — can serve a name that has no file behind it and
build the buffer contents on demand.

`test/spike-notes-backend.el` does exactly that: `insert-file-contents` for a
virtual name reads the sidecar, resolves the marks against the source
document, and returns Org text with org-remark's own property names.
org-remark is untouched.

Measured over the generated corpus, both document families:

| | |
|---|---|
| overlays loaded | 47 |
| at the position the store gave | 47 |
| moved by org-remark after loading | 0 |
| cases that broke | 0 |

Five of the 47 cover more source text than they stored, all in the fixtures
with Markdown markup or a quote marker: KOReader stores rendered text, so a
mark across `**bold**` or a `> ` line covers characters the sidecar never
saw. That is the range being right, not wrong.

`org-remark-open` also works: the indirect clone is made over the virtual
buffer and comes up in `org-mode` with the generated notes in it.

Three details had to be right, and each one cost a debugging round:

- the virtual name must end in `.org`, or `auto-mode-alist` leaves the notes
  buffer in `fundamental-mode` and every `org-entry-get` returns nil;
- `file-attributes` must report an inode of its own. Borrow the source
  file's and Emacs concludes the two names are the same file, then reuses the
  source buffer as the notes buffer;
- `directory-file-name` and `file-name-as-directory` must return strings.
  Return nil and Emacs says "Invalid handler in `file-name-handler-alist'",
  which names neither the operation nor the handler.

## What a save would have to do

Saving funnels through one `write-region` call carrying the whole store as one
Org text. Adding a highlight by hand and saving produced that text with the
new entry in it, alongside the entries the sidecar had generated.

One funnel is good news for a writer: one place to translate, and one place
where a field could go missing. It also shows what would have to be reconciled
rather than appended, because org-remark re-serialises everything it read.
And it shows what the sidecar has no room for — org-remark adds
`org-remark-link` and `org-remark-label` to every entry, and a round trip
through a KOReader sidecar would have to put them somewhere or drop them.

## What this does not establish

That the read path works is not that the store can move. Writing is untested
and stays untested until preserving unknown sidecar data is proven: a sidecar
holds reading state — font size, margins, reading position — that no import
may lose.

A virtual notes file also has no revision history, no diff against yesterday,
and nothing for the user to grep. The marginalia file has all three.

Nothing here accounts for the announced rebuild of org-remark's highlighting
on `chu`, which moves the store from Org headlines to a triples database.
Everything measured above is measured against the overlay implementation as
it stands.
