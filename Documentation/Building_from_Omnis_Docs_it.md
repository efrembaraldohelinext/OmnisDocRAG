# Costruire il RAG Server dalla tua documentazione di Omnis

## Cos'è questo progetto e cosa non è

Questo repository mostra **un modo** per trasformare la documentazione di Omnis in un RAG server che gli
assistenti di programmazione AI possono interrogare. È scritto in modo che uno sviluppatore senza
esperienza di RAG possa farsi un'idea dell'intero percorso (documenti → testo → chunk → embedding →
database → ricerca → tool MCP) e costruire da esso un **primo MVP funzionante**. È un esempio, non un prodotto:

- Gli script sono stati sviluppati su documenti Omnis specifici. Con altri file o un'altra versione
  potrebbe essere necessario adattarli. Non segnalano i propri errori silenziosi.
- Altri approcci sono validi (altri estrattori, dimensioni dei chunk, modelli di embedding, vector
  store). I documenti di questa cartella spiegano perché questo progetto ha fatto le sue scelte, così
  puoi fare le tue.
- **Fai validare e rivedere il risultato, idealmente con un agente AI.** L'estrazione della
  documentazione tecnica è soggetta a errori, e i controlli automatici individuano solo i danni per cui
  sono stati scritti. [AI_Review_Guide_it.md](AI_Review_Guide_it.md) è un documento scritto per un
  agente AI: descrive i problemi, i punti in cui gli script dipendono dai documenti e cosa controllare.
  Consegnalo al tuo agente insieme ai tuoi documenti.

Percorso suggerito per chi inizia: leggi [RAG_concept_it.md](RAG_concept_it.md), poi questa guida, poi
esegui la pipeline solo sui PDF (senza doc pack) per ottenere un primo server funzionante. Aggiungi il
doc pack e le tue domande di valutazione in un secondo momento.

---

Questo repository non contiene **alcuna documentazione di Omnis** né nulla di generato da essa. I
manuali e l'help HTML sono © Omnis Software Ltd. Ogni sviluppatore costruisce il corpus dalla propria
installazione Omnis con licenza. Questa guida descrive la costruzione passo per passo, indica cosa va
storto quando si estrae la documentazione ed elenca cosa controllare dopo ogni passo.

> Non pubblicare i PDF, il doc pack, `output/` (Markdown estratto, chunk, embedding) né un dump del
> database. Gli embedding e il testo dei chunk derivano dalla documentazione. Condividili solo dove la
> tua licenza Omnis lo consente, ad esempio all'interno del tuo team. Il `.gitignore` di questo
> repository li esclude tutti.

---

## 1. Cosa serve

| Input | Usato per | Provenienza | Destinazione |
|---|---|---|---|
| `CommandRef.pdf` | `omnis-commands` | Manuale PDF di Omnis "Command Reference" | `Omnis PDF/` |
| `FunctionRef.pdf` | `omnis-functions` | Manuale PDF di Omnis "Function Reference" | `Omnis PDF/` |
| `Programming_Omnis.pdf` | `omnis-programming` | Manuale PDF di Omnis "Programming with Omnis Studio" | `Omnis PDF/` |
| **Doc pack** (opzionale), creato dall'help HTML | `omnis-notation`, dati di deprecazione, voci mancanti nei PDF | L'help HTML nella cartella di installazione di Omnis Studio; lo converti tu | qualsiasi cartella, imposta `OMNISDOC_PACK` |

I tre nomi di file sono fissati in `scripts/extract.py`. Il doc pack è opzionale. Senza di esso la
pipeline costruisce solo i tre corpus dei PDF: nessun corpus notation (`$line`, `$search`, …), nessun
flag di deprecazione e nessuna delle voci che esistono solo nell'help HTML.

I PDF e l'help HTML sono versioni diverse della documentazione (vedi
[Deriva di versione](#deriva-di-versione)). Prendi entrambi dalla versione di Omnis per cui il tuo team scrive codice.

---

## 2. Passo per passo

### 2.1 Metti i PDF al loro posto

Copia i tre PDF in `Omnis PDF/`.

### 2.2 Fornisci il doc pack (opzionale)

L'help HTML è incluso nell'installazione di Omnis Studio (una cartella `idehelp/omnis` con `commands/`,
`functions/` e `notation/`). `scripts/chunk.py` non legge HTML. Legge un **doc pack**: l'help
convertito in Markdown più cataloghi JSONL. Questo repository non contiene alcun convertitore. Tu
fornisci il pack, e la pipeline specifica soltanto cosa si aspetta:

```text
<pack>/
├── catalogs/
│   ├── commands.jsonl      un oggetto JSON per riga: name, markdown_path, deprecated, modern_equivalent, scope_category
│   ├── functions.jsonl     name, markdown_path
│   └── notation.jsonl      name, markdown_path, container, container_canonical, deprecated
└── md/
    ├── commands/…          una pagina Markdown per ogni pagina dell'help
    ├── functions/…
    └── notation/…
```

- `markdown_path` è relativo alla radice del pack (`md/commands/…`). `name` è il nome esatto della voce
  come appare nell'help (`Do method`, `mid()`, `$search`).
- Pagine di comandi e funzioni: front matter opzionale, un `# Title`, una sezione `## Metadata` come
  tabella Markdown a due colonne (campo, valore) e le sezioni rimanenti come `## Heading` (Syntax,
  Description, Example, …). Il codice è in blocchi recintati. Una riga `Source:` viene ignorata.
- Pagine di notazione: front matter con `title`, una descrizione e, per ogni sezione (`## Properties`,
  `## Methods`, …), una tabella Markdown la cui prima colonna è il nome del membro e le altre colonne
  ne sono la descrizione. I membri che non si chiamano `$…`, `#…` o `k…` vengono trattati come testo semplice.
- Vengono usati solo i campi elencati sopra. Tutto il resto nei cataloghi viene ignorato.

Indica il pack alla pipeline in `scripts/.env.local` (ignorato da git) oppure con `--omnisdoc`:

```env
OMNISDOC_PACK=/path/to/omnisdoc
```

`chunk.py` stampa `Doc pack: <path>` come prima riga; controllala. Senza pack usa
`chunk.py --without-docpack`.

**Usa l'help completo.** Alcune installazioni contengono, accanto a quella completa, una seconda
cartella di help ridotta (qui: `jsidehelp` accanto a `idehelp`) con lo stesso layout ma solo un
sottoinsieme delle pagine. Non fallisce nulla, il corpus è semplicemente incompleto. Confronta il
numero di pagine delle cartelle prima di convertire.

### 2.3 Esegui la pipeline

```bash
python scripts/pipeline.py setup
python scripts/pipeline.py doctor     # shows whether embedding runs on GPU/Apple Silicon (minutes) or CPU (hours)
python scripts/pipeline.py build      # extract → chunk → validate → embed → import → eval
```

Oppure passo per passo: `extract.py` → `chunk.py` → `validate.py` → `embed_and_store.py` → importazione → `eval_retrieval.py`.
Dettagli: [Pipeline_it.md](Pipeline_it.md). Setup di database e server: i README delle cartelle Docker.

**`validate.py` è un gate, non una prova.** Termina con codice diverso da zero in caso di danni
strutturali che è stato scritto per trovare. Per sapere se il contenuto è corretto servono comunque i
controlli seguenti, e alcuni suoi controlli non possono fallire con certi input (ad esempio il
controllo dei bookmark su un PDF senza bookmark).

**Adattare gli script.** Se i documenti differiscono da quelli per cui gli script sono stati scritti,
gli script vanno modificati. Font, dimensioni, testi delle etichette e nomi dei file sono codificati
in `scripts/extract.py`, e `validate.py` contiene elenchi di parole fissi. La tabella "Dove gli script
dipendono dai documenti" in
[AI_Review_Guide_it.md](AI_Review_Guide_it.md#2-dove-gli-script-dipendono-dai-documenti) elenca ogni
punto di questo tipo.

---

## 3. Problemi nell'estrazione dei PDF

Queste sono le trappole trovate nei manuali di Omnis. Aspettati le stesse classi di problemi in
qualsiasi PDF non taggato. Contesto e correzioni implementate in `scripts/extract.py`:
[chunking_concept_it.md](chunking_concept_it.md).

| # | Problema | Sintomo nell'output | Motivo | Cosa controllare |
|---|---|---|---|---|
| 1 | **Le intestazioni non sono taggate** | Titoli errati; righe di codice usate come titoli di sezione | I convertitori PDF deducono le intestazioni dalla dimensione del font; il font del codice è più grande dei titoli di sezione | Nessun titolo di chunk assomiglia a codice (`Calculate x as …`, `$ctask.$x()`) |
| 2 | **Il titolo della voce sembra un'etichetta** | Un comando o una funzione viene unito alla voce precedente e scompare | I titoli delle voci usano lo stesso font in grassetto di "Syntax", "Description" | Numero di voci = numero di bookmark (CommandRef) o di tabelle di metadati (FunctionRef) |
| 3 | **Nessun bookmark né struttura** | Niente a cui ancorare le sezioni | I PDF salvati di nuovo (ad esempio con Anteprima di macOS) perdono i bookmark | Il PDF ha un indice (`fitz.open(...).get_toc()`)? Quale percorso di estrazione riporta il log? |
| 4 | **Legature "fi" / "fl"** | `specifed`, `frst`, `fag`, `usequalifers` | L'estrazione delle tabelle perde il secondo carattere di una legatura | Nessun danno da legature residuo; campiona parole con "fi"/"fl" nelle tabelle |
| 5 | **Codice senza spazi** | `Calculatexas1` | I glifi sono posizionati, il PDF non contiene caratteri di spazio | Apri i blocchi di codice di alcune voci e leggili |
| 6 | **Le tabelle di metadati vengono rese in modo incoerente** | Mancano "Flag affected", piattaforma, gruppo | La conversione in Markdown produce tre varianti di tabella e a volte testo semplice | Confronta la riga di metadati di 5–10 voci con la pagina del PDF |
| 7 | **Pagine di indice a più colonne** | Elenchi come i comandi obsoleti o i gruppi di funzioni mancano o sono mescolati | L'ordine delle colonne si perde nella conversione in Markdown | Tutto ciò che proviene dalle pagine di indice si controlla separatamente |
| 8 | **Taglio al bordo della pagina** | Celle di intestazione come `Pla` invece di `Platform` | Testo tagliato al bordo della pagina | Le chiavi dei metadati devono risultare complete |
| 9 | **Elementi di pagina** | Intestazioni, piè di pagina e numeri di pagina dentro il testo | Ripetuti su ogni pagina | Cerca con grep le righe ripetute tra i chunk |
| 10 | **Voci troppo grandi** | Chunk molto sopra il limite di dimensione | Tabelle o listati di codice lunghi | `validate.py` fallisce sopra 600 parole (`chunk.py` divide a 450); controlla come sono state divise le voci lunghe |

Regole pratiche valide per ogni PDF:

- **Le euristiche sono tarate su file specifici.** Nomi e dimensioni dei font (Montserrat-Bold a certe
  dimensioni in punti, LMMono10 per il codice) sono codificati in `extract.py`. Un'altra versione del
  manuale, un file salvato di nuovo o un'esportazione diversa possono romperle in silenzio. Dopo ogni
  cambio di input, ricontrolla a mano; non fidarti solo dell'exit code.
- **Confronta con la fonte.** Prendi dieci voci distribuite nel documento (la prima, l'ultima, una
  lunga, una corta, una con una tabella, una con codice) e confronta fianco a fianco pagina del PDF e chunk.
- **Conta, non leggere.** Voci per PDF, chunk per corpus, bookmark per comando. Un conteggio che
  cambia di qualche punto percentuale tra un'esecuzione e l'altra è un risultato da indagare.

---

## 4. Problemi con l'help HTML e il doc pack

L'help è HTML generato con molte irregolarità. Qualunque convertitore usi, controlla il risultato
confrontandolo con l'help in un browser.

| Problema | Cosa controllare |
|---|---|
| Cartella di help incompleta | Numero di pagine: pagine di comandi, funzioni e notazione rispetto all'help completo |
| Versione di Omnis sbagliata | Un pack dipende dalla versione. Converti l'help della versione per cui sviluppi |
| Firme dei metodi con parentesi rotte o spazi estranei | Cerca nel pack le firme la cui `(` non si chiude mai |
| Tabelle con celle unite o vuote (membri della notazione, parametri) | Controlla a campione cinque pagine di notazione con tabelle |
| Righe segnaposto vuote nelle tabelle di notazione | Campiona le pagine delle costanti e delle variabili hash |
| Link che non portano da nessuna parte | Contali durante la conversione; tieni il numero basso e spiegabile |
| Informazioni di deprecazione | Scegli alcuni comandi legacy noti e verifica che `deprecated` sia impostato |
| Catalogo e pagine non coincidono | Ogni `markdown_path` esiste; ogni pagina ha una riga nel catalogo |

### Deriva di versione

| Fonte | Versione | Conseguenza |
|---|---|---|
| Manuali PDF | quella che hai (il numero di revisione è stampato nelle prime pagine e letto da `extract.py`) | Possono mancare comandi e funzioni più recenti |
| Help HTML | la versione di Omnis installata | Può contenere voci che mancano nel PDF (e viceversa) |

`chunk.py` unisce entrambi: le voci che esistono solo nell'help vengono aggiunte (`source: OmnisDocPack`),
le voci del PDF che l'help non elenca più ricevono `in_help_11_1: false` (il nome della chiave è
storico). Leggi la sezione informativa dell'output di `validate.py`: elenca le voci che esistono in una
sola fonte. Un elenco lungo significa che il PDF e l'help provengono da versioni diverse.

---

## 5. Revisione con un agente AI

Consegna [AI_Review_Guide_it.md](AI_Review_Guide_it.md) al tuo agente di programmazione insieme ai tuoi
documenti e chiedigli di eseguire la pipeline e la revisione passo per passo. Contiene i problemi
sopra descritti nel dettaglio, il metodo di rilevamento per ciascuno, una procedura e un formato di
report. Leggi tu stesso i suoi risultati: anche l'agente può sbagliare, per questo deve mostrare le
prove (pagina, testo estratto e chunk affiancati).

---

## 6. Checklist

Dopo ogni build:

1. Il doc pack (se usato) supera i tuoi controlli della sezione 4.
2. `python scripts/validate.py` termina con 0. Leggi la sua sezione informativa, non solo l'exit code.
3. I conteggi delle voci corrispondono alle fonti: comandi = bookmark del PDF, funzioni = tabelle di metadati del PDF.
4. Nessun titolo di chunk assomiglia a codice; nessun danno da legature; nessun chunk è vuoto o troppo grande.
5. Dieci voci del PDF e (con un pack) cinque pagine di notazione confrontate a mano con la fonte.
6. Il doc pack è quello che intendi usare: `chunk.py` stampa `Doc pack: <path>` all'inizio.
7. `python scripts/eval_retrieval.py --compare` produce numeri plausibili con le **tue** query:
   `scripts/eval_queries.json` è un insieme di esempio; sostituiscilo o amplialo con le domande che i
   tuoi sviluppatori pongono davvero, indicando il risultato atteso per ogni query.
8. I tool MCP rispondono dal client VS Code: cerca un comando che conosci, poi recupera il suo testo
   completo con `get_omnis_doc` e leggilo.
9. Nessun contenuto derivato dalla documentazione è in staging per git: `git status` non mostra PDF,
   `output/` né pack.

Quando cambia la versione di Omnis: sostituisci i PDF, ricostruisci il doc pack dal nuovo help ed
esegui di nuovo `pipeline.py build`. `embed_and_store.py` ricalcola solo i chunk modificati.
