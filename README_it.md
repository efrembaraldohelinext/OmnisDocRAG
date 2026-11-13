# Euromnis-OmnisDocRAG-example

Stack RAG locale per la documentazione di Omnis Studio. Estrae i manuali PDF (e, in opzione, il
riferimento della notazione dalla guida di Omnis), li divide in chunk, ne calcola gli embedding, li salva
in PostgreSQL con `pgvector` ed espone la ricerca semantica e full-text come tool MCP per lo sviluppo
Omnis assistito dall'AI.

---

## Orientamento rapido

Parti da qui: [Project_instructions_it.md](Project_instructions_it.md)

Il documento descrive l'obiettivo del progetto, la struttura delle directory, i passaggi di setup, l'ordine
di avvio in esecuzione e le topologie disponibili per l'uso locale e con Docker.

---

## Porta la tua documentazione

Questo repository mostra **un modo** per costruire un RAG server dalla documentazione di Omnis. Così uno
sviluppatore senza esperienza di RAG vede l'intero percorso e costruisce un primo MVP funzionante. È un
esempio, non un prodotto: esistono altri approcci e gli script potrebbero richiedere adattamenti ai tuoi
documenti. **Il repository non contiene documentazione di Omnis né materiale generato da essa.** I manuali e la
guida sono © Omnis Software Ltd. Li fornisci tu dalla tua installazione di Omnis:

- i manuali PDF `CommandRef.pdf`, `FunctionRef.pdf` e `Programming_Omnis.pdf` in `Omnis PDF/`
- in opzione, un doc pack creato dalla guida HTML della tua installazione (`OMNISDOC_PACK`)

La guida passo passo, i problemi che emergono durante l'estrazione di questi documenti e i controlli da
eseguire dopo ogni passaggio: [Documentation/Building_from_Omnis_Docs_it.md](Documentation/Building_from_Omnis_Docs_it.md).
Fai validare il risultato, preferibilmente da un agente AI: [Documentation/AI_Review_Guide_it.md](Documentation/AI_Review_Guide_it.md)
è scritta per l'agente e descrive i problemi e i controlli da fare.
`output/` (testo estratto, chunk, embedding) deriva dalla documentazione ed è ignorata da git.
Non fare commit né pubblicare questa directory.

---

## Indice della documentazione

| Documento | Contenuto |
|---|---|
| [Project_instructions_it.md](Project_instructions_it.md) | Punto di ingresso: setup, ordine di avvio, comandi di avvio rapido |
| [Documentation/Building_from_Omnis_Docs_it.md](Documentation/Building_from_Omnis_Docs_it.md) | **Parti da qui per i dati:** fornire i PDF e la guida HTML, problemi di estrazione, checklist |
| [Documentation/AI_Review_Guide_it.md](Documentation/AI_Review_Guide_it.md) | **Per un agente AI:** i problemi, dove adattare gli script, cosa controllare, formato del rapporto |
| [Documentation/RAG_concept_it.md](Documentation/RAG_concept_it.md) | Perché usare RAG, come funziona il retrieval, panoramica dell'architettura |
| [Documentation/Pipeline_it.md](Documentation/Pipeline_it.md) | Pipeline di build dei dati, piattaforme, **runbook: nuovi embedding su un Mac → server** |
| [Documentation/chunking_concept_it.md](Documentation/chunking_concept_it.md) | Come si estraggono e si dividono in chunk i PDF, e perché |
| [Documentation/embedding_concept_it.md](Documentation/embedding_concept_it.md) | Modello di embedding, dimensioni e archiviazione |
| [Documentation/postgres_it.md](Documentation/postgres_it.md) | Schema del database, vettore full-text, `rag.search_ranked` |
| [Documentation/expected_outcome_it.md](Documentation/expected_outcome_it.md) | Come appare un sistema funzionante end-to-end |
| [Documentation/retrieval_quality_analysis_it.md](Documentation/retrieval_quality_analysis_it.md) | Analisi della qualità del retrieval, misurazioni prima e dopo la revisione |
| [OmnisRAGServer/README_it.md](OmnisRAGServer/README_it.md) | Contratto del bridge MCP stdio locale e riferimento dei tool |
| [docker_mcp-rag/README_it.md](docker_mcp-rag/README_it.md) | Stack Docker: `mcp-server` + `rag-server`, con PostgreSQL sull'host |
| [docker_mcp-rag-pg/README_it.md](docker_mcp-rag-pg/README_it.md) | Stack Docker completo: PostgreSQL 18 + `pgvector` + `rag-server` + `mcp-server`; **deployment su un server Docker interno** |

---

## Tre topologie di esecuzione

**Locale**: RAG server Python + bridge MCP stdio Node.js:

```
VS Code (stdio) → mcp-bridge (Node.js) → rag-server (Python) → PostgreSQL
```

**Docker con PostgreSQL sull'host**: runtime MCP/RAG in container, il database resta fuori da Docker:

```
VS Code (HTTP) → mcp-server (Python, port 3000) → rag-server (Python, port 7071) → PostgreSQL
```

**Stack Docker completo**: PostgreSQL 18 + `pgvector` dentro Docker:

```
VS Code (HTTP) → mcp-server (Python, port 3000) → rag-server (Python, port 7071) → postgres (Docker, PG18 + pgvector)
```

---

## Cosa viene indicizzato

| Corpus | Fonte |
|---|---|
| `omnis-commands` | Command Reference (ogni comando, sezioni di panoramica, tabelle dei codici di errore) |
| `omnis-functions` | Function Reference |
| `omnis-programming` | Manuale di programmazione, tutti i capitoli |
| `omnis-notation` | Riferimento della notazione dalla guida HTML (doc pack opzionale) |

## Tool MCP

| Tool | Usalo per |
|---|---|
| `search_omnis_docs` | Ricerca ordinata su tutto. `mode`: `hybrid` (predefinito), `semantic`, `fulltext` (supporta `"phrase"`, `OR`, `-word`) |
| `get_omnis_doc` | Testo completo degli id dei risultati (secondo passaggio) |
| `search_omnis_syntax` | Stessa ricerca, solo comandi, funzioni, notazione |
| `search_omnis_concepts` | Stessa ricerca, solo il manuale di programmazione |

Le risposte di ricerca sono testo compatto (una riga + snippet per risultato, di solito 2–4 KB). Il testo
completo si recupera solo per gli id che interessano.

---

## Avvio rapido minimo (stack Docker completo)

Funziona allo stesso modo su macOS, Windows e Linux (usa `python3` / `py` al posto di `python` dove serve).

```bash
# 1. Configura e controlla la macchina
python scripts/pipeline.py setup
python scripts/pipeline.py doctor        # mostra se l'embedding gira su GPU/Apple Silicon (minuti) o su CPU (ore)

# 2. Avvia lo stack
cd docker_mcp-rag-pg
cp .env.example .env   # poi modifica le credenziali del database
docker compose up -d --build
cd ..

# 3. Build, import e controllo (doc pack opzionale: OMNISDOC_PACK in scripts/.env.local)
python scripts/pipeline.py build

# 4. VS Code — .vscode/mcp.json
# { "omnis-rag-docker": { "type": "http", "url": "http://localhost:3000/mcp" } }
```

Se vuoi usare Docker solo per `mcp-server` e `rag-server` e tenere PostgreSQL sull'host,
usa invece [docker_mcp-rag/README_it.md](docker_mcp-rag/README_it.md).

---

## Installazione su Debian 13 senza Docker

Lo script `install_omnisdocrag.sh` installa il runtime su un server Debian 13 senza Docker. Serve solo i privilegi di root.
Lo script è idempotente: puoi rilanciarlo, e converge sempre allo stesso stato.

```bash
sudo OMNIS_PDF_DIR=/percorso/dei/pdf [OMNISDOC_PACK=/percorso/del/doc-pack] bash install_omnisdocrag.sh
```

Lo script esegue questi passaggi:

- installa i pacchetti apt (`postgresql`, `postgresql-<versione>-pgvector`, `python3-venv`, `git`, `iproute2`)
- clona il repository in `/opt/omnisdocrag/src` e crea 3 virtualenv (`venv-rag`, `venv-mcp`, `venv-pipeline`) con PyTorch CPU
- crea i ruoli, il database `ragdb`, lo schema e la funzione di ranking con gli SQL del repository
- copia i 3 PDF in `Omnis PDF/` ed esegue `scripts/pipeline.py build --from extract --to import --target local`
- crea i servizi systemd `omnisdocrag-rag` (127.0.0.1:7071) e `omnisdocrag-mcp` (porta 3000)
- verifica `/health`, `/search` e la porta MCP, poi stampa una configurazione `.vscode/mcp.json` per ogni IP non loopback

Note operative:

- Il repository non contiene PDF, doc pack né embedding (© Omnis Software Ltd). Fornisci i file tu, dalla tua installazione di Omnis.
- Senza `OMNIS_PDF_DIR` lo script installa tutto, ma il database resta vuoto. Rilancia lo script con `OMNIS_PDF_DIR` per costruire i dati.
- L'embedding su CPU richiede ore. Lancia lo script in `tmux` o `screen`. Un'esecuzione interrotta riprende in modo incrementale.
- L'utente di sistema `omnisrag` deve poter leggere `OMNISDOC_PACK`. Non usare una cartella sotto `/root`.
- L'endpoint MCP non ha autenticazione e ascolta su `0.0.0.0`. Su una rete non fidata esegui lo script con `MCP_BIND_HOST=127.0.0.1`.
- `setup_project.sh` resta lo script di bootstrap per lo sviluppo (virtualenv dentro il repository). Lo script di installazione non lo richiama.
- Variabili opzionali: `REPO_URL`, `REPO_REF`, `MCP_PORT`, `RAG_PORT`, `TORCH_INDEX`, `EMBED_THREADS`, `SKIP_MODEL_DOWNLOAD`, `FORCE_BUILD`, `ALLOW_NON_DEBIAN13`.

---

## Licenza

Il codice e la documentazione di questo repository sono rilasciati sotto [licenza MIT](LICENSE).
La licenza **non** copre i manuali di Omnis né la guida di Omnis, che sono © Omnis Software Ltd e non
fanno parte di questo repository.
