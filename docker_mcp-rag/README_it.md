# docker_mcp-rag — Stack Omnis RAG in container

Questa cartella contiene la configurazione Docker per eseguire lo stack Omnis RAG come container, con
PostgreSQL sull'host. Le cartelle `rag-server/` e `mcp-server/` sono il sorgente di entrambi i servizi:
`docker_mcp-rag-pg/` esegue la build da qui, e lo script di avvio locale `OmnisRAGServer/rag-server/ragserver.py`
esegue `rag-server/ragserver.py`.

---

## Contenuto della cartella

```text
docker_mcp-rag/
├── mcp-server/
│   ├── server.py          MCP server — Python FastMCP, Streamable HTTP
│   ├── requirements.txt   mcp bloccato sotto la 2.0 (la 2.x ha rinominato FastMCP)
│   └── Dockerfile
├── rag-server/
│   ├── ragserver.py       RAG retrieval server (FastAPI) — l'unica copia del codice del server
│   ├── requirements.txt
│   └── Dockerfile
├── docker-compose.yml     Orchestra entrambi i servizi
├── .env.example           Modello di configurazione
└── README.md              Questo file
```

---

## A cosa accede davvero il RAG server?

Il container `rag-server` richiede due risorse esterne in esecuzione:

### 1. PostgreSQL con pgvector (`ragdb`)

Il RAG server si connette a PostgreSQL ed esegue `rag.search_ranked` (semantica + full-text pesato +
boost sul nome esatto, un unico ordinamento su tutti i corpus) sullo schema `rag`. Prima dell'avvio le seguenti tabelle devono essere già popolate:

| Tabella | Contenuto |
|---|---|
| `rag.corpus` | Le raccolte di documenti (commands, functions, programming, notation) |
| `rag.document` | Una riga per chunk, con i metadati della fonte |
| `rag.chunk` | Testo del chunk, titolo, percorso delle intestazioni, nomi dei simboli, `tsvector` pesato |
| `rag.embedding` | `vector(1024)` a 1024 dimensioni per chunk |

Gli script della pipeline nel progetto principale creano e popolano il database.
Vedi [`Documentation/Pipeline_it.md`](../Documentation/Pipeline_it.md) per il processo completo
e [`Documentation/postgres_it.md`](../Documentation/postgres_it.md) per i dettagli dello schema.

Il container Docker si connette a **PostgreSQL della tua macchina host** (non a un database in container).
`host.docker.internal` viene risolto nell'IP dell'host tramite l'impostazione `extra_hosts` in
`docker-compose.yml`. Configura PostgreSQL in modo che accetti connessioni dalla subnet di Docker
(vedi [Configurazione di PostgreSQL](#2-configurazione-di-postgresql) più sotto).

### 2. Modello di embedding BAAI/bge-m3

All'avvio il RAG server carica `BAAI/bge-m3` tramite `sentence-transformers`.
Il modello pesa circa 2,2 GB e viene scaricato da HuggingFace al primo avvio. Il server offre anche
`POST /embed`, quindi `scripts/embed_and_store.py --server http://localhost:7071` può creare gli embedding
dei documenti con questo modello in cache.

Per evitare il download a ogni avvio:
- La configurazione Docker Compose usa un **volume con nome** (`hf_cache`) che conserva il modello
  tra i riavvii e le ricostruzioni dei container.
- Se hai già il modello in cache locale in `~/.cache/huggingface/`, puoi montare
  quella directory (vedi il commento in `docker-compose.yml`).

---

## Architettura

```text
┌─────────────────────────────────────────────────┐
│  docker-compose                                   │
│                                                   │
│  ┌──────────────────┐   HTTP    ┌──────────────┐ │
│  │  mcp-server      │ ────────► │  rag-server  │ │
│  │  Python FastMCP  │ :7071     │  FastAPI     │ │
│  │  port 3000       │           │  port 7071   │ │
│  └────────┬─────────┘           └──────┬───────┘ │
│           │                            │         │
└───────────┼────────────────────────────┼─────────┘
            │ HTTP /mcp                  │ TCP
            │ (Streamable HTTP)          │ PostgreSQL + bge-m3
            ▼                            ▼
     VS Code Copilot             Host machine
     (MCP client)                (PostgreSQL on port 5432)
```

**Trasporto MCP:** Streamable HTTP (protocollo MCP 2025-03-26)
VS Code si connette a `http://localhost:3000/mcp` con `"type": "http"` in `mcp.json`.

---

## Prerequisiti

- Docker Desktop (Windows/macOS) oppure Docker Engine + plugin Compose (Linux)
- PostgreSQL in esecuzione sulla macchina host con il database `ragdb` popolato
- Accesso a Internet per il primo download del modello (CDN di HuggingFace)

---

## Configurazione

### 1. Crea `.env`

```bash
cp .env.example .env
```

Apri `.env` e inserisci le credenziali del database:

```env
RAG_DB_HOST=host.docker.internal   # lascia invariato — Docker lo risolve nell'IP dell'host
RAG_DB_PORT=5432
RAG_DB_NAME=ragdb
RAG_DB_USER=rag_app
RAG_DB_PASS=your_actual_password   # obbligatoria
EMBED_MODEL=BAAI/bge-m3
RAG_PORT=7071
MCP_PORT=3000
```

Lascia `RAG_DB_HOST` impostato su `host.docker.internal`. Docker Compose lo risolve
automaticamente nell'IP della macchina host tramite l'impostazione
`extra_hosts: host.docker.internal:host-gateway`. Non devi mai scrivere l'IP dell'host nel file.

### 2. Configurazione di PostgreSQL

Il container `rag-server` si connette da una subnet di Docker (di solito `172.17.x.x` o
`172.18.x.x`). PostgreSQL deve consentire queste connessioni.

**`postgresql.conf`** — fai ascoltare PostgreSQL su tutte le interfacce:
```
listen_addresses = '*'
```

**`pg_hba.conf`** — consenti le connessioni dalla subnet di Docker:
```
host    ragdb    rag_app    172.0.0.0/8    md5
```

Riavvia PostgreSQL dopo queste modifiche.

---

## Avvio

```bash
cd docker_mcp-rag
docker compose up --build
```

Al **primo avvio**:
1. Docker costruisce entrambe le immagini (~2–4 min)
2. `rag-server` scarica `BAAI/bge-m3` (~2,2 GB, salvato nel volume `hf_cache`)
3. `rag-server` si connette a PostgreSQL e segnala di essere pronto
4. `mcp-server` parte dopo il superamento dell'health check di `rag-server` (l'health check concede 5 minuti
   per caricare il modello su una CPU occupata)

Negli **avvii successivi** il modello viene caricato dal volume e lo stack è attivo in ~30 s.

**In background:**
```bash
docker compose up -d
```

**Log:**
```bash
docker compose logs -f
docker compose logs -f rag-server
docker compose logs -f mcp-server
```

**Arresto:**
```bash
docker compose down
```

---

## Connessione a VS Code

Il file `.vscode/mcp.json` nella radice del workspace contiene già la voce:

```json
{
  "omnis-rag-docker": {
    "type": "http",
    "url": "http://localhost:3000/mcp"
  }
}
```

Avvia lo stack con `docker compose up`, poi riavvia l'MCP server in VS Code
(**MCP: Restart Server**). Il server `omnis-rag-docker` dovrebbe connettersi subito.

---

## Tool disponibili

I tool chiamano il RAG server (`/search`, `/chunks`) e restituiscono testo semplice compatto. Il
rag-server esegue tutto l'ordinamento e la formattazione.

| Tool | Ambito | Usalo per |
|---|---|---|
| `search_omnis_docs` | tutti i corpus (`corpus` per restringere) | Ricerca ordinata; `mode` = hybrid \| semantic \| fulltext, `top_k` |
| `get_omnis_doc` | — | Testo completo degli id dei risultati |
| `search_omnis_syntax` | commands, functions, notation | Firme, parametri, proprietà, metodi |
| `search_omnis_concepts` | Manuale di programmazione | Pattern, architettura; `deep=true` → 15 risultati |

Vedi [`OmnisRAGServer/README_it.md`](../OmnisRAGServer/README_it.md) per il formato della risposta.

---

## Aggiornamento di ragserver.py

`rag-server/ragserver.py` è l'unica copia del codice del server. Lo script di avvio locale
`OmnisRAGServer/rag-server/ragserver.py` esegue questo file. Dopo le modifiche:

```bash
docker compose build rag-server && docker compose up -d rag-server
```

---

## Relazione con la configurazione di sviluppo locale

| | Configurazione locale | Configurazione Docker |
|---|---|---|
| Trasporto MCP | stdio NDJSON | Streamable HTTP (MCP 2025-03-26) |
| MCP server | `OmnisRAGServer/mcp-bridge/mcpserver.mjs` (Node.js) | `docker_mcp-rag/mcp-server/server.py` (Python) |
| RAG server | avviato manualmente | gestito da Docker Compose |
| Cache del modello | `~/.cache/huggingface/` | volume Docker con nome `hf_cache` |
| Configurazione VS Code | `"type": "stdio"` | `"type": "http"` |

Entrambe le configurazioni condividono lo stesso database PostgreSQL e usano lo stesso modello `BAAI/bge-m3`.
La configurazione locale è documentata in [`OmnisRAGServer/README_it.md`](../OmnisRAGServer/README_it.md)
e in [`Documentation/Pipeline_it.md`](../Documentation/Pipeline_it.md).
