# org-remark-koreader

Maakt KOReader-annotaties zichtbaar en bewerkbaar in Emacs, als
[org-remark](https://github.com/nobiot/org-remark)-marks met marginale
notities. Werkt op Markdown, platte tekst en EPUB.

De KOReader-sidecar wordt uitsluitend gelezen. Bronbestand en sidecar blijven
byte-identiek; dat is een test, geen belofte.

*This document is also available [in English](README.md).*

## Gebruik

Hetzelfde bestand staat op de e-reader en op de computer:

```text
reading-notes.md
reading-notes.sdr/
└── metadata.md.lua
```

Open het bestand in Emacs en roep aan:

```text
M-x org-remark-koreader-import
```

De markeringen verschijnen als overlays; notities zijn te openen en te
bewerken met de gewone org-remark-commando's (`org-remark-open`,
`org-remark-view-next`).

Let op de mapnaam: de extensie valt weg uit de `.sdr`-map en blijft staan in
het metadatabestand. Dus `reading-notes.sdr/metadata.md.lua`, niet
`reading-notes.md.sdr/`.

Voor een EPUB werkt het net zo, maar dan in `nov-mode`. Zet
`org-remark-koreader-mode` aan en importeer; het hele boek wordt langsgegaan,
hoofdstuk voor hoofdstuk.

## De commando's

| commando | wat het doet |
|---|---|
| `org-remark-koreader-import` | leest de sidecar en plaatst wat betrouwbaar te plaatsen is |
| `org-remark-koreader-reload` | ruimt de markeringen eerst op en bouwt ze daarna opnieuw op |
| `org-remark-koreader-report` | wat de laatste import opleverde, inclusief wat er níét geplaatst is |
| `org-remark-koreader-inspect-mark` | de herkomst van de markering onder je cursor |
| `org-remark-koreader-mode` | buffer-lokaal; zet org-remark aan, en in een EPUB ook `org-remark-nov-mode` |

Importeren mag zo vaak je wilt: een tweede keer levert geen duplicaten op,
en een notitie die je in Emacs hebt bewerkt blijft staan.

`reload` is er voor als de buffer niet meer klopt — bijvoorbeeld nadat je de
bron hebt gewijzigd en er markeringen zijn achtergebleven die nergens meer bij
horen. Het notitiebestand is dan leidend: alles wordt weggegooid en van daaruit
teruggelezen, en pas daarna gaat de sidecar er weer naast.

`inspect-mark` beantwoordt de vraag die een gekleurd stuk tekst zelf niet kan
beantwoorden: waar komt dit vandaan? Het toont soort, hoofdstuk, kleur, de
XPointers van KOReader, waar de markering hier terecht is gekomen en hoe die
plek bepaald is.

## Wat het plaatst en wat niet

KOReader bewaart *gerenderde* tekst. `**bold words**` in de bron wordt
`bold words` in de sidecar, en een selectie over blokgrenzen is
aaneengeschreven. Daardoor is de opgeslagen tekst niet altijd letterlijk in
het bronbestand terug te vinden.

Elke mark krijgt een `confidence` die zegt hóé de positie is bepaald. Een
geschatte positie wordt nooit als exacte gepresenteerd.

| confidence | betekenis |
|---|---|
| `exact` | de opgeslagen tekst stond er eenduidig |
| `disambiguated` | meerdere kandidaten, teruggebracht tot één met een onafhankelijk signaal |
| `projected` | via de XPointer bepaald, niet via de tekst |
| `joined` | een selectie over een blokgrens, uit haar delen samengesteld |
| `approximate` | gevonden met een ruimere regel dan de andere routes |
| `elsewhere` | hoort bij een hoofdstuk dat nu niet in de buffer staat |
| `unresolved` | gemeld in plaats van geplaatst |

**Eenduidige tekst** wordt letterlijk gezocht — de opgeslagen tekst is data,
geen patroon. **Meerduidige tekst** wordt alleen vernauwd met harde grenzen:
de positie van een buurmark die zelf eenduidig is opgelost, de sectie van een
kop die maar één keer voorkomt, en de XPointer. Blijft er meer dan één
kandidaat over, dan wordt de mark gemeld in plaats van geplaatst. Een verkeerd
geplaatste markering is erger dan een onopgeloste.

**Tekst over nodegrenzen** kan niet gezocht worden. Bij Markdown en platte
tekst gaat die via de projectie: het pakket bouwt de documentstructuur na die
KOReader ziet en vertaalt de XPointer terug naar een bronpositie. Die
projectie wordt nooit op haar woord geloofd — het geprojecteerde bereik moet
de opgeslagen tekst reproduceren, en pas dan telt het.

**Bookmarks** hebben geen tekstbereik en dus niets om op te zoeken. Ze worden
geplaatst op hun `page`-XPointer, als puntmarkering zonder lengte. Let op wat
die plek betekent: `page` is het begin van de gerenderde pagina waarop de
bookmark staat, niet de zin die je aanwees. Vier bookmarks in vier fixtures
staan op pagina 1 en komen alle vier bovenaan het document uit.

Diezelfde XPointer maakt een bookmark juist bestand tegen wijzigingen in de
bron. Waar een highlight zich na een bronwijziging op zijn tekst moet
terugvinden, noemt de XPointer een blok en een offset daarbinnen; komt er
elders tekst bij, dan schuift de bookmark gewoon mee.

## Drie documentfamilies

KOReader rendert niet elk bestand hetzelfde, en dat is aan zijn XPointers te
zien. Welke familie geldt, staat dus in de sidecar zelf — een betrouwbaarder
signaal dan de bestandsnaam.

| bron | XPointer | hoe het pakket de positie vindt |
|---|---|---|
| Markdown | `/html/body/p[2]/text().26` | eigen boom nagebouwd uit de bron |
| platte tekst | `/FictionBook/body/pre[9]/text().42` | idem, met één `pre` per niet-lege regel |
| EPUB | `/body/DocFragment[3]/body/p[1]/text().0` | de XHTML zegt wat er staat, de nov-buffer zegt waar |

Bij Markdown en platte tekst lezen KOReader en Emacs hetzelfde bestand, dus is
de boom na te bouwen. Bij EPUB niet: `nov-mode` toont wat **shr** van de XHTML
maakt en KOReader wat **CRengine** ervan maakt. Daar wordt geen boom gebouwd —
de XPointer wijst het hoofdstuk en het element aan, en de tekst doet de rest.

In een `pre` telt het offset de bron onbewerkt in plaats van de samengeklapte
tekst; in de andere twee families telt het de gerenderde tekst. Dat verschil is
gemeten, niet gekozen.

## Notities en lokale bewerkingen

Een geïmporteerde notitie komt volledig in het Org-bestand te staan. Bewerk je
hem daarna in Emacs, dan laat een volgende import hem met rust — ook wanneer
je hem hebt leeggemaakt.

Dat werkt via een baseline: bij elke geslaagde import wordt de hash van de
notitie opgeslagen in de property `org-remark-koreader-note-hash`. Die baseline
maakt er een drieweg-vergelijking van — laatst geïmporteerd, huidig in
KOReader, huidig in Org — zodat zichtbaar wordt wie er iets veranderde:

| wie veranderde er iets | gedrag |
|---|---|
| niemand | ongewijzigd |
| alleen KOReader | verversen |
| alleen jij | jouw tekst blijft staan |
| allebei | conflict — jouw tekst blijft staan, en je krijgt het te zien |

Zonder baseline geldt: een lege body wordt gevuld, een gevulde body blijft
staan. Het bepalende signaal is dus niet of de body leeg is maar of er een
baseline is — een leeggemaakte notitie ná een import is een bewuste
verwijdering en wordt niet opnieuw gevuld.

Body en baseline worden altijd in dezelfde bewerking geschreven, zodat een
onderbreking nooit een baseline zonder body achterlaat.

## Opnieuw importeren

Importeren is geen toevoegactie maar een vergelijking van twee kanten. Het
rapport meldt wat er nieuw is, wat KOReader zelf wijzigde (kleur, tekst), en
wat er uit de sidecar is verdwenen.

Een annotatie die je in KOReader wist, wordt **niet** automatisch uit je
Org-bestand verwijderd — de notitie die je erbij schreef zou dan meeverdwijnen.
Ze wordt gemeld, met haar ID, zodat je zelf kunt beslissen.

Annotaties die je zelf met org-remark maakte blijven buiten deze vergelijking.

## Instellingen

| variabele | betekenis |
|---|---|
| `org-remark-koreader-sidecar-resolver` | functie die het sidecarpad zoekt, voor niet-standaard KOReader-indelingen |
| `org-remark-koreader-color-faces` | KOReader-kleur naar face |
| `org-remark-koreader-unknown-color-face` | face voor een onbekende kleur |
| `org-remark-koreader-lua-max-*` | grenzen voor bestandsgrootte, diepte, aantal velden en stringlengte |

Een onbekende kleur krijgt nooit stil de face van een bekende kleur; de
oorspronkelijke naam blijft bewaard.

## Veiligheid

De sidecar wordt gelezen, nooit uitgevoerd: geen `load`, geen externe
Lua-interpreter, geen shellaanroep. De lezer accepteert de datasubset die
KOReaders serializer schrijft en wijst al het overige af — functieaanroepen,
identifiers als waarden, niet-eindige getallen, tekst na de tabel. Grenzen op
bestandsgrootte, nestingdiepte, aantal velden en stringlengte sluiten
geheugenuitputting uit.

## Bouw

```text
org-remark-koreader.el          commando's, pennen, org-remark-adapter
org-remark-koreader-lua.el      beperkte Lua-lezer
org-remark-koreader-lua-write.el  hetzelfde formaat terug, byte voor byte
org-remark-koreader-model.el    genormaliseerd annotatiemodel, identiteit
org-remark-koreader-match.el    bronpositiebepaling, de ladder
org-remark-koreader-dom.el      de bron nagebouwd als CRengine-boom
org-remark-koreader-epub.el     de EPUB-familie, via nov.el
```

Niets laadt `-lua-write.el`: het levert tekst en raakt geen bestand aan. Het
bestaat omdat eerst bewezen moest zijn dat een sidecar ongewijzigd terug kan
komen, voordat er ooit een geschreven mag worden.

De lezer weet niets van Markdown, het model niets van org-remark, en
`-match.el` niets van EPUB: die familie meldt zich aan in een register. Zo
blijft de kennis van nov.el in één bestand, dat nov niet hoeft te vereisen om
geladen te kunnen worden.

## Uitproberen zonder de repo te vervuilen

Een import schrijft een `marginalia.org` naast het bronbestand. Om dat buiten
de repo te houden:

```sh
test/sandbox.sh                # toon de beschikbare documenten
test/sandbox.sh fixture        # zet er een klaar in een wegwerpmap
```

Open het pad dat eruit rolt en importeer daar.

## Tests

```sh
test/run-tests.sh
```

Zoekt org-remark en nov.el zelf op; wijs org-remark anders aan met
`ORG_REMARK_DIR`. Wat er niet is, wordt overgeslagen in plaats van gemist.

De suite toetst onder meer dat geen enkele geplaatste mark de verkeerde tekst
aanwijst, dat de nagebouwde boom dezelfde posities oplevert als de sidecar
beschrijft, dat een bookmark van nul lengte de opruiming van org-remark
overleeft, en dat import, opslaan, sluiten en heropenen mark én notitie
behouden zonder duplicaten.

De toets op de verkeerde tekst weegt het zwaarst. Die draait de echte
bronpositiebepaling op de gegenereerde corpus en legt elke uitkomst naast de
bytegrenzen die de generator uit zijn eigen scenariomarkeringen afleidt —
onafhankelijk van wat dit pakket doet. Dat is de enige toets die kan zien dat
een mark op de *verkeerde* plek staat in plaats van alleen dat hij ergens staat.
De suite houdt hem vast in `test/org-remark-koreader-corpus-tests.el`, en
`test/analyse-fixtures.el` drukt dezelfde meting per fixture af, met de details
van elke afwijking. Uitkomst:

```text
Markdown en platte tekst   47 van de 47 tekstbereiken, 9 van de 9 bookmarks
EPUB                       41 van de 41 bewerkingen
```

De corpus komt uit
[koreader-fixtures](https://github.com/jajpater/koreader-fixtures), waar hij
met een vastgepinde KOReader-build wordt gegenereerd.

`test/analyse-corpus.py` kijkt naar de andere kant: niet naar onze matching,
maar naar de sidecars zelf. Het leest de Lua puur als tekst — er wordt niets
uitgevoerd — en telt wat het formaat feitelijk bevat.

```sh
python3 test/analyse-corpus.py                 # de corpus in deze repo
python3 test/analyse-corpus.py ~/boeken        # je eigen sidecars
```

Wijs er een willekeurige map mee aan; die wordt doorlopen op `*.sdr`-mappen.
Draai hem op je eigen leescorpus om te zien of jouw boeken vormen bevatten die
de fixtures niet dekken — een kleur, een XPointer-pad of een escapevorm die we
niet gemeten hebben. Bronnen die geen platte tekst zijn, een EPUB is immers een
archief, tellen nog steeds mee voor alles wat alleen uit de sidecar volgt.

## Achtergrond

- [`docs/design.md`](docs/design.md) — waarom het pakket gebouwd is zoals het
  gebouwd is: de keuzes, de alternatieven die ertegen zijn afgewogen, en wat de
  metingen hebben uitgesloten
- [`docs/koreader-current-format.md`](docs/koreader-current-format.md) — wat
  het sidecarformaat feitelijk is, gemeten
- [`docs/org-remark-current-api.md`](docs/org-remark-current-api.md) — de
  org-remark-API, levenscyclus en inhaakpunten
- [`docs/epub-and-nov.md`](docs/epub-and-nov.md) — de andere kant van de
  EPUB-route: wat `nov-mode` van een boek maakt, en hoe een KOReader-XPointer
  daarin zijn weg vindt
- [`docs/notes-storage.md`](docs/notes-storage.md) — waar org-remark de
  annotaties bewaart, wat het verplaatsen daarvan vastlegt, en een draaiend
  experiment dat ze rechtstreeks uit de sidecar serveert

## Licentie

GPL-3.0-or-later.
