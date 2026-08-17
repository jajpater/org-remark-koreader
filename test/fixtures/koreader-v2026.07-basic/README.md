# KOReader v2026.07 basic fixture

This fixture is written by KOReader itself. The sidecar file may not be created
or edited by hand.

The source document is Dutch, and so are the selected strings below: they are
what KOReader stored, and changing them would make the fixture something other
than what was measured.

## Provenance

| field | value |
|---|---|
| date | 14 August 2026 |
| platform | KOReader desktop, Linux x86_64 |
| release | `v2026.07` |
| upstream commit | `1e2fa5f1239028ab4b37acae833cdc86a71e5258` |
| release asset | `koreader-v2026.07-x86_64.AppImage` |
| asset SHA-256 | `757d7f15d4fb2b0c73fc0ab74bbf33f38710a3e1d4e3f2da1ea90a948fa3a0` |
| source file | `source.md` in this directory |
| export annotations on closing | enabled |
| keep all annotations on import | enabled |

The release asset and its checksum come from the official GitHub release. The
commit is the commit object the annotated tag `v2026.07` points at.

## How it was made

Start without an existing `source.sdr` directory. Open `source.md` directly with
the build recorded above and carry out these actions. Selecting text on the
desktop starts by holding the left mouse button briefly and then dragging
without letting go:

1. Select exactly `unieke ankerlicht`, choose **Highlight** and leave the colour
   yellow.
2. Select exactly `donkere horizon`, choose **Highlight** and change the colour
   to green.
3. Select exactly `kalme noorderwind`, choose **Highlight** and add this note:

   ```text
   Dit is een notitie bij de woorden ¨kalme noorderwind¨ Ik weet niet of de noorderwind vaak kalm is. Maar zo is het een mooie notitie geworden.
   ```

4. Make exactly one bookmark on the only page. KOReader records it in the
   generated metadata at the page/title position, not at the visual paragraph
   where the bookmark action was started.
5. During the recorded session the reading status was set to finished, with
   `Dit is een mooi boek om te lezen` as the book note. That is top-level
   `summary` state and not an annotation.
6. Switch on **Export annotations on book closing** and **Keep all annotations
   on import**. In the recorded session both settings were on.
7. Close the document from within KOReader and then quit KOReader normally, so
   that the ordinary persistence and export code runs.

Expected result:

```text
source.sdr/
├── metadata.md.lua
├── metadata.md.lua.old
└── source.md.annotations.lua
```

## Acceptance

The sidecar has to hold exactly four entries:

- one yellow highlight on `unieke ankerlicht`;
- one green highlight on `donkere horizon`;
- one yellow highlight with the note above on `kalme noorderwind`;
- one bookmark without `drawer`.

The source file and the generated sidecar are not changed after generation. A
new generation starts by removing the whole `source.sdr` directory and running
the procedure again with the same release.

`source.md.annotations.lua` is not a second standard sidecar but KOReader's
optional export/import file for annotations. It holds the same `annotations`
block as `metadata.md.lua`, plus the export time and `device_id`.
