# Guida di revisione per l'AI: validare la build della documentazione Omnis

**Questo file è scritto per un agente AI di programmazione.** Consegnalo al tuo agente (Claude Code,
Codex, Copilot, …) quando fornisci a questo progetto la tua documentazione Omnis, e chiedigli di
eseguire la revisione descritta sotto. Gli script sono stati sviluppati su un insieme specifico di
documenti Omnis. Con altri file o un'altra versione di Omnis possono fallire senza alcun errore. Un
secondo paio d'occhi lo scopre, e un agente lo fa a basso costo.

Prompt suggerito:

> Leggi `Documentation/AI_Review_Guide_it.md` e `Documentation/Building_from_Omnis_Docs_it.md`. Ho
> messo i miei PDF Omnis in `Omnis PDF/` e (facoltativo) il mio doc pack in `<path>`. Esegui la
> pipeline passo per passo ed effettua la revisione della guida dopo ogni passo. Riporta i risultati
> come descrive la guida. Non modificare gli script prima di avermi mostrato le prove.

---

## 1. Contesto

Il progetto costruisce un server RAG a partire dalla documentazione di Omnis Studio:

```text
Omnis PDF/*.pdf  (+ optional doc pack from the HTML help)
  → scripts/extract.py     PDF → units (JSON), output/extracted/ and output/*_extracted.md
  → scripts/chunk.py       units (+ doc pack) → chunks, output/chunks/*_chunks.json
  → scripts/validate.py    structural quality gate, output/validation_report.json
  → scripts/embed_and_store.py   chunks → output/embeddings.jsonl
  → scripts/import_to_*.py       → PostgreSQL + pgvector → rag-server → MCP tools
```

Il repository è un **esempio** di un modo di procedere. Non è un prodotto, e nulla garantisce che
funzioni su documenti che non ha mai visto. Il tuo compito è scoprire se funziona sui documenti che
hai davanti e dire chiaramente dove non funziona.

Regole:

- La documentazione Omnis è © Omnis Software Ltd. Non committare, caricare o incollare mai i PDF, il
  doc pack, `output/` o testo estratto da essi in un luogo pubblico. Cita solo ciò che serve a un
  risultato.
- Non modificare i file di input.
- Non modificare uno script finché un controllo non ha mostrato un difetto concreto, e mostra prima le
  prove (la pagina PDF, il testo estratto e il chunk affiancati).
- Dopo ogni modifica: riesegui il passo interessato e `python scripts/validate.py`.
- Esegui con `python -I` il codice Python che legge file non attendibili.

---

## 2. Dove gli script dipendono dai documenti

Questi sono i punti che più spesso richiedono un adattamento quando l'input è diverso. Verifica ognuno
sui tuoi file.

| Dove | Cosa si assume | Controllo |
|---|---|---|
| `scripts/extract.py`, `SOURCES` | Nomi di file `CommandRef.pdf`, `FunctionRef.pdf`, `Programming_Omnis.pdf`; titoli delle panoramiche dei comandi ("Command information", "Command Groups", "Error Codes", …); panoramica di FunctionRef a pagina 2; testi delle etichette `Command group` / `Function group` | Questi titoli ed etichette sono presenti nel tuo PDF? La pagina 2 di FunctionRef corrisponde? |
| `scripts/extract.py`, `OMNIS_VERSION` | `"11"` | Corrisponde ai tuoi documenti? Finisce nei metadati |
| `scripts/extract.py`, font | Il nome del font del codice contiene `mono`/`courier`/`code` (`MONO_HINTS`); le intestazioni sono in grassetto; le intestazioni del manuale Programming hanno certe dimensioni (Montserrat-Bold ~11 / 9.2 / 7.7 pt) | Stampa font e dimensioni della prima intestazione, di una riga di codice e di un'etichetta di metadati nel tuo PDF (PyMuPDF `get_text("dict")`) |
| `scripts/extract.py`, `REFERENCE_SUBSECTIONS` | Sottointestazioni "Syntax", "Description", "Options", "Example", … | Le stesse etichette compaiono nel tuo PDF? |
| `scripts/extract.py`, `LigatureRepair` | Solo i caratteri di legatura "fi" e "fl" | Altre legature rotte ("ff", "ffi")? Altre lingue? |
| `scripts/extract.py`, `document_revision` | Revisione stampata nelle prime pagine come `Revision NNNNN` | Viene trovata? |
| `scripts/validate.py` | Conta le voci ma non controlla dove finisce l'ultima voce (P12); segnalibri di CommandRef al livello 3; voci di FunctionRef = numero di etichette "Function group" − 1; capitoli numerati consecutivamente; `LIGATURE_DAMAGE` è un **elenco fisso di parole**; regex `CODE_TITLE`; `MAX_CHUNK_WORDS = 600` | Questi controlli passano per i motivi sbagliati quando il tuo PDF non ha segnalibri o contiene altre parole danneggiate |
| `scripts/chunk.py` | `MAX_WORDS = 450`; le stringhe `"omnis_version": "11.1"` e "Not listed in the Omnis 11.1 help" sono scritte nel codice; nomi dei campi del doc pack (vedi `Building_from_Omnis_Docs_it.md`) | Sostituisci le stringhe di versione se usi un'altra versione dell'help |
| `scripts/eval_queries.json` | Domande di esempio con risultati attesi (espressioni regolari) | Sostituiscile con le domande dei tuoi sviluppatori; gli esempi riflettono un solo insieme di documentazione |

---

## 3. Problemi noti e come rilevarli

Per ogni problema: cosa vedi, perché accade, come verificare. Usa conteggi ed esempi, non impressioni.

### 3.1 Estrazione dal PDF

| # | Problema | Rilevamento |
|---|---|---|
| P1 | **Le intestazioni non sono marcate nel PDF.** I convertitori deducono le intestazioni dalla dimensione del font. Il font del codice è più grande dei titoli di sezione, quindi le righe di codice diventano intestazioni. | In `output/extracted/Programming.json` elenca i titoli che contengono `$`, `;`, `=`, `Returns #`, o che iniziano con `Calculate`, `Quit method`. Atteso: nessuno. Fai lo stesso per i titoli nei file di chunk |
| P2 | **I titoli delle voci sembrano etichette.** Il titolo di un comando usa lo stesso font grassetto dell'etichetta "Syntax". Una voce si fonde con la precedente e scompare. | Confronta il numero di voci in `CommandRef.json` con i segnalibri del PDF (`fitz.open(...).get_toc()`, livello 3) e quello di `FunctionRef.json` con il numero di etichette "Function group" nel PDF. Ogni differenza è una voce persa o inventata. Elenca i nomi mancanti |
| P3 | **Segnalibri o struttura mancanti** (PDF risalvato). `validate.py` salta in silenzio il controllo dei segnalibri quando non ce ne sono. | Stampa `len(get_toc())` per ogni PDF. Se è 0, il controllo dei segnalibri non prova nulla: verifica il numero di voci in altro modo (ordine alfabetico dei titoli, intervalli di pagine senza lacune) |
| P4 | **Legature fi/fl perse nelle tabelle** (`specifed`, `frst`, `fag`). | Cerca in tutti i testi dei chunk le parole che diventano inglese valido inserendo una "i" o una "l" dopo una "f". `validate.py` conosce solo un elenco fisso di parole: estendi tu il controllo con un dizionario |
| P5 | **Codice senza spazi** (`Calculatexas1`). I glifi sono posizionati senza caratteri spazio. | Apri 10 blocchi di codice (lunghi, corti, con stringhe, con operatori) e confrontali con la pagina PDF. Cerca nei blocchi di codice token molto lunghi senza spazi |
| P6 | **Tabelle di metadati rese in modo incoerente.** La conversione in Markdown produce più varianti di tabella; campi come "Flag affected" o "Platform(s)" vanno persi. | Per 10 voci confronta la riga di metadati nel chunk con la tabella nel PDF. Conta le voci senza `Command group`/`Function group`. Controlla se le chiavi hanno nomi troncati (`Pla`) |
| P7 | **Pagine a più colonne** (comandi obsoleti, elenchi dei gruppi di funzioni) sono mescolate o scartate. | Individua quelle pagine, estrai il loro testo con `page.get_text()` e confrontalo con i chunk. Ciò che manca lì è perso |
| P8 | **Elementi di pagina** (intestazioni, piè di pagina, numeri di pagina) finiscono nel testo. | Trova le righe che ricorrono molte volte tra i chunk |
| P9 | **Chunk troppo grandi o vuoti.** | Distribuzione del numero di parole per corpus; i 10 chunk più grandi e i 10 più piccoli letti da una persona |
| P10 | **Tabelle divise su più pagine** perdono l'intestazione o si fondono con il testo seguente. | Trova i chunk che contengono righe `|` senza riga di intestazione |
| P11 | **Versioni miste.** PDF e help descrivono versioni diverse di Omnis. | La parte informativa di `validate.py` elenca le voci presenti solo da un lato. Un elenco lungo indica versioni diverse. Indica quali voci sono interessate |
| P12 | **L'ultima voce assorbe ciò che la segue.** Il materiale dopo l'ultima voce (appendici, elenchi di gruppi, capitoli non correlati) viene attaccato ad essa, perché nulla segna dove finisce la voce. La build dell'autore lo ha mostrato per l'ultima funzione di FunctionRef: i suoi chunk (due parti) contenevano elenchi di gruppi di funzioni e il capitolo sul worker FileOps. Le ricerche restituivano poi quel chunk per termini non correlati, sotto il titolo sbagliato. `validate.py` conta solo le voci e non se ne accorge. | Leggi per intero l'**ultima voce di ogni riferimento** (e l'ultima sezione del manuale) e confronta il suo intervallo di pagine e il suo testo con il PDF. Segnala i chunk il cui testo è molto più lungo delle voci circostanti, il cui intervallo di pagine copre più pagine, o che contengono elenchi di molti nomi non correlati. Cerca un termine che appartiene all'appendice e guarda sotto quale titolo viene trovato |

### 3.2 Help HTML e doc pack

| # | Problema | Rilevamento |
|---|---|---|
| H1 | **Cartella dell'help incompleta.** Un'installazione può contenere una copia ridotta dell'help accanto a quella completa. Nulla fallisce, ma manca contenuto. | Confronta il numero di pagine delle cartelle; confronta i conteggi di comandi, funzioni e pagine di notazione con i conteggi nei cataloghi |
| H2 | **Versione sbagliata.** Un pack dipende dalla versione. | Prova cinque nomi aggiunti o rimossi nella versione per cui sviluppi |
| H3 | **Firme rotte.** Parentesi che non si chiudono mai, spazi estranei (`( x`, `bFromStart= kTrue`). | Analizza ogni firma per verificare che le parentesi siano bilanciate e cerca gli spazi doppi |
| H4 | **Tabelle con celle unite o vuote** (membri di notazione, tabelle di parametri). | Controlla a campione 5 pagine di notazione confrontandole con l'help in un browser. Conta i membri per pagina rispetto all'help |
| H5 | **Righe segnaposto vuote** nelle tabelle di notazione. | Trova le righe di membri con descrizione vuota |
| H6 | **Catalogo e pagine non coincidono.** | Ogni `markdown_path` esiste; ogni pagina ha una riga nel catalogo; i nomi sono unici |
| H7 | **Flag di deprecazione sbagliati o mancanti.** | Prendi 10 comandi che sai essere legacy e verifica che `deprecated` sia impostato. Prendine 10 che sai essere attuali e verifica che non lo sia |
| H8 | **I nomi di notazione perdono il `$`.** Il catalogo elimina il `$` in alcuni percorsi `$root`. | Confronta `container` con il titolo della pagina per dieci nodi |

### 3.3 Chunk, embedding e retrieval

| # | Problema | Rilevamento |
|---|---|---|
| C1 | **Id duplicati o instabili.** | `validate.py` segnala i duplicati; verifica anche che due esecuzioni producano gli stessi id |
| C2 | **`embed_text` e `text` divergono** (il testo dell'embedding contiene una riga di contesto). | Leggi 5 chunk: la riga di contesto indica la voce, il gruppo e il corpus corretti? |
| C3 | **Embedding obsoleti** (chunk cambiati, vettori no). | `python scripts/pipeline.py doctor` deve mostrare `missing/stale: 0`; l'importer rifiuta gli embedding obsoleti |
| C4 | **Limite di modello/token non coerente.** I chunk più lunghi del limite del modello vengono troncati durante l'embedding. | Confronta il limite di token memorizzato per ogni record in `embeddings.jsonl` con il chunk più lungo |
| C5 | **Il retrieval sembra corretto sugli esempi ma non sulle domande reali.** | Scrivi 20–40 query tratte da domande reali degli sviluppatori con la voce attesa, esegui `python scripts/eval_retrieval.py --compare` e leggi i mancati. Includi nomi esatti, domande in tedesco, membri di notazione (`$search`), variabili hash (`#ERRCODE`) |

---

## 4. Procedura

Procedi passo per passo. Alla fine di ogni passo annota cosa hai controllato, i numeri e gli esempi
che hai confrontato a mano.

1. **Input.** Elenca i file in `Omnis PDF/` con numero di pagine, numero di segnalibri e numero di
   revisione. Annota il percorso del doc pack e i conteggi del suo catalogo (oppure che non ne usi
   uno).
2. **Verifica di compatibilità.** Percorri la tabella della sezione 2 e indica per ogni riga se
   corrisponde ai tuoi file. Fallo *prima* della prima esecuzione.
3. **extract.** Esegui `python scripts/extract.py`. Leggi gli avvisi che stampa. Applica P1–P8 e P12 a
   `output/extracted/*.json` e ai file `output/*_extracted.md`.
4. **chunk.** Esegui `python scripts/chunk.py`. Conferma che la prima riga di output indica il doc
   pack che intendevi usare. Applica P9–P12 e H1–H8.
5. **validate.** Esegui `python scripts/validate.py`. Indica quali controlli sono passati *e quali non
   potevano fallire con il tuo input* (per esempio il controllo dei segnalibri senza segnalibri).
6. **Confronto manuale.** Scegli 10 voci PDF e (con un pack) 5 pagine di notazione, distribuite lungo
   il documento: la prima, l'ultima, la più lunga, la più corta, una con tabella, una con codice, una
   deprecata. Affianca pagina PDF, testo estratto e chunk.
7. **embed e import.** Esegui i passi restanti. Applica C1–C4.
8. **Retrieval.** Applica C5 con le tue query.
9. **Report** (formato sotto).

### Formato del report

```text
Inputs:       <files, pages, bookmarks, revision, doc pack>
Fit check:    <rows of section 2 that do not fit>
Counts:       <entries per source, chunks per corpus, expected vs. actual>
Findings:     <ID> <severity> <what> — evidence: <page / chunk id / sample> — proposed fix
Unverified:   <what could not be checked and why>
Changes made: <script, reason, evidence, re-run result>
```

Gravità: **high** = contenuto mancante o errato (voci perse, codice mescolato), **medium** = qualità
ridotta (parole danneggiate, metadati mancanti), **low** = estetica.

Non riportare "sembra a posto" senza numeri ed esempi. Se non puoi eseguire un controllo, dillo.

---

## 5. Quando uno script deve cambiare

- Fai la modifica più piccola che corregge il difetto, nel punto indicato nella sezione 2.
- Preferisci una regola che deriva dalla struttura del documento (segnalibri, font, posizioni delle
  tabelle) a un elenco di casi speciali. I casi speciali si rompono alla versione successiva.
- Aggiungi a `scripts/validate.py` il controllo che avrebbe rilevato il difetto.
- Riesegui il passo e `validate.py`, poi riconfronta le voci che hanno motivato la modifica.
- Descrivi la modifica nel tuo report.
