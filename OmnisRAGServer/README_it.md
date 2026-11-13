# Omnis RAG Server / MCP Bridge — Contratto

## Scopo

Il runtime è composto da due parti:

- `rag-server`: server di retrieval HTTP su PostgreSQL. Il codice si trova in
  `docker_mcp-rag/rag-server/ragserver.py`; `OmnisRAGServer/rag-server/ragserver.py` è un wrapper sottile
  che lo avvia con il file `.env` accanto al wrapper.
- `mcp-bridge`: bridge MCP stdio per VS Code che inoltra le chiamate dei tool a `rag-server`.

Il bridge dipende dal rag-server e deve poterlo raggiungere.

Alternative in container con trasporto Streamable HTTP offrono gli stessi tool:

- [`docker_mcp-rag/`](../docker_mcp-rag/README_it.md): Docker MCP/RAG con PostgreSQL sull'host
- [`docker_mcp-rag-pg/`](../docker_mcp-rag-pg/README_it.md): stack Docker completo con PostgreSQL 18 + `pgvector`

## Tool

| Tool | Argomenti | Scopo |
|---|---|---|
| `search_omnis_docs` | `query`, `mode` = hybrid \| semantic \| fulltext, `top_k` (8), `corpus` = all \| commands \| functions \| programming \| notation | ricerca ordinata nella documentazione |
| `get_omnis_doc` | `ids` (fino a 20) | testo completo dei risultati di ricerca |
| `search_omnis_syntax` | `query`, `top_k`, `mode` | ricerca in comandi, funzioni, notazione |
| `search_omnis_concepts` | `query`, `top_k`, `deep`, `mode` | ricerca nel manuale di programmazione; `deep=true` → 15 risultati |

Le query possono essere in inglese o in tedesco. I nomi esatti (`mid()`, `$search`, `#ERRCODE`,
`Begin reversible block`) vengono riconosciuti e messi per primi. In modalità `fulltext` la query supporta
`"exact phrase"`, `OR` e `-exclusion`.

## Formato della risposta

Testo semplice, senza wrapper JSON:

```text
Omnis documentation — 8 results for "set the current line of a list" (hybrid):
1. [notation] List properties ($colcount … $smartlist) — Omnis help 11.1 — id: not_list_properties_1
   - `$line` — The current line in the list This changes when the user clicks on a list line …
2. [command] Set current list — CommandRef p.270 — id: cmd_set_current_list
   …
Full text: get_omnis_doc with one or more ids.
```

`get_omnis_doc` restituisce ogni chunk con una riga di intestazione (`[id] title — source — other parts: …`)
seguita dal testo Markdown.

## Avvio

### 1. Avvia il RAG server

```bash
cd Euromnis-OmnisDocRAG-example/OmnisRAGServer/rag-server
source .venv/bin/activate          # dipendenze: requirements.txt
python ragserver.py                # http://127.0.0.1:7071
```

### 2. Registra il bridge in VS Code

`.vscode/mcp.json` nella radice del workspace: VS Code avvia il bridge da sé.

```json
{
  "omnis-rag-local": {
    "type": "stdio",
    "command": "node",
    "args": ["${workspaceFolder}/OmnisRAGServer/mcp-bridge/mcpserver.mjs"],
    "env": { "OMNIS_RAG_SERVER_URL": "http://127.0.0.1:7071" }
  }
}
```

## Formato di trasmissione

`mcpserver.mjs` usa JSON-RPC delimitato da newline (un oggetto per riga, senza intestazioni
`Content-Length`), come specificato per il trasporto stdio di MCP.

## Test ed esempi

- `python scripts/test_mcp_rag_bridge.py`: test end-to-end del bridge contro un rag-server in esecuzione
- `example-tool-call-*.json`: richieste `tools/call` di esempio
