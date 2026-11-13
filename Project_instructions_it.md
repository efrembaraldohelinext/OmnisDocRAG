# Euromnis-OmnisDocRAG-example — Istruzioni di progetto

Questo repository è un esempio di come costruire un RAG server dalla documentazione di Omnis. Non contiene
la documentazione di Omnis: la fornisci tu (vedi Documentation/Building_from_Omnis_Docs_en.md). Gli
script possono richiedere adattamenti ai tuoi documenti, quindi fai verificare il risultato, preferibilmente da un agente AI
(Documentation/AI_Review_Guide_en.md).

Questo documento è il breve punto di ingresso per gli sviluppatori. Spiega la struttura effettiva del runtime, l'ordine corretto di avvio e dove trovare la documentazione dettagliata.

---

## Obiettivo

`Euromnis-OmnisDocRAG-example` fornisce uno stack RAG locale per la documentazione di Omnis Studio:

- estrai i manuali PDF di Omnis (struttura da segnalibri, font e posizioni delle tabelle)
- aggiungi, se vuoi, il riferimento alla notazione e le novità della versione 11.1 dal doc pack di Omnis
- suddividi tutto in chunk strutturati e convalidali
- crea gli embedding dei chunk in locale
- importali in PostgreSQL con `pgvector`
- avvia un `rag-server` HTTP locale per il retrieval OPPURE
- compila ed esegui il container `docker_mcp-rag` con PostgreSQL sull'host OPPURE
- compila ed esegui lo stack completo `docker_mcp-rag-pg` con PostgreSQL 18 dentro Docker
- esponi i tool MCP a VS Code tramite il `mcp-bridge` basato su stdio OPPURE una delle varianti Docker basate su HTTP

Il progetto si basa su quattro corpora:

- `omnis-commands` da `CommandRef.pdf` (più i comandi nuovi nella guida di Omnis 11.1)
- `omnis-functions` da `FunctionRef.pdf` (più le funzioni nuove nella guida di Omnis 11.1)
- `omnis-programming` da `Programming_Omnis.pdf`, tutti i capitoli
- `omnis-notation` dal doc pack di Omnis (opzionale; Markdown creato dalla guida di Omnis 11.1)

---

## Struttura effettiva del progetto

```text
Euromnis-OmnisDocRAG-example/
├── README.md                   Root overview and document index
├── Documentation/              Concepts, architecture, pipeline docs
├── Omnis PDF/                  Your Omnis PDF manuals (not in the repo, see its README)
├── output/                     Generated: extracted units, chunks, validation report, embeddings
│   ├── extracted/              Step 1 — units per PDF (JSON)
│   ├── chunks/                 Step 2 — chunks per corpus (JSON)
│   └── embeddings.jsonl        Step 4 — vectors (base64 float32); output/ is git-ignored
├── scripts/                    extract, chunk, validate, embed, import, eval, bridge test, local SQL setup
├── docker_mcp-rag-pg/          Full containerised stack with PostgreSQL 18 + pgvector
│   ├── docker-compose.yml      Orchestrates postgres + rag-server + mcp-server
│   ├── postgres-init/          10-init-ragdb.sh + sql/ (roles, schema, ranking — shared with the local setup)
│   ├── .env                    Runtime configuration (copy from .env.example)
│   ├── .env.example            Configuration template
│   └── README.md               Full-stack Docker documentation
├── docker_mcp-rag/             Containerised rag-server + mcp-server (PostgreSQL on the host)
│   ├── mcp-server/
│   │   ├── server.py           MCP server — Python FastMCP, Streamable HTTP, port 3000
│   │   ├── requirements.txt
│   │   └── Dockerfile
│   ├── rag-server/
│   │   ├── ragserver.py        FastAPI retrieval server — the only copy of the server code
│   │   ├── requirements.txt
│   │   └── Dockerfile
│   ├── docker-compose.yml      Orchestrates both services
│   ├── .env                    Runtime configuration (copy from .env.example)
│   ├── .env.example            Configuration template
│   └── README.md               Full Docker documentation
└── OmnisRAGServer/
    ├── README.md               Bridge/server contract
    ├── rag-server/
    │   ├── ragserver.py        Local start wrapper for docker_mcp-rag/rag-server/ragserver.py
    │   ├── requirements.txt    RAG server dependencies
    │   ├── .env                Runtime configuration
    │   └── .env.example        Template
    └── mcp-bridge/
        └── mcpserver.mjs       stdio MCP bridge for VS Code
```

---

## Da leggere per primi

- [Documentation/Building_from_Omnis_Docs_it.md](Documentation/Building_from_Omnis_Docs_it.md) (come fornire la documentazione di Omnis, problemi di estrazione, checklist)
- [Documentation/AI_Review_Guide_it.md](Documentation/AI_Review_Guide_it.md) (per un agente AI: convalida la build, adatta gli script)
- [Documentation/Pipeline_it.md](Documentation/Pipeline_it.md)
- [Documentation/chunking_concept_it.md](Documentation/chunking_concept_it.md)
- [Documentation/retrieval_quality_analysis_it.md](Documentation/retrieval_quality_analysis_it.md)
- [Documentation/RAG_concept_it.md](Documentation/RAG_concept_it.md) (concetto originale, background)
- [Documentation/embedding_concept_it.md](Documentation/embedding_concept_it.md)
- [Documentation/postgres_it.md](Documentation/postgres_it.md)
- [Documentation/expected_outcome_it.md](Documentation/expected_outcome_it.md)
- [OmnisRAGServer/README_it.md](OmnisRAGServer/README_it.md)
- [docker_mcp-rag-pg/README_it.md](docker_mcp-rag-pg/README_it.md)
- [docker_mcp-rag/README_it.md](docker_mcp-rag/README_it.md)

---

## Setup

### Setup più rapido

Per far funzionare il progetto su una macchina nuova con il minor numero di prerequisiti esterni,
usa lo stack Docker completo in `docker_mcp-rag-pg/`.

```bash
cd docker_mcp-rag-pg
cp .env.example .env
docker compose up --build -d
```

Poi crea i dati (vedi [Flusso standard di build dei dati](#flusso-standard-di-build-dei-dati)) e importali
dalla root del repository:

```bash
python scripts/import_to_docker_postgres.py
```

`output/` non è nel repository (deriva dalla documentazione di Omnis). Crealo una volta, oppure copialo
dalla macchina che lo ha creato. Ricostruisci gli embedding solo dopo una modifica dei chunk (`scripts/embed_and_store.py` crea l'embedding solo dei chunk modificati;
pochi minuti su una GPU / Apple Silicon, ore su una semplice CPU).

### Helper di bootstrap locale

Dalla root del progetto:

```bash
bash setup_project.sh            # macOS / Linux
.\setup_project.ps1              # Windows PowerShell
```

Entrambi richiamano il runner multipiattaforma `scripts/pipeline.py` (solo libreria standard):

- `pipeline.py setup --rag-server` crea `.venv` e `OmnisRAGServer/rag-server/.venv` con i
  percorsi giusti per il sistema operativo, installa le dipendenze e crea `OmnisRAGServer/rag-server/.env`
  da `.env.example` se manca
- `pipeline.py doctor` mostra sistema operativo, Python, il dispositivo per gli embedding (CUDA / Apple Silicon / CPU), Node.js,
  Docker, il rag-server e lo stato di chunk ed embedding, con una raccomandazione

Non installa dipendenze di sistema come PostgreSQL, Docker o Node.js.
Dettagli sulle piattaforme: [Documentation/Pipeline_it.md](Documentation/Pipeline_it.md#piattaforme-macos-windows-linux).

### 1. Ambiente virtuale della pipeline

Dalla root del progetto:

```bash
cd Euromnis-OmnisDocRAG-example
python3 -m venv .venv
source .venv/bin/activate
python -m pip install --upgrade pip
pip install -r scripts/requirements.txt
```

Questo installa le dipendenze per:

- `scripts/extract.py`
- `scripts/chunk.py`
- `scripts/validate.py`
- `scripts/embed_and_store.py`
- `scripts/import_to_postgres.py`
- `scripts/import_to_docker_postgres.py`
- `scripts/eval_retrieval.py`

Le impostazioni locali che non devono essere committate (ad es. il percorso del doc pack) vanno in `scripts/.env.local`
(ignorato da git):

```env
OMNISDOC_PACK=/path/to/omnisdoc
```

### 2. Ambiente del RAG server

Il server di retrieval ha una propria cartella di runtime:

```bash
cd OmnisRAGServer/rag-server
python3 -m venv .venv
source .venv/bin/activate
python -m pip install --upgrade pip
pip install -r requirements.txt
```

La configurazione si trova in:

```text
OmnisRAGServer/rag-server/.env
```

### 3. Runtime Node per il MCP bridge

Usa una versione LTS recente di Node.js. Node 20 è una scelta sicura.

```bash
node --version
```

`OmnisRAGServer/mcp-bridge/mcpserver.mjs` usa attualmente solo le API integrate di Node, quindi non serve un passaggio `npm install` separato.

### 4. Runtime PostgreSQL

Serve PostgreSQL con `pgvector` prima di importare gli embedding.

Ora sono supportati due percorsi per il database:

- PostgreSQL locale o esterno, gestito fuori da Docker
- PostgreSQL 18 dentro `docker_mcp-rag-pg/` con bootstrap automatico

Usa (includono l'SQL condiviso di `docker_mcp-rag-pg/postgres-init/sql/`):

- `scripts/setup_db.sql` — ruoli, poi schema (eseguilo di nuovo con `-d ragdb`)
- `scripts/setup_ranking.sql` — `rag.search_ranked`

La configurazione manuale dello schema serve solo per il percorso con PostgreSQL locale/esterno.
Lo stack Docker completo inizializza il database automaticamente al primo avvio.

Dettagli sullo schema: [Documentation/postgres_it.md](Documentation/postgres_it.md)

---

## Flusso standard di build dei dati

Tutti i passaggi in un colpo solo (su qualsiasi sistema operativo): `python scripts/pipeline.py build` — oppure passo per passo dalla root del
progetto, dopo aver attivato l'ambiente virtuale della pipeline:

```bash
python scripts/extract.py
python scripts/chunk.py --omnisdoc /path/to/omnisdoc    # doc pack opzionale (oppure OMNISDOC_PACK in scripts/.env.local)
python scripts/validate.py
python scripts/embed_and_store.py                        # oppure --server http://localhost:7071
```

Che cosa fa ogni passaggio:

1. `extract.py` legge la struttura del PDF (segnalibri, font, tabelle di metadati) e scrive le unità in
   `output/extracted/` più Markdown leggibile in `output/*_extracted.md`.
2. `chunk.py` crea i file di chunk in `output/chunks/` (con il doc pack anche il corpus notation
   e le voci nuove della versione 11.1).
3. `validate.py` è il controllo di qualità: fallisce se mancano voci, se righe di codice sono diventate titoli,
   se restano danni da legature o se i chunk sono vuoti o troppo grandi.
4. `embed_and_store.py` aggiorna `output/embeddings.jsonl`. È incrementale: solo i
   chunk modificati ricevono un nuovo embedding; `--force` rifà l'embedding di tutto.
5. Importa nel PostgreSQL di destinazione:
   - PostgreSQL locale/esterno: `python scripts/import_to_postgres.py`
   - PostgreSQL Docker in `docker_mcp-rag-pg/`: `python scripts/import_to_docker_postgres.py`
6. Controlla la qualità del retrieval: `python scripts/eval_retrieval.py --compare`

Dettagli: [Documentation/Pipeline_it.md](Documentation/Pipeline_it.md),
[Documentation/chunking_concept_it.md](Documentation/chunking_concept_it.md).

### Modalità di importazione (full-sync o upsert-only)

`scripts/import_to_postgres.py` supporta due modalità, controllate da `DELETE_STALE_DOCS`:

- Full-sync (predefinita): `DELETE_STALE_DOCS=1`
  - Esegue l'upsert di chunk ed embedding correnti.
  - Elimina i documenti dei corpora importati che non sono più in `output/chunks/`.
- Upsert-only: `DELETE_STALE_DOCS=0`
  - Esegue l'upsert di chunk ed embedding correnti.
  - Mantiene le righe più vecchie che non sono nei file di chunk correnti.

L'importer si rifiuta di partire se manca un embedding o se un embedding appartiene a un testo di chunk più vecchio.

Esempi:

```bash
# full-sync (predefinito)
python scripts/import_to_postgres.py

# full-sync esplicito
DELETE_STALE_DOCS=1 python scripts/import_to_postgres.py

# upsert-only
DELETE_STALE_DOCS=0 python scripts/import_to_postgres.py
```

Equivalenti PowerShell:

```powershell
# full-sync esplicito
$env:DELETE_STALE_DOCS = "1"; python scripts/import_to_postgres.py

# upsert-only
$env:DELETE_STALE_DOCS = "0"; python scripts/import_to_postgres.py

# pulizia opzionale
Remove-Item Env:DELETE_STALE_DOCS
```

`scripts/import_to_docker_postgres.py` delega allo stesso importer e quindi
eredita lo stesso comportamento full-sync o upsert-only.

---

## Ordine di avvio del runtime

Questa parte è importante:

1. PostgreSQL deve già contenere gli embedding importati.
2. Il `rag-server` deve essere in esecuzione prima di inviare richieste MCP.
3. Il livello MCP dipende dalla variante di runtime attiva:
   - locale: il `mcp-bridge` inoltra le richieste al `rag-server` locale
   - Docker: il `mcp-server` inoltra le richieste al `rag-server` nel container

### Avvia il RAG server

```bash
cd OmnisRAGServer/rag-server
source .venv/bin/activate
python ragserver.py
```

Endpoint predefinito:

```text
http://127.0.0.1:7071
```

### Avvia il MCP bridge

Se serve, indirizzalo al RAG server in esecuzione:

```bash
export OMNIS_RAG_SERVER_URL=http://127.0.0.1:7071
```

Poi avvia il bridge:

```bash
cd OmnisRAGServer/mcp-bridge
node mcpserver.mjs
```

Il MCP bridge dipende dal RAG server. Se il `rag-server` non è in esecuzione, le richieste MCP falliscono.

---

## Varianti Docker

Sono disponibili due percorsi Docker:

- `docker_mcp-rag/`: esegue `rag-server` + `mcp-server`, ma si connette ancora a PostgreSQL sull'host
- `docker_mcp-rag-pg/`: esegue `postgres` + `rag-server` + `mcp-server` come un unico stack pronto all'uso

Nessuna delle due varianti Docker richiede un ambiente Python locale o il bridge Node.js a runtime.

### Variante A — Docker con PostgreSQL sull'host

### Architettura

```text
VS Code (HTTP MCP client)
    │  HTTP POST http://localhost:3000/mcp
    ▼
mcp-server  (Python FastMCP, Streamable HTTP, port 3000)
    │  HTTP http://rag-server:7071  (internal Docker network)
    ▼
rag-server  (FastAPI, port 7071)
    │  TCP
    ▼
PostgreSQL on host  (host.docker.internal)
```

### Prerequisiti

- Docker Desktop (Windows/macOS) oppure Docker Engine + plugin Compose (Linux)
- PostgreSQL già popolato con gli script della pipeline (vedi [Flusso standard di build dei dati](#flusso-standard-di-build-dei-dati))
- PostgreSQL configurato per accettare connessioni dalla subnet Docker (vedi `docker_mcp-rag/README.md`)

### Prima configurazione

```bash
cd docker_mcp-rag
copy .env.example .env     # Windows
# cp .env.example .env     # macOS/Linux
```

Modifica `.env` e imposta almeno:

```env
RAG_DB_USER=rag_app
RAG_DB_PASS=your_password
RAG_DB_NAME=ragdb
```

### Build e avvio

```bash
cd docker_mcp-rag
docker compose up --build
```

Il primo avvio scarica il modello `BAAI/bge-m3` (~2,2 GB) nel volume con nome `hf_cache`.
Gli avvii successivi riusano il modello in cache e sono molto più veloci.

```bash
# Avvia in background
docker compose up -d

# Segui i log solo del MCP server
docker compose logs -f mcp-server

# Ferma tutto
docker compose down
```

### Health check

Il container `rag-server` espone un endpoint `/health`:

```bash
curl http://localhost:7071/health
```

Il `mcp-server` parte solo dopo che il `rag-server` ha superato il suo health check (`depends_on: service_healthy`).

### Configurazione MCP di VS Code

**Variante locale stdio** (richiede il RAG server locale + il bridge Node.js):

```json
{
  "omnis-rag-local": {
    "type": "stdio",
    "command": "node",
    "args": [
      "${workspaceFolder}/OmnisRAGServer/mcp-bridge/mcpserver.mjs"
    ],
    "env": {
      "OMNIS_RAG_SERVER_URL": "http://127.0.0.1:7071"
    }
  }
}
```

**Variante Docker HTTP** (richiede `docker compose up` in `docker_mcp-rag/`):

```json
{
  "omnis-rag-docker": {
    "type": "http",
    "url": "http://localhost:3000/mcp"
  }
}
```

Entrambe le voci possono coesistere in `.vscode/mcp.json`. Usa l'una o l'altra a seconda della variante in esecuzione.

### Variante B — Stack Docker completo con PostgreSQL 18

La cartella `docker_mcp-rag-pg/` contiene lo stack completo:

```text
VS Code (HTTP MCP client)
    │  HTTP POST http://localhost:3000/mcp
    ▼
mcp-server  (Python FastMCP, Streamable HTTP, port 3000)
    │  HTTP http://rag-server:7071
    ▼
rag-server  (FastAPI, port 7071)
    │  TCP
    ▼
postgres  (Docker, PostgreSQL 18 + pgvector)
```

Questa è la configurazione consigliata per macchine nuove e ambienti condivisi, perché:

- non serve installare PostgreSQL in locale
- lo schema del database e i ruoli sono creati automaticamente al primo avvio
- la porta host di PostgreSQL è configurabile in `docker_mcp-rag-pg/.env`
- le importazioni possono puntare al database del container con `python scripts/import_to_docker_postgres.py`

Avvio rapido:

```bash
cd docker_mcp-rag-pg
cp .env.example .env
docker compose up --build -d
cd ..
python scripts/import_to_docker_postgres.py
```

Tutti i dettagli, incluso il deploy su un server Docker interno (importazione dentro Docker, bind host,
aggiornamenti): [docker_mcp-rag-pg/README_it.md](docker_mcp-rag-pg/README_it.md#deployment-su-un-server-docker-interno).
Ricostruzione degli embedding su un Mac e relativo rollout:
[Documentation/Pipeline_it.md](Documentation/Pipeline_it.md#runbook-nuovi-embedding-su-un-mac-deployment-su-un-server-docker).

---

## Note importanti

- La documentazione in `Documentation/` è scritta in inglese (file `_en`).
- Tratta `output/` come artefatti generati. Sono ignorati da git perché derivano dalla documentazione di
  Omnis: copiali tra le macchine invece di committarli.
- `embed_and_store.py` usa `sentence-transformers` in locale con `BAAI/bge-m3` (download di ~2,2 GB; MPS/CUDA
  usati automaticamente) oppure, con `--server`, il modello del rag-server in esecuzione.
- `scripts/import_to_postgres.py` legge i valori di ambiente del database da `scripts/.env`.
- `scripts/import_to_docker_postgres.py` legge le impostazioni del database Docker da `docker_mcp-rag-pg/.env`.
- Sono disponibili tre topologie di runtime:
  - **Locale:** `rag-server (Python) → mcp-bridge (Node.js) → VS Code (stdio)`
  - **Docker con PostgreSQL sull'host:** `PostgreSQL (host) → rag-server (container) → mcp-server (container) → VS Code (HTTP)`
  - **Stack Docker completo:** `postgres (container) → rag-server (container) → mcp-server (container) → VS Code (HTTP)`
- `docker_mcp-rag/rag-server/ragserver.py` è l'unica copia del codice del server; `OmnisRAGServer/rag-server/ragserver.py`
  lo avvia per la topologia locale.
- `docker_mcp-rag-pg/` riusa quelle cartelle di servizio Docker, ma aggiunge PostgreSQL 18 + `pgvector` e il bootstrap del database.
- Il MCP server Docker usa Python FastMCP con Streamable HTTP, non il bridge stdio Node.js. `mcp` è bloccato
  sotto la versione 2.0 (la 2.x ha rinominato FastMCP). Entrambi i front-end MCP offrono gli stessi quattro tool.
- La cache del modello HuggingFace è salvata nel volume Docker con nome `hf_cache` per evitare download ripetuti.

---

## Programmazione agentica — Configurazione MCP per VS Code

Questa sezione è per gli sviluppatori che usano un coding agent (GitHub Copilot, Claude Code o qualsiasi assistente compatibile con MCP) in questo workspace.

### Configurazione MCP di VS Code (`.vscode/mcp.json`)

Crea `.vscode/mcp.json` nella root del workspace (una o entrambe le voci, a seconda della variante in esecuzione):

```json
{
  "servers": {
    "omnis-rag-docker": {
      "type": "http",
      "url": "http://localhost:3000/mcp"
    },
    "omnis-rag-local": {
      "type": "stdio",
      "command": "node",
      "args": [
        "${workspaceFolder}/OmnisRAGServer/mcp-bridge/mcpserver.mjs"
      ],
      "env": {
        "OMNIS_RAG_SERVER_URL": "http://127.0.0.1:7071"
      }
    }
  }
}
```

- Usa `omnis-rag-docker` quando `docker compose up` è in esecuzione in `docker_mcp-rag/`.
- Usa `omnis-rag-local` quando il RAG server e il MCP bridge sono avviati manualmente (vedi [Ordine di avvio del runtime](#ordine-di-avvio-del-runtime)).
- Dopo aver modificato `mcp.json`, esegui **MCP: Restart Server** in VS Code per applicare le modifiche.

### Istruzioni per il coding agent (`CLAUDE.md` / `.github/copilot-instructions.md`)

Per far usare automaticamente questi tool MCP al coding agent, aggiungi il blocco seguente al file di istruzioni dell'agente.
Per Claude Code è `CLAUDE.md` nella root del workspace; per GitHub Copilot è `.github/copilot-instructions.md`.

---

#### Impostazioni predefinite per l'uso di MCP (a livello di progetto)

Per i task Omnis in questo repository, preferisci la conoscenza e le funzioni MCP quando disponibili:

1. **Prima le domande su sintassi e comportamento:** se il comportamento del linguaggio Omnis o la semantica di una funzione non sono chiari, consulta la documentazione Omnis fornita da MCP prima di implementare.
2. **Prima il retrieval delle classi:** per classi locali mancanti o obsolete, usa il workflow MCP di retrieval delle classi (`getClass`) invece di ricreare a mano le strutture.
3. **Priorità della fonte di verità:** se l'export locale e il payload MCP differiscono, considera autorevole il payload MCP per la ricostruzione, poi ricontrolla i punti di integrazione locali.
4. **Tracciabilità:** quando usi dati MCP per decisioni di implementazione, indica brevemente nel riepilogo di consegna quale classe o payload hai usato.

#### Omnis RAG tramite MCP-Bridge (per il coding agent)

Quando lavora in questo workspace, il coding agent deve usare il server MCP bridge `omnis-rag-docker` o `omnis-rag-local` per basarsi sulla documentazione di Omnis.

1. **Tool:** `search_omnis_docs` (predefinito), `get_omnis_doc`; varianti ristrette `search_omnis_syntax`
   (comandi, funzioni, notazione) e `search_omnis_concepts` (manuale Programming).
2. **Quando chiamare il RAG:** quando la sintassi o la semantica di Omnis non sono chiare (prima l'incertezza), non a ogni passo di codifica.
3. **Due passi:** prima cerca — la risposta elenca i risultati con titolo, fonte, id e uno snippet (pochi KB).
   Poi recupera solo gli id rilevanti con `get_omnis_doc` e basa il codice su quel testo completo.
4. **Modalità di `search_omnis_docs`:**
   - `hybrid` (predefinita) — significato e parole combinati; adatta alla maggior parte delle domande, in inglese o tedesco.
   - `semantic` — solo significato; per domande formulate in modo vago.
   - `fulltext` — solo parole; per termini esatti, testi di errore, `"exact phrases"`, `OR`, `-exclusion`.
5. **Nomi esatti** (`mid()`, `$search`, `#ERRCODE`, `Begin reversible block`) si possono cercare direttamente;
   la voce corrispondente è classificata per prima.
6. **Le voci deprecate** sono contrassegnate con `[deprecated]` nell'elenco dei risultati: spiegale, non proporle.
7. **Argomenti ampi:** più ricerche mirate valgono più di una ricerca generica (ad es. `$sendall` → `$sendallref`).
8. **Fallback:** se il server non è disponibile, dillo e continua al meglio dai pattern locali del progetto.
9. **Runtime:** `omnis-rag-docker` su `http://localhost:3000/mcp`; `omnis-rag-local` richiede il rag-server su
   `http://127.0.0.1:7071` (bridge avviato da VS Code).

---

## Avvio rapido

### Variante locale

```bash
# 1. Pipeline — esegui una volta per creare i dati
cd Euromnis-OmnisDocRAG-example
python3 -m venv .venv
source .venv/bin/activate          # Windows: .venv\Scripts\Activate.ps1
pip install -r scripts/requirements.txt
python scripts/extract.py
python scripts/chunk.py --omnisdoc /path/to/omnisdoc   # doc pack opzionale
python scripts/validate.py
python scripts/embed_and_store.py
python scripts/import_to_postgres.py

# 2. RAG server — terminale 1
cd OmnisRAGServer/rag-server
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
python ragserver.py

# 3. MCP bridge — terminale 2
cd OmnisRAGServer/mcp-bridge
node mcpserver.mjs
```

### Variante Docker

```bash
# 1. Pipeline — esegui una volta (come sopra, usa il .venv locale)
python scripts/extract.py
python scripts/chunk.py --omnisdoc /path/to/omnisdoc   # doc pack opzionale
python scripts/validate.py
python scripts/embed_and_store.py

# 2a. Runtime Docker con PostgreSQL sull'host
cd docker_mcp-rag
copy .env.example .env
docker compose up --build

# 2b. Stack Docker completo con PostgreSQL 18
cd ../docker_mcp-rag-pg
copy .env.example .env
docker compose up --build
cd ..
python scripts/import_to_docker_postgres.py
```

Dopo l'avvio, registra `http://localhost:3000/mcp` come server MCP HTTP in VS Code.

Se non conosci il codebase, leggi prima `Pipeline_it.md`, poi `chunking_concept_it.md`, poi `docker_mcp-rag-pg/README_it.md` o `docker_mcp-rag/README_it.md` a seconda del runtime che vuoi usare. `RAG_concept_it.md` documenta le decisioni di progettazione originali.
