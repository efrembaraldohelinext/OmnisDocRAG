# Omnis Studio RAG — Documentazione della pipeline

Documentazione tecnica del percorso dai PDF di Omnis (e, opzionalmente, dal doc pack di Omnis) al
database PostgreSQL e ai tool MCP.

---

## Panoramica

```text
Omnis PDF/*.pdf  (+ doc pack opzionale: l'help HTML convertito in Markdown)
    │  scripts/extract.py        struttura dal PDF, contenuto tramite pymupdf4llm
    ▼
output/extracted/*.json          unità: titolo, percorso delle intestazioni, pagine, Markdown, metadati
    │  scripts/chunk.py          chunk per corpus (+ notazione e aggiunte 11.1 dal doc pack)
    ▼
output/chunks/*_chunks.json
    │  scripts/validate.py       quality gate (exit code 1 in caso di errore)
    │  scripts/embed_and_store.py   BAAI/bge-m3, incrementale tramite hash del testo
    ▼
output/embeddings.jsonl          vettori come float32 in base64 (~5,6 KB per chunk), ignorato da git
    │  scripts/import_to_postgres.py / import_to_docker_postgres.py
    ▼
PostgreSQL ragdb (schema rag, v2)
    │  rag-server  (docker_mcp-rag/rag-server/ragserver.py)   /search /chunks /embed /health
    ▼
MCP: docker_mcp-rag/mcp-server/server.py (HTTP)  oppure  OmnisRAGServer/mcp-bridge/mcpserver.mjs (stdio)
```

| Corpus | Fonte |
|---|---|
| `omnis-commands` | CommandRef.pdf, aggiunte dal doc pack |
| `omnis-functions` | FunctionRef.pdf, aggiunte dal doc pack |
| `omnis-programming` | Programming_Omnis.pdf, tutti i capitoli |
| `omnis-notation` | doc pack (opzionale) |

I PDF e il doc pack non fanno parte di questo repository. Come fornirli:
[Building_from_Omnis_Docs_it.md](Building_from_Omnis_Docs_it.md).

Dettagli su estrazione e chunking: [chunking_concept_it.md](chunking_concept_it.md).

---

## Prerequisiti

```bash
python3 --version      # >= 3.10
python -m venv .venv && source .venv/bin/activate      # Windows: .venv\Scripts\activate
pip install -r scripts/requirements.txt
```

- Il modello `BAAI/bge-m3` (~2 GB) viene scaricato al primo uso locale in `~/.cache/huggingface/`.
- L'embedding di ~1,7 M di token richiede minuti su una GPU / Apple Silicon (MPS viene usato
  automaticamente) e ore su una semplice CPU (vedi [Piattaforme](#piattaforme-macos-windows-linux)).
  In alternativa, calcola gli embedding tramite il rag-server in esecuzione (`--server`), che usa il
  modello già presente nella cache del suo container.
- Doc pack opzionale: una directory con `catalogs/` e `md/` (creata dall'help HTML di Omnis 11.1).
  Passala con `--omnisdoc PATH` oppure imposta `OMNISDOC_PACK=PATH` in `scripts/.env.local`.

## Piattaforme (macOS, Windows, Linux)

`scripts/pipeline.py` è il punto di ingresso multipiattaforma (solo libreria standard). Usa i percorsi
corretti dell'ambiente virtuale per ogni sistema operativo ed esegue ogni passo con il `.venv` del progetto:

```bash
python scripts/pipeline.py doctor        # OS, Python, torch device, Node, Docker, rag-server, data state
python scripts/pipeline.py setup         # create .venv and install (add --rag-server for the local topology)
python scripts/pipeline.py build         # extract → chunk → validate → embed → import → eval
python scripts/pipeline.py build --from embed --to embed   # only the embeddings
```

`setup_project.sh` (macOS/Linux) e `setup_project.ps1` (Windows) chiamano `pipeline.py setup --rag-server`
e `pipeline.py doctor`.

Cosa si adatta alla macchina:

| Aspetto | Comportamento |
|---|---|
| Dispositivo di embedding | GPU NVIDIA (`cuda`) → GPU Apple Silicon (`mps`, con fallback su CPU per le operazioni mancanti) → CPU; sovrascrivibile con `--device` |
| Durata di un embedding completo | minuti su `cuda`/`mps`, ore su CPU (`doctor` indica quale caso vale) |
| Vettori | identici ovunque: stesso modello, stesso limite di token (512); entrambi sono salvati in ogni record, quindi un file creato su una macchina può essere continuato o importato su un'altra |
| Output della console | UTF-8 su ogni OS (le pipe di Windows non si interrompono più su `›`/`…`) |
| File generati | scritti con LF; `.gitattributes` mantiene `output/`, `*.sh`, `*.sql`, `*.yml` in LF |
| Immagine Docker | build CPU di PyTorch — i container non hanno GPU (Docker Desktop su macOS non ne ha) e la build CUDA aggiungerebbe diversi GB su amd64; le immagini `pgvector` e Python sono multi-arch (arm64 su Apple Silicon) |

**Embedding su una macchina, servizio su un'altra.** `output/` è ignorato da git perché deriva dalla
documentazione di Omnis. `output/embeddings.jsonl` salva i vettori come byte float32 esatti in base64.
Crea gli embedding dove è veloce (`pipeline.py build --from embed --to embed` su un Mac con Apple
Silicon), copia `output/` sulla macchina con il database (`rsync -a output/ server:Euromnis-OmnisDocRAG-example/output/`)
ed esegui lì `pipeline.py build --from import`.

### Runbook: nuovi embedding su un Mac, deployment su un server Docker

**1. Prepara il Mac (una sola volta)**

```bash
git clone <your repository URL> && cd Euromnis-OmnisDocRAG-example   # or: git pull
python3 scripts/pipeline.py setup
python3 scripts/pipeline.py doctor        # "embedding device: mps" — otherwise it runs on the CPU (hours)
```

Solo se ricostruisci i chunk sul Mac (passo 2b): il doc pack di Omnis deve trovarsi sul Mac e
`scripts/.env.local` deve puntare ad esso (`OMNISDOC_PACK=/path/to/omnisdoc`, vedi `scripts/.env.local.example`).
Senza doc pack `chunk.py` si ferma, invece di scartare in silenzio il corpus notation e le aggiunte 11.1.

**2a. Solo nuovo embedding** (chunk invariati, ad esempio dopo un cambio di modello o del limite di token):

```bash
python3 scripts/pipeline.py build --from embed --to embed     # --force in embed_and_store.py re-embeds everything
```

**2b. Ricostruzione di chunk ed embedding** (dopo modifiche a `extract.py` / `chunk.py`):

```bash
python3 scripts/pipeline.py build --from extract --to embed   # extract → chunk → validate → embed
```

`validate.py` interrompe la build in caso di voci mancanti o testo danneggiato; `embed_and_store.py`
calcola l'embedding solo dei chunk il cui testo è cambiato.

**3. Verifica e trasferimento**

```bash
python3 scripts/pipeline.py doctor        # "missing/stale: 0"
rsync -a output/ <server>:Euromnis-OmnisDocRAG-example/output/        # output/ is not in git
```

**4. Deploy sul server** (vedi [docker_mcp-rag-pg/README_it.md](../docker_mcp-rag-pg/README_it.md#deployment-su-un-server-docker-interno)):

```bash
git pull
cd docker_mcp-rag-pg
docker compose up -d --build                        # only rebuilds what changed
docker compose --profile import run --rm importer   # loads output/ into the database (~30 s)
```

**5. Misura** (da qualsiasi macchina che raggiunge il rag-server, ad esempio sul server stesso o tramite
un tunnel SSH verso la porta 7071):

```bash
python3 scripts/eval_retrieval.py --compare --url http://localhost:7071/search
```

Confronta con il registro dei risultati in [retrieval_quality_analysis_it.md](retrieval_quality_analysis_it.md#6-registro-dei-risultati).

---

## Struttura del progetto

```text
Euromnis-OmnisDocRAG-example/
├── Omnis PDF/                     CommandRef.pdf, FunctionRef.pdf, Programming_Omnis.pdf
├── scripts/
│   ├── extract.py                 passo 1: PDF → unità (JSON) + Markdown di ispezione
│   ├── chunk.py                   passo 2: unità (+ doc pack) → chunk
│   ├── validate.py                passo 3: quality gate
│   ├── embed_and_store.py         passo 4: chunk → embeddings.jsonl
│   ├── import_to_postgres.py      passo 5: chunk + embedding → PostgreSQL
│   ├── import_to_docker_postgres.py  passo 5 sul PostgreSQL di Docker
│   ├── pipeline.py                runner multipiattaforma: doctor, setup, build
│   ├── eval_retrieval.py          controllo di regressione del retrieval (eval_queries.json)
│   ├── test_mcp_rag_bridge.py     test end-to-end del bridge stdio
│   ├── setup_db.sql / setup_ranking.sql   PostgreSQL locale (includono l'SQL condiviso)
├── output/
│   ├── extracted/*.json           passo 1
│   ├── *_extracted.md             passo 1, per la lettura
│   ├── chunks/*_chunks.json       passo 2
│   ├── validation_report.json     passo 3
│   └── embeddings.jsonl           passo 4 (in git, ~33 MB)
├── docker_mcp-rag/                immagini rag-server + mcp-server (PostgreSQL sull'host)
├── docker_mcp-rag-pg/             stack completo: PostgreSQL 18 + pgvector + entrambi i server
│   └── postgres-init/
│       ├── 10-init-ragdb.sh       esegue una volta l'SQL seguente su un volume vuoto
│       └── sql/                   20 roles, 30 schema, 40 ranking — condivisi con il setup locale
└── OmnisRAGServer/
    ├── rag-server/ragserver.py    wrapper di avvio locale di docker_mcp-rag/rag-server/ragserver.py
    └── mcp-bridge/mcpserver.mjs   bridge MCP stdio
```

---

## Passo 1 — Estrazione (`extract.py`)

```bash
python scripts/extract.py                      # all sources
python scripts/extract.py CommandRef           # one source
```

Stampa per ogni fonte il numero di unità e gli avvisi (ad esempio "title line synthesised" quando un
titolo era renderizzato dentro una tabella). L'output si trova in `output/extracted/` e `output/*_extracted.md`.

## Passo 2 — Chunking (`chunk.py`)

```bash
python scripts/chunk.py --omnisdoc /path/to/omnisdoc     # or OMNISDOC_PACK in scripts/.env.local
python scripts/chunk.py                                  # without doc pack: no notation, no 11.1 additions
```

## Passo 3 — Validazione (`validate.py`)

```bash
python scripts/validate.py --omnisdoc /path/to/omnisdoc
```

Interrompe la build (exit code 1) quando mancano voci, righe di codice sono diventate titoli, restano
danni da legature o i chunk sono vuoti o troppo grandi. Stampa il controllo incrociato con il doc pack.

## Passo 4 — Embedding (`embed_and_store.py`)

```bash
python scripts/embed_and_store.py                               # local model (MPS/CUDA/CPU)
python scripts/embed_and_store.py --threads 12                  # CPU: use all cores
python scripts/embed_and_store.py --server http://localhost:7071   # via the running rag-server
python scripts/embed_and_store.py --force                       # re-embed everything
```

- Calcola l'embedding di `embed_text` (riga di contesto + testo del chunk), normalizzato, 1024 dimensioni.
- Incrementale: solo i chunk il cui hash del testo è cambiato vengono ricalcolati; l'avanzamento viene
  salvato ogni 10 batch, quindi un'esecuzione interrotta riprende da dove si era fermata.
- `--max-seq-length` (predefinito 512 token) limita la lunghezza di embedding dei chunk più lunghi.

## Passo 5 — Importazione

```bash
python scripts/import_to_postgres.py            # RAG_DB_* from scripts/.env
python scripts/import_to_docker_postgres.py     # reads docker_mcp-rag-pg/.env
```

- Si rifiuta di partire se manca un embedding o è obsoleto (controllo dell'hash).
- Una sola transazione: upsert di documenti, chunk (titolo, percorso delle intestazioni, simboli,
  contenuto) ed embedding; il vettore full-text viene costruito da un trigger; i documenti che non
  esistono più vengono eliminati (`DELETE_STALE_DOCS=0` lo disattiva).

---

## Database

Schema e ranking si trovano in `docker_mcp-rag-pg/postgres-init/sql/` e sono usati da entrambi i setup:

- Docker: `10-init-ragdb.sh` esegue `sql/20…`, `sql/30…`, `sql/40…` una volta su un volume vuoto.
- Locale: `scripts/setup_db.sql` (roles, poi lo schema tramite `\ir`) e `scripts/setup_ranking.sql`.

Entrambi i file SQL sono idempotenti; `30-rag-schema.sql` migra un database v1. Vedi
[postgres_it.md](postgres_it.md).

---

## Runtime

### rag-server

| Endpoint | Scopo |
|---|---|
| `GET /health` | modello e numero di chunk per corpus |
| `POST /search` | `{query, mode: hybrid\|semantic\|fulltext, top_k, corpora, format: text\|json}` |
| `POST /chunks` | `{ids: [...], format}` — testo completo dei risultati |
| `POST /embed` | `{texts: [...]}` — embedding con il modello del server |

Messa a punto tramite variabili d'ambiente: `RAG_W_DENSE` (1.0), `RAG_W_FTS` (0.3), `RAG_RRF_K` (60), `RAG_SNIPPET_CHARS` (240). `/search` accetta `w_dense`, `w_fts` e `rrf_k` per ogni richiesta, per i parameter sweep.

### Tool MCP (identici nel server Docker e nel bridge stdio)

| Tool | Uso |
|---|---|
| `search_omnis_docs` | ricerca ordinata su tutti i corpus; `mode`, `top_k`, `corpus` |
| `get_omnis_doc` | testo completo degli id dei risultati |
| `search_omnis_syntax` | ricerca limitata a comandi, funzioni, notazione |
| `search_omnis_concepts` | ricerca limitata al manuale Programming (`deep` = 15 risultati) |

La risposta di una ricerca è testo semplice: una riga per risultato con corpus, titolo o percorso delle
intestazioni, fonte con pagine, id e uno snippet — in genere 2–4 KB.

---

## Ricostruzione completa

```bash
python scripts/pipeline.py build                  # all steps, import into the Docker stack
python scripts/pipeline.py build --target local   # import into the database from scripts/.env
```

Passi singoli equivalenti (dentro il `.venv` attivato):

```bash
python scripts/extract.py
python scripts/chunk.py --omnisdoc /path/to/omnisdoc
python scripts/validate.py --omnisdoc /path/to/omnisdoc
python scripts/embed_and_store.py            # or --server http://localhost:7071
python scripts/import_to_docker_postgres.py  # or import_to_postgres.py
python scripts/eval_retrieval.py --compare
```

Per modificare lo schema su un volume Docker esistente, ricrea il volume PostgreSQL
(`docker compose rm -sf postgres && docker volume rm docker_mcp-rag-pg_postgres_data && docker compose up -d`,
il volume della cache del modello resta) oppure esegui `sql/30…` e `sql/40…` sul database come `postgres`.
