# KOReader v2026.07 basic fixture

Deze fixture wordt door KOReader zelf geschreven. Het sidecarbestand mag niet
handmatig worden aangemaakt of aangepast.

## Provenance

| veld | waarde |
|---|---|
| datum | 14 augustus 2026 |
| platform | KOReader desktop, Linux x86_64 |
| release | `v2026.07` |
| upstreamcommit | `1e2fa5f1239028ab4b37acae833cdc86a71e5258` |
| release-asset | `koreader-v2026.07-x86_64.AppImage` |
| asset-SHA-256 | `757d7f15d4fb2b0c73fc0ab74bbf33f38710a3e1d4e3f2da1ea90a948fa3a0` |
| bronbestand | `source.md` in deze map |
| annotatie-export bij sluiten | ingeschakeld |
| alle annotaties behouden bij import | ingeschakeld |

De release-asset en checksum komen uit de officiële GitHub-release. De commit
is het commitobject waarnaar de annotated tag `v2026.07` verwijst.

## Aanmaakprocedure

Begin zonder bestaande `source.sdr`-map. Open `source.md` rechtstreeks met de
hierboven vastgelegde KOReader-build en voer deze handelingen uit. Tekstselectie
op desktop begint met de linkermuisknop even vasthouden en daarna, zonder los te
laten, slepen:

1. Selecteer exact `unieke ankerlicht`, kies **Highlight** en laat de kleur
   geel.
2. Selecteer exact `donkere horizon`, kies **Highlight** en verander de kleur
   in groen.
3. Selecteer exact `kalme noorderwind`, kies **Highlight** en voeg deze notitie
   toe:

   ```text
   Dit is een notitie bij de woorden ¨kalme noorderwind¨ Ik weet niet of de noorderwind vaak kalm is. Maar zo is het een mooie notitie geworden.
   ```

4. Maak precies één bookmark op de enige pagina. KOReader legt deze in de
   gegenereerde metadata vast op de pagina-/titelpositie, niet op de visuele
   alinea waar de bookmarkactie werd gestart.
5. Tijdens de vastgelegde sessie is de leesstatus op voltooid gezet met als
   boeknotitie `Dit is een mooi boek om te lezen`. Dit is top-level
   `summary`-toestand en geen annotatie.
6. Schakel **Export annotations on book closing** en **Keep all annotations on
   import** in. In de vastgelegde sessie stonden beide instellingen aan.
7. Sluit het document via KOReader en sluit daarna KOReader normaal af, zodat
   de normale persistence- en exportcode worden uitgevoerd.

Verwacht resultaat:

```text
source.sdr/
├── metadata.md.lua
├── metadata.md.lua.old
└── source.md.annotations.lua
```

## Acceptatie

De sidecar moet precies vier entries bevatten:

- één gele highlight op `unieke ankerlicht`;
- één groene highlight op `donkere horizon`;
- één gele highlight met de `note` hierboven op `kalme noorderwind`;
- één bookmark zonder `drawer`.

Het bronbestand en de gegenereerde sidecar worden na generatie niet meer
gewijzigd. Een nieuwe generatie begint door de complete `source.sdr`-map te
verwijderen en de procedure opnieuw met dezelfde release uit te voeren.

`source.md.annotations.lua` is geen tweede standaard-sidecar, maar KOReaders
optionele export/importbestand voor annotaties. Het bevat hetzelfde
`annotations`-blok als `metadata.md.lua`, plus exporttijd en `device_id`.
