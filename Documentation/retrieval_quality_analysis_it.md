# Analisi della qualità del retrieval e piano di miglioramento

Stato: analisi del 2026-09-28, implementata (vedi sezione 7).
Ambito: lo stack Docker `docker_mcp-rag-pg` (che compila `docker_mcp-rag/rag-server` e `docker_mcp-rag/mcp-server`) e la pipeline di ingestion in `scripts/`.

> Tutti i numeri di questo documento sono stati misurati sulla build dell'autore (PDF di Omnis 11.0, help di Omnis 11.1) e
> servono come riferimento. I tuoi conteggi e punteggi saranno diversi con altre versioni della documentazione.

Obiettivo: un indice **completo quanto i PDF**, utilizzabile per la ricerca **semantica e fulltext**, con **risposte compatte**, in modo che ogni chiamata a un tool costi poco all'agente chiamante.

---

## 1. Riepilogo

Il modello di embedding (`BAAI/bge-m3`) non è il problema. I punti deboli, in ordine di impatto, sono:

1. **Dimensione della risposta** — una chiamata MCP restituisce 50–105 KB; lo stesso testo compare fino a quattro volte.
2. **Ranking** — un `k` fisso per corpus e un punteggio RRF per corpus mescolano risultati fuori tema nelle prime posizioni.
3. **Ramo fulltext** — la query lessicale mette in AND ogni parola, quindi quasi mai trova corrispondenze per domande in linguaggio naturale.
4. **Estrazione e chunking** — i PDF contengono le informazioni, ma la pipeline perde il 13% dei comandi e il 7% delle funzioni, e trasforma 220 righe di codice in titoli di sezione.
5. **Copertura** — solo tre manuali; la notation e diversi argomenti non sono nell'indice.

Una modifica al solo ranking (un unico ranking vettoriale globale su tutti i corpus, senza re-ingestion) porta già MRR@5 da 0.62 a 0.79 sul set di test.

---

## 2. Metodo

- 18 query che coprono comandi, funzioni, notation, concetti, SQL, JSON, form remote JavaScript, un nome di simbolo esatto e una domanda in tedesco.
- Ogni query ha una regex `gold` che deve corrispondere al titolo di un chunk rilevante (`corpus :: command_name | function_signature | section`).
- Metriche sui primi 5 risultati: **Hit@5** (gold presente) e **MRR@5** (reciprocal rank medio del primo risultato gold).
- Set di query: [`scripts/eval_queries.json`](../scripts/eval_queries.json); runner: [`scripts/eval_retrieval.py`](../scripts/eval_retrieval.py).

```bash
python scripts/eval_retrieval.py --param k_commands=4 --param k_functions=4 --param k_programming=10
```

Avvertenza: 18 query con pattern gold definiti da noi mostrano una tendenza, non una prova. I risultati sulla qualità dei dati nella sezione 4.4 sono conteggi esatti.

---

## 3. Risultati di base

| Variante | Hit@5 | MRR@5 | Note |
|---|---|---|---|
| **Attuale** (default di `search_omnis_docs`, k = 4/4/10) | 14/18 | 0.62 | media 52 KB HTTP, ~100 KB via MCP |
| Ranking vettoriale globale su tutti i corpus (esperimento SQL) | 16/18 | **0.79** | stesso indice, senza re-ingestion |
| Hybrid globale con query fulltext OR naive (esperimento SQL) | 12/18 | 0.50 | il ramo lessicale sul contenuto grezzo peggiora i risultati |

Latenza: 140–220 ms a caldo; la prima richiesta dopo l'avvio del container ha richiesto ~14.6 s (warm-up del modello).

Query che falliscono in tutte le varianti: `binfrombase64` (il chunk non esiste, vedi 4.4) e `set the current line of a list` (`$line` — notation non indicizzata, vedi 4.5).

---

## 4. Risultati dell'analisi

### 4.1 Dimensione della risposta e costo in token

`mcp-server/server.py` restituisce `resp.text`, cioè il JSON completo di `/search`:

- `chunks[].content` **e** `context_text` contengono lo stesso testo (×2).
- I tool dichiarano un tipo di ritorno `str`, quindi FastMCP aggiunge un `outputSchema` e invia di nuovo il risultato come `structuredContent` (di nuovo ×2).
- I valori `k` predefiniti restituiscono 14–20 chunk per chiamata.

Misurato: 50 KB per query via HTTP, 105 KB per una chiamata MCP (Q01). Sono circa 25k token per ricerca.

### 4.2 Ranking: k fisso per corpus + RRF tra corpus

`rag.search_omnis_docs` esegue `search_hybrid` una volta per corpus e concatena i risultati ordinati per `rrf_score`.
L'RRF si basa sulla posizione, quindi la posizione 1 di *ogni* corpus ottiene lo stesso punteggio (~1/61), indipendentemente dalla similarità reale.
Risultato: per "extract a substring from a string" i primi 3 sono una sezione XML di Oracle, `Strip()` e `MailSplit`; `mid()` non è nei primi 5.
I tre tool MCP differiscono solo nei valori predefiniti di `k`, quindi spetta al chiamante indovinare la miscela giusta.

### 4.3 Ramo fulltext

- `search_hybrid` costruisce `to_tsquery('simple', 'w1 & w2 & ...')`. Ogni parola, comprese le stop word, deve comparire nel chunk → per le domande in linguaggio naturale `fts_rank` è vuoto nella maggior parte dei risultati.
- I caratteri speciali (`$`, `#`, `()`) possono far fallire `to_tsquery`; l'eccezione viene ignorata e il ramo scompare senza avviso.
- `content_tsv` usa la configurazione `simple` (senza stemming) su tutto il contenuto, senza pesi per campo. Un passaggio naive a OR peggiora i risultati (MRR 0.50), perché dominano i chunk lunghi con parole comuni (`list`, `line`).
- Il fallback inline in `ragserver.py` usa `websearch_to_tsquery` — un comportamento diverso dalla funzione del database.

La ricerca fulltext serve, ma richiede un progetto proprio (sezione 5, fase 3), non solo OR al posto di AND.

### 4.4 Estrazione e chunking

I PDF contengono le informazioni. Si perdono nella pipeline.

**CommandRef.pdf** (499 bookmark di comandi)

| Fase | Conteggio |
|---|---|
| Bookmark (livello 3, dalla pagina 11) | 499 |
| Tabelle di metadati in `CommandRef_extracted.md` | 491 |
| Comandi distinti in `commands_chunks.json` | 434 |
| **Mancanti** | **66 (13%)** — ad es. `OK message`, `Yes/No message`, `For each line in list`, `Quit all methods`, `Open window instance`, `Do async method`, `HTTPGet`, `HTTPPost`, `SMTPSend`, `While flag true` |
| Chunk senza `command_group` interpretato | 168 su 485 |

Cause principali:

- `pymupdf4llm` a volte rende il titolo del comando come `**Name**` invece di `## Name` (34 casi). `find_boundaries()` accetta solo righe H2, quindi la voce viene accodata al chunk precedente (`Advise on find/next/previous` finisce dentro `Add line to list`).
- La tabella dei metadati ha tre varianti di intestazione; `extract_command_metadata()` interpreta solo quella a 5 colonne. La variante `|Reversible<br>Execute on client<br>Platform(s)|` (169 tabelle) produce un gruppo vuoto e flag errati.
- Il PDF ha **508 bookmark con numeri di pagina** (LaTeX/hyperref). Non vengono usati; darebbero i confini esatti delle voci.

**FunctionRef.pdf**

| Fase | Conteggio |
|---|---|
| Tabelle di metadati in `FunctionRef_extracted.md` | 352 |
| Chunk in `functions_chunks.json` | 327 |
| **Mancanti** | **≥ 25 (7%)** — ad es. `binfrombase64()`, `abs()`, `int()`, `bool()`, `errtext()`, `coalesce()`, `charat()` |

Cause principali: lo stesso problema dei titoli in grassetto (29 titoli come `**name()**`); `abs()` viene recuperata solo da un caso speciale. Questo PDF è stato salvato di nuovo con PDFium e **non ha bookmark**.

**Programming_Omnis.pdf** (614 pagine, salvato di nuovo con macOS Preview, **senza bookmark**)

- 220 chunk su 1,543 hanno una **riga di codice come titolo di sezione** (`Do StatementObj.$prepare() Returns #F`, `.omh text eol=crlf`, `OK message SQL Error {...}`), e questo divide anche le sezioni a metà.
- Causa principale (profilo dei font, pagine 85–400):

  | Font | Dimensione | Usato per |
  |---|---|---|
  | Montserrat-Bold | 11.0 | Titoli dei capitoli |
  | Montserrat-Bold | 9.2 | Titoli delle sezioni |
  | **LMMono10-Regular** | **9.6** | **Codice** |
  | Montserrat-Bold | 7.7 | Titoli delle sottosezioni e grassetto inline |
  | Montserrat-Regular | 7.8 | Testo del corpo |

  `pymupdf4llm` individua le intestazioni dalla dimensione del font; il codice (9.6 pt) è più grande dei titoli di sezione (9.2 pt), quindi le righe di codice diventano intestazioni. Un estrattore basato sui font le separa senza ambiguità.
- Nessun percorso delle intestazioni: un chunk conosce solo il proprio capitolo e la propria intestazione, non la sezione padre.
- 164 chunk condividono il titolo con un altro chunk (`Session Properties` ×15), e questo rende ambigui i titoli nei risultati.
- `skip_pages` in `extract.py` è scritto nel codice per un'edizione di 508 pagine; con il file di 614 pagine è sfasato di circa una pagina (l'indice di pagina 156, ancora capitolo 3, viene saltato). Il filtro dei capitoli in `chunk.py` gestisce il resto.

### 4.5 Copertura

- Indicizzati: CommandRef, FunctionRef, Programming (senza i capitoli 1 e 4).
- Non indicizzati: il **riferimento della notation** (`$line`, `$search`, `$sendall` come membri di oggetti list/window/...), la documentazione dei componenti esterni oltre a quanto contiene FunctionRef (OJSON, web service), la documentazione dei componenti client JavaScript/web.
- I tool pubblicizzano un corpus `omnis-code` che non esiste.

### 4.6 Igiene del repository

- `scripts/.env` e `OmnisRAGServer/rag-server/.env` sono tracciati nonostante `.gitignore` (dal commit iniziale) e contengono una password del database. Il repository è pubblico.
- `ragserver.py` esiste due volte (`docker_mcp-rag/rag-server/`, `OmnisRAGServer/rag-server/`), al momento identico.
- `Documentation/chunking_concept_en.md` descrive un manuale Programming di 508 pagine con 11 capitoli; il file attuale ha 614 pagine e capitoli fino al 17.

---

## 5. Piano di miglioramento

Ricostruire l'indice costa poco, quindi il piano preferisce una re-ingestion pulita alla correzione dei chunk esistenti. Ogni fase termina con un'esecuzione di `scripts/eval_retrieval.py`; i risultati sono registrati nella sezione 6.

### Fase 1 — Server: dimensione della risposta e ranking (senza re-ingestion)

1. **Risposta compatta.** I tool MCP restituiscono solo testo formattato: per ogni risultato `title`, `source + page`, `chunk_id`, contenuto. Niente JSON grezzo, niente duplicato `context_text`, niente `structuredContent` (dichiara i tool senza output schema).
2. **Retrieval in due fasi.** `search` restituisce una lista ordinata con un breve snippet per risultato (per il fulltext: `ts_headline`); un `get_chunk(chunk_id)` separato restituisce il testo completo su richiesta. Obiettivo: ≤ 5 KB per chiamata di ricerca.
3. **Un unico ranking globale** su tutti i corpus con un solo `top_k` (default 6–8) e un filtro `corpus` opzionale, al posto di un `k` fisso per corpus. Unisci i tre tool in un unico tool di ricerca con un parametro `mode` (vedi fase 3).
4. **Raggruppamento per voce**: al massimo un chunk per comando/funzione/sezione nella lista dei risultati.
5. **Warm-up** del modello di embedding all'avvio.

Criterio di accettazione: MRR@5 ≥ 0.79, risposta media ≤ 5 KB, nessuna regressione su alcuna query.

### Fase 2 — Re-ingestion con confini corretti

1. **CommandRef: suddivisione basata sui bookmark.** Usa `fitz.get_toc()` per i titoli delle voci e gli intervalli di pagine; il titolo del bookmark è quello autorevole. Verifica: numero di chunk = numero di bookmark (499).
2. **FunctionRef e Programming: struttura basata sui font**, letta direttamente dagli span di PyMuPDF:
   - titolo/intestazione = Montserrat-Bold alle dimensioni delle intestazioni, riga isolata;
   - codice = righe LMMono → blocco di codice recintato (mantiene la spaziatura corretta grazie a `pdfplumber` / x-tolerance);
   - voce di FunctionRef = riga di intestazione seguita dalla tabella `Function group`.
   In alternativa, procurati i PDF originali con i bookmark (i file attuali di FunctionRef e Programming sono stati salvati di nuovo e li hanno persi).
3. **Parser delle tabelle di metadati** che gestisce tutte e tre le varianti di intestazione (normalizza `<br>` in colonne separate prima dell'interpretazione).
4. **Percorso delle intestazioni** per ogni chunk (`Chapter › Section › Sub-section`) nei metadati e nel prefisso incorporato; sostituisce titoli ambigui come `Session Properties`.
5. **Numeri di pagina** (`page_start`, `page_end`) nei metadati per le citazioni.
6. **Passo di validazione** (`scripts/validate.py`, già citato nel concept ma mancante): conteggi per sorgente rispetto a bookmark/tabelle, nessun titolo di chunk che sembri codice, nessun `command_group` vuoto, nessun chunk sopra il limite di dimensione.

Criterio di accettazione: 499 comandi, ≥ 352 funzioni, 0 titoli con righe di codice, 0 chunk senza gruppo.

### Fase 3 — Vera ricerca fulltext

1. **tsvector pesato**: `setweight(title/symbol, 'A') || setweight(heading path, 'B') || setweight(content, 'D')`.
2. **Due configurazioni**: `english` per la prosa (stemming, stop word) e `simple` per i token di simboli; mantieni `$name`, `#NAME`, `name()` come token (normalizza prima di indicizzare e interrogare).
3. **Costruzione della query**: `websearch_to_tsquery` (supporta virgolette, OR, `-`) con rimozione delle stop word; mai un AND rigido su tutte le parole.
4. **Modalità** nel tool di ricerca:
   - `semantic` — solo vettoriale;
   - `fulltext` — solo lessicale, ordinato con `ts_rank_cd` con pesi, snippet tramite `ts_headline`;
   - `hybrid` (default) — RRF di entrambi, calcolato **globalmente**, non per corpus.
5. **Boost del titolo esatto**: se la query coincide con il titolo di un comando/funzione, quella voce è in posizione 1.
6. Opzionale: un indice trigram (`pg_trgm`) sui titoli per la ricerca di nomi tollerante agli errori di battitura.

Criterio di accettazione: le query con nome esatto (Q03 e simili) in posizione 1 in `fulltext` e `hybrid`; hybrid non peggiore di semantic sul set di test.

### Fase 4 — Copertura

1. Aggiungi il riferimento della notation e altri manuali (componenti esterni, client web/JavaScript) come corpus separati.
2. Rimuovi `omnis-code` dalle descrizioni dei tool finché non esiste.
3. Estendi `eval_queries.json` con almeno 10 query per ogni nuovo corpus.

### Fase 0 / manutenzione (può procedere in parallelo)

- ~~Rimuovere i file `.env` tracciati da git, ruotare la password del database~~ — non necessario: il database è
  locale, gira in Docker e non contiene dati riservati (decisione del proprietario).
- Mantieni un solo `ragserver.py`.
- Aggiorna `chunking_concept_en.md` dopo la fase 2.

---

## 6. Registro dei risultati

| Data | Modifica | Query | Modalità | Hit@5 | MRR@5 | Dimensione della risposta |
|---|---|---|---|---|---|---|
| 2026-09-28 | Baseline (v1) | 18 | misto per corpus | 14/18 | 0.62 | 52 KB HTTP, ~105 KB MCP |
| 2026-09-28 | Rework, prima esecuzione (`w_fts` 0.5) | 40 | hybrid | 37/40 | 0.86 | 1.9 KB |
| 2026-09-28 | + radici delle parole tedesche, sweep → `w_fts` 0.3, `rrf_k` 60 | 40 | hybrid | **39/40** | **0.92** | 1.9 KB |
| 2026-09-28 | idem | 40 | semantic | 37/40 | 0.86 | 1.9 KB |
| 2026-09-28 | idem | 40 | fulltext | 34/40 | 0.71 | 1.9 KB |
| 2026-09-28 | idem, solo le 18 query originali | 18 | hybrid | 17/18 | 0.82 | 1.9 KB |

Note sulla misurazione:

- Il set di query è cresciuto da 18 a 40 (notation, nomi esatti, tedesco, aggiunte di 11.1, panoramica). Per cinque
  delle query originali il pattern del risultato atteso è stato ampliato per accettare un id (ad es. `not_list_properties`),
  perché le risposte sulla notation sono gruppi di membri il cui titolo non nomina il membro.
- Sweep dei parametri (hybrid, 40 query): `rrf_k` ∈ {10, 20, 40, 60} × `w_fts` ∈ {0.3, 0.5, 0.7, 1.0} —
  ogni combinazione 39/40; MRR 0.87–0.92, `w_fts` 0.3 è il migliore per ogni `rrf_k`. `rrf_k` resta al
  valore standard 60 (0.919 contro il migliore 0.921) per evitare di ottimizzare su 40 domande.
- Mancato risultato residuo Q18 ("set the current line of a list"): la risposta (`$line`) è una riga all'interno del
  chunk dei membri "List properties" e viene superata dai comandi list. Gruppi di membri della notation più piccoli
  risolverebbero il problema, ma richiedono un nuovo embedding completo — candidato per il prossimo ciclo.
- Latenza (a caldo, container CPU): hybrid ~240 ms, semantic ~180 ms, fulltext ~80 ms.
- Dimensione della risposta via MCP: 1.5–3.5 KB per ricerca (v1: ~105 KB); `get_omnis_doc` restituisce il testo
  completo degli id scelti.

Dimensioni dopo il rework: 5,918 chunk (5.3 MB di testo), `output/embeddings.jsonl` 33 MB (float32 in base64,
versionato), database 123 MB (chunk 27 MB, embedding incluso l'indice HNSW 82 MB).

---

## 7. Implementazione (2026-09-28)

### Cosa è stato realizzato

| Voce del piano | Implementazione |
|---|---|
| Fase 1.1 risposta compatta | il rag-server produce testo semplice; i tool MCP non hanno output schema; niente JSON, niente duplicati |
| Fase 1.2 retrieval in due fasi | `search_omnis_docs` (snippet + id) e `get_omnis_doc` (`/chunks`) |
| Fase 1.3 ranking globale | `rag.search_ranked`: candidati dense e fulltext su tutti i corpus selezionati, RRF pesato |
| Fase 1.4 raggruppamento | un risultato per `doc_key` |
| Fase 1.5 warm-up | il modello codifica una volta all'avvio |
| Fase 2.1/2.2 confini | voci dal titolo in grassetto prima della tabella dei metadati, rese canoniche con i bookmark; intestazioni di Programming dai font; LMMono mai un'intestazione |
| Fase 2.3 metadati | letti dalle coordinate del PDF invece che dalle tabelle renderizzate |
| Fase 2.4/2.5 percorso delle intestazioni, pagine | in ogni chunk e nella riga di contesto incorporata |
| Fase 2.6 validazione | `scripts/validate.py` (controllo bloccante) |
| Fase 3 fulltext | `search_tsv` pesato (titolo A, intestazione B, contenuto C/D), query OR senza stop word, sintassi `websearch`, boost del nome esatto tramite `symbols`, modalità `hybrid` / `semantic` / `fulltext` |
| Fase 4 copertura | tutti i 17 capitoli di Programming; corpus notation e aggiunte di 11.1 dal doc pack |
| Manutenzione | un solo `ragserver.py`; `omnis-code` rimosso; documentazione aggiornata |

Ulteriori risultati emersi durante l'implementazione:

- **Perdita di legature nelle tabelle.** PyMuPDF espande "fi"/"fl" in due caratteri nella stessa posizione e
  la sua estrazione delle tabelle scarta il secondo (`specifed`, `frst`, `usequalifers`). Riparato con un
  vocabolario ricavato dal testo intatto della pagina — 1,158 riparazioni, 0 parole danneggiate rimaste.
- **Voci senza riga del titolo.** Quando il titolo è reso dentro una tabella, il taglio viene posto alla
  tabella dei metadati; la ricerca della voce successiva ora parte dopo la tabella della voce corrente
  (prima una voce poteva risultare vuota).
- **L'elenco dei comandi obsoleti** si trova in pagine di indice a più colonne che la conversione in Markdown scarta — letto
  dal testo semplice della pagina.
- **L'init di Docker eseguiva il bootstrap due volte.** L'entrypoint di postgres esegue ogni `*.sql` di primo livello in
  `docker-entrypoint-initdb.d`; `20-rag-bootstrap.sql` falliva la seconda volta (variabili della password assenti).
  I file SQL ora si trovano in `postgres-init/sql/`.
- **`mcp` 2.x rompe l'MCP server.** Il requisito senza versione fissa ha installato `mcp` 2.x (FastMCP rinominato) alla
  ricompilazione; fissato a `<2`.
- **Costo dell'embedding.** ~1.7 M token con bge-m3: minuti su GPU / Apple Silicon, ore su una semplice CPU.
  `embed_and_store.py` è incrementale (hash del testo), salva checkpoint e può usare il modello del rag-server.

### Dati dopo il rework

| | Prima | Dopo |
|---|---|---|
| Comandi | 434 (66 su 499 persi) | 499 dal PDF + 4 nuovi in 11.1 + 2 sezioni di codici di errore + 5 panoramiche |
| Funzioni | 327 | 357 dal PDF + 23 nuove in 11.1 |
| Programming | 1,543 chunk, capitoli 1 e 4 esclusi, 220 titoli con righe di codice | 1,883 chunk, capitoli 1–17, 0 titoli con righe di codice |
| Notation | — | 3,055 chunk (1,121 nodi) |
| Danni da legature | ~770 parole | 0 |
