# org-remark: API, life cycle and hook points

Established by reading the upstream source, not from documentation.

## Pinned source

| | |
|---|---|
| repository | `https://github.com/nobiot/org-remark` |
| commit | `6f8193c4997c734c39ccf814636c4e5d10eb42d1` |
| date | 31 May 2026 |
| files | `org-remark.el` (1961 lines), `org-remark-global-tracking.el`, `org-remark-line.el`, `org-remark-icon.el`, `org-remark-nov.el`, `org-remark-info.el`, `org-remark-eww.el`, `org-remark-convert-legacy.el` |

Line numbers below refer to this commit.

### What is actually run against

The tests run against **release 1.3.0** from GNU ELPA, because that is what is
installed. That release counts 1955 lines against 1961 in the pinned commit.
Every anchor from this document was found back in it: `org-remark-mark` (487),
`org-remark-highlight-mark` (938), the property constants (238) and the
`after-load` defcustom (160) sit on exactly the same line; from about line 1000
onwards 1.3.0 runs six lines ahead, so that
`org-remark-notes-set-properties` sits at 1510 there instead of 1516 and
`org-remark-string=` at 1940 instead of 1946.

The difference is therefore a shift, not different behaviour. Where it matters
below, both numbers are given.

## Making a mark

### `org-remark-mark` and the pen macro

```elisp
(org-remark-mark BEG END &optional ID MODE)
```

`org-remark.el:487`. Interactively it generates a new ID; from Elisp an existing
ID can be passed in.

`MODE` governs persistence and knows three values: `nil`, `:load` and
`:change`. The relevant line sits in `org-remark-highlight-mark`
(`org-remark.el:1001`):

```elisp
;; for mode, nil and :change result in saving the highlight.  :load
;; bypasses save.
(unless (eq mode :load) ...)
```

So with `:load` **no** headline is written to the notes file. That is precisely
what you want when restoring existing marks, and precisely what you do *not*
want when importing a new KOReader annotation that has no Org counterpart yet.

Both go through the same function in the end:

```elisp
(org-remark-highlight-mark BEG END &optional ID MODE LABEL FACE PROPERTIES)
```

`org-remark.el:938`. It switches `org-remark-mode` on if needed, makes the
overlay, puts all `PROPERTIES` on it, and calls the storage when the mode is
not `:load`.

### Custom pens

```elisp
(org-remark-create LABEL &optional FACE PROPERTIES)
```

`org-remark.el:245`. A macro that defines the function `org-remark-mark-LABEL`
and registers it in `org-remark-available-pens`.

`PROPERTIES` is a plist. Two conventions matter:

- properties that have to end up in the property drawer of the Org headline get
  the prefix `org-remark-` or are called `CATEGORY`;
- the key `org-remark-type` determines which generic methods apply (see
  [Hook points](#hook-points)).

The standard pens are made with the same macro (`org-remark.el:520`), so there
is no privileged path only upstream can walk.

## Storage format

Marks are stored as Org headlines under one headline per source file. The
property names sit as constants at `org-remark.el:238`:

| constant | property |
|---|---|
| `org-remark-prop-id` | `org-remark-id` |
| `org-remark-prop-source-file` | `org-remark-file` |
| `org-remark-prop-source-beg` | `org-remark-beg` |
| `org-remark-prop-source-end` | `org-remark-end` |

Besides that, `org-remark-original-text` is written (`org-remark.el:1265`) —
the text as it stood in the buffer at the moment of marking.

### The headline belongs to the user, the property is the anchor

In `org-remark-highlight-add-or-update-highlight-headline` the heading text and
`org-remark-original-text` come from **one and the same** call to
`org-remark-highlight-headline-text` (`org-remark.el:1221`); that value is both
inserted as the headline (`org-remark.el:1255`) and set in the property
(`org-remark.el:1259`).

That happens only on **creation**. If the headline already exists, its text is
not updated; the line that would do so is commented out with the explanation
alongside (`org-remark.el:1242`):

```elisp
;; Don't update the headline text when it already exists.
;; Let the user decide how to manage the headlines
;; (org-edit-headline text)
```

Two consequences.

**Headings are free.** A headline once created may be renamed without anything
breaking: the position correction reads `org-remark-original-text`, not the
heading.

**A custom `org-remark-highlight-headline-text` determines the anchor too.**
What that method returns becomes the stored text matched against later. A
shortened or otherwise lossy heading text makes the anchor silently unusable.
Anyone wanting short headings has to set them afterwards, not by way of this
method.

### Which overlay properties end up in the drawer

`org-remark-notes-set-properties` (`org-remark.el:1516`) applies two rules:

- the name is `CATEGORY` or starts with `org-remark-` → **goes into the property
  drawer**;
- the name starts with `*` → **stays overlay-only**.

That is precisely the mechanism for letting KOReader metadata ride along:
`org-remark-koreader-pos0` is preserved, `*org-remark-koreader-confidence`
stays in the session. The properties are read from the overlay at the moment of
saving (`org-remark-highlight-add-or-update-highlight-headline`,
`org-remark.el:1216`).

**Positions are absolute buffer positions**, stored as a number and read back on
loading with `string-to-number` (`org-remark.el:1650`). There is no textual
anchor in the storage format itself; `org-remark-original-text` serves as a
means of correction, not as the primary location.

### The note body

```elisp
(org-remark-notes-get-body)
```

`org-remark.el:1552`. The body is everything after the meta-data of the
headline up to the end of the subtree. Two properties to reckon with:

- an empty annotation yields `nil`, not an empty string;
- **the body is truncated at 200 characters** when read:

```elisp
(if (< 200 (length full-text))
    (substring-no-properties full-text 0 200)
  full-text)
```

That is a read limit for the in-memory representation (used for among other
things `help-echo` and the overlay property `*org-remark-note-body`,
`org-remark.el:1302`), not a write restriction. A KOReader note longer than 200
characters therefore ends up complete in the Org file, but the value
`org-remark-highlights-get` returns is shortened. Anyone comparing the body to
detect local edits must therefore not take that truncated value as the basis of
comparison.

### There is no setter for the body

`org-remark-notes-get-body` reads, `org-remark-notes-set-properties`
(`org-remark.el:1516`) writes properties — but **nothing writes a body**. In
the design of org-remark the body is purely text typed by the user; the library
makes the headline and the property drawer, and leaves the content to the human.

That has a direct consequence for importing a KOReader note.
`org-remark-highlight-mark` with `MODE` = `nil` makes the headline and saves the
notes file, but puts no text in it. The note content has to be inserted
afterwards in a separate step.

The building material for that does exist:

- `(org-find-property org-remark-prop-id ID)` locates the headline by the ID —
  this is how org-remark does it itself (`org-remark.el:1244`);
- `(org-end-of-meta-data :full)` puts point at the place where the body begins,
  as `org-remark-notes-get-body` shows.

An adapter therefore has to do its own: find the headline by the ID, put point
after the meta-data, read the complete existing body, decide whether writing is
allowed, save the buffer, and update the overlay property
`*org-remark-note-body`.

That decision is subtler than a comparison. Without a comparison step the body
grows with every import; with an equality test alone you overwrite a locally
edited note, because that is exactly where the body differs. The write semantics
ought to be: fill an empty body, refresh a body equal to the last imported
value, and leave a deviating body alone.

Note in this connection that `*org-remark-note-body` holds the **truncated**
value and is therefore a display cache, not a reliable basis for that
comparison.

## The load cycle

```elisp
(org-remark-highlights-get NOTES-BUF)
```

`org-remark.el:1611`. Finds the headline whose `org-remark-file` matches the
source, narrows to that subtree, and walks the child headlines. Per highlight it
yields:

```elisp
(:id ID
 :location (BEG . END)
 :label LABEL
 :props (:original-text TEXT :body BODY))
```

A headline without an `id`, `beg` or `end` is silently skipped
(`org-remark.el:1647`).

### Position correction on loading

```elisp
(org-remark-highlight-adjust-position-after-load HIGHLIGHT TEXT)
```

`org-remark.el:1314`. This is the place where org-remark does text matching
itself. The behaviour:

1. if `TEXT` already matches what stands at `BEG`–`END`, nothing happens. That
   comparison goes through `org-remark-string=`, which **removes all spaces and
   line breaks** before comparing (`org-remark.el:1946`) — so
   whitespace-insensitive, not exact;
2. if not, a search is done with `re-search-forward` within a window of two
   paragraphs back to two paragraphs forward;
3. on a hit the overlay is moved there;
4. either way `*org-remark-position-adjusted` is set on the overlay.

Two things matter here for this coupling. `TEXT` goes into the search function
as a **regexp**, not as a literal string, so text with regexp metacharacters
behaves unpredictably. And the search is paragraph-bounded, which means
org-remark's own recovery does not work for text moved across paragraph
boundaries.

That is no argument for storing the text quoted instead — see
[Consequences](#consequences-for-a-koreader-coupling); the way out is switching
the correction off per type.

## Housekeeping and zero-length overlays

```elisp
(org-remark-highlights-housekeep)
```

`org-remark.el:1793`. Runs automatically on *mark*, *save* and *remove*, before
the sorting. Two cases are cleaned up:

1. start and end of the overlay are equal;
2. the overlay no longer points at any buffer.

Case 1 is decisive for point markers. An overlay of zero length is removed, and
`org-remark-notes-remove` is called with `org-remark-notes-auto-delete`. That
happens only when the buffer is writable and not derived from `special-mode`.

What that does to the note depends on that variable, which is `nil` by default
(`org-remark.el:99`). At the default value **only the properties of the Org
entry are removed**; the headline and the note text stay. The mark thereby loses
its link without the text disappearing — quiet enough to go unnoticed, and
serious enough that the annotation is no longer found on a following load.

The escape is a generic method:

```elisp
(cl-defgeneric org-remark-highlights-housekeep-delete-p (_ov _org-remark-type))
```

`org-remark.el:1862`, `t` by default. A type returning `nil` is kept.
`org-remark-line` does precisely that (`org-remark-line.el:385`):

```elisp
(cl-defmethod org-remark-highlights-housekeep-delete-p (_ov (_org-remark-type (eql 'line)))
  "Always return nil when ORG-REMARK-TYPE is 'line'.
Line-highlights are designed to be zero length with the start and
end of overlay being identical."
  nil)
```

**A zero-length mark is therefore a supported pattern**, provided it has an
`org-remark-type` of its own with this method. That is no detour around the
library but the way upstream does it itself.

## Hook points

All the extension points are `cl-defgeneric`. This is the complete list in this
commit:

| generic | file:line | what for |
|---|---|---|
| `org-remark-notes-get-file-name` | `global-tracking.el:139` | **where the annotations go** |
| `org-remark-highlight-make-overlay` | `org-remark.el:923` | what the overlay looks like |
| `org-remark-highlight-get-constructors` | `org-remark.el:1070` | build-up of the Org headlines |
| `org-remark-highlight-headline-text` | `org-remark.el:1177` | title text of the headline |
| `org-remark-highlights-housekeep-delete-p` | `org-remark.el:1862` | keeping zero-length overlays |
| `org-remark-highlights-housekeep-per-type` | `org-remark.el:1871` | cleanup behaviour of your own |
| `org-remark-highlights-adjust-positions-p` | `org-remark.el:1899` | position correction on/off |
| `org-remark-beg-end` | `org-remark.el:1920` | what gets selected interactively |
| `org-remark-icon-overlay-put` | `icon.el:178` | icon display |
| `org-remark-icon-highlight-get-face` | `icon.el:221` | icon colour |

Besides that there are two ordinary hooks, which need no specialisation:

| hook | file:line | when |
|---|---|---|
| `org-remark-highlights-after-load-functions` | `org-remark.el:160` | after `org-remark-highlights-load` |
| `org-remark-highlight-other-props-functions` | — | while building the properties before storage |

The first is a `defcustom` with `'(org-remark-highlights-adjust-positions)` as
its default value. It runs with `OVERLAYS` and `NOTES-BUF` as arguments, with
the source buffer as the current buffer, called at `org-remark.el:1706`.
`org-remark-icon` hooks onto it with `add-hook`.

**This is the hook point for a position resolver of your own.** No upstream
extension is needed to do work of your own after loading.

### Two of these methods are mandatory, not optional

The table above reads like a list of options. It is not: for an
`org-remark-type` of your own there are two methods without which the mechanism
does not work. Both only showed up on running, not on reading.

**`org-remark-highlight-make-overlay`** has `(ignore)` as its generic default
implementation — which returns `nil`. Only the type `nil` has a method that
really makes an overlay (`org-remark.el:923` and `:931`). A custom type without
a method of its own therefore yields **no overlay, silently**:
`org-remark-highlight-mark` returns `nil`, the headline does get written, and
there is nothing to see. No error, no message.

**`org-remark-highlight-headline-text`** has no default implementation at all:
the `cl-defgeneric` at `org-remark.el:1177` has an empty body, and there are
only methods for `(eql nil)` and `(eql 'line)`. A custom type therefore gives
`cl-no-applicable-method` as soon as storage happens — not at the making of the
overlay, but further along in
`org-remark-highlight-add-or-update-highlight-headline`.

So the minimum for a working type of your own is:

| method | without this method |
|---|---|
| `org-remark-highlight-make-overlay` | no overlay, no message |
| `org-remark-highlight-headline-text` | `cl-no-applicable-method` on saving |

That `org-remark-line` implements eight of them is therefore no excess: two of
them are the price of a type of your own, the rest is behaviour.

### The label determines what comes back on reload

`org-remark-highlight-load` (`org-remark.el:1272`) looks the pen up by the
stored label:

```elisp
(let ((fn (intern (concat "org-remark-mark-" label))))
  (unless (functionp fn) (setq fn #'org-remark-mark))
  (setq ov (funcall fn beg end id :load)))
```

If `org-remark-mark-LABEL` does not exist, it falls back to `org-remark-mark` —
and that one does not know the custom `org-remark-type`. After reopening, the
mark is then of the standard type, with which *all* the type-specific methods
lapse: the position correction is on again, and a zero-length mark is cleaned
up again.

A pen per label is therefore not decoration but the condition under which a
custom type survives a restart. What is put back on the overlay is further
limited to `*org-remark-note-body` and `*org-remark-original-text`
(`org-remark-highlight-put-props`, `org-remark.el:1288`); properties of your own
from the drawer do **not** come back on the overlay.

Two forms of specialisation are used:

- **on type**: `((_org-remark-type (eql 'line)))` — applies to marks with that
  `org-remark-type` in their properties;
- **on major mode**: `(&context (major-mode nov-mode))` — applies to all marks
  in buffers with that mode.

## Worked examples in the library itself

Three existing extensions are usable as a template:

**`org-remark-line.el`** — a point marker. Implements 8 methods: six core
methods — `beg-end` (yields `(bol bol)`, so zero length),
`highlight-make-overlay`, `highlight-headline-text`,
`highlights-adjust-positions-p` (yields `nil`), `housekeep-delete-p` (yields
`nil`) and `housekeep-per-type` (keeps the overlay at the start of the line) —
plus two icon methods. This is the complete recipe for a
location-without-a-range.

**`org-remark-nov.el`** — a different source state. Specialises
`notes-get-file-name` on major mode and redefines
`highlight-get-constructors`.

**`org-remark-info.el`** — specialises only `highlight-get-constructors`.

## Consequences for a KOReader coupling

What the source demonstrates, ordered by the questions that matter:

**Making marks is possible without forking the library.**
`org-remark-create` is public, and type specialisation by way of
`org-remark-type` is the intended mechanism.

**Bookmarks as point markers are feasible.** Zero-length overlays survive
housekeeping provided there is a type of your own with `housekeep-delete-p` →
`nil`. `org-remark-line` proves it works and shows which methods belong to it.
What is still a choice: `org-remark-line` ties the mark to the start of the
line, which for a KOReader bookmark with an offset in the middle of a paragraph
throws information away.

**`:load` is not the right import mechanism.** It skips storage, so an imported
KOReader annotation would get no Org headline and would be gone on the next
load. Import has to use `MODE` = `nil`; `:load` is for restoring what has
already been stored.

**The note body is editable but not comparable just like that.** The Org file
holds the complete text, but `org-remark-highlights-get` yields a body truncated
at 200 characters. For detecting local edits the complete body has to come from
the Org file, not from that plist.

**There is no storage abstraction.** `org-remark-notes-get-file-name`
determines which *file* gets the annotations, but the format — Org headlines
with property drawers — is fixed in `org-remark-highlight-add`,
`org-remark-highlights-get` and `org-remark-notes-*`. A KOReader backend can
therefore not be plugged in by way of an existing abstraction. The smallest
interventions are, in order of size: specialisation of `notes-get-file-name`
(determines only where), advice around `org-remark-highlights-get` and
`org-remark-highlight-add` (determines how), or an abstraction that could go
upstream.

**Two position mechanisms must not run side by side.** org-remark stores
`BEG`/`END` as numbers and corrects them itself on loading with a
`re-search-forward` within ±2 paragraphs, in which `org-remark-original-text`
goes into the search function as a **regexp**.

The temptation is to store that text quoted instead. That is the wrong way in:
`org-remark-string=` then compares the stored text with the source text, and a
quoted form fails there. The problem sits in `re-search-forward`, not in the
storage.

The clean solution is switching the whole mechanism off for types of your own:

```elisp
(cl-defmethod org-remark-highlights-adjust-positions-p
  ((_org-remark-type (eql 'koreader-highlight)))
  nil)
```

`org-remark-highlights-adjust-positions` (`org-remark.el:1875`) tests that
predicate before anything else, so `nil` switches the correction off entirely.
`org-remark-line` uses the same way out. With that
`org-remark-original-text` stays verbatim, and only our own confidence-based
resolver restores the positions.

## What running has confirmed

The save, kill and reopen cycle has been tried against release 1.3.0 in
`test/org-remark-koreader-integration-tests.el`. Confirmed: marks with all their
properties in one call to `org-remark-highlight-mark` survive saving and
reopening, their `org-remark-type` included; a zero-length overlay with a type
of its own survives housekeeping while an ordinary one does not; and our own
resolver on `org-remark-highlights-after-load-functions` runs after loading.

Two things only showed up there: that `highlight-make-overlay` and
`highlight-headline-text` are mandatory (see above), and that the loading
postpones itself as long as the buffer has no window.

**`org-remark-highlights-load` does nothing without a window.** The first line
is `(if (not (get-buffer-window)) (add-hook 'post-command-hook ...))`
(`org-remark.el:1666`). In a batch Emacs that hook does not run, so loading
happens there only when the buffer has explicitly been put in a window. Anyone
overlooking this in tests gets a suite that is green because nothing happened.

## What this reading does not establish

- Interaction with `org-remark-global-tracking-mode` and the automatic
  activation on opening a file.
- Behaviour of `org-remark-icon` when margins are not available — in
  `org-remark-line` the overlay turns out to be `nil` sometimes because there is
  no window yet (`org-remark.el:985`).
