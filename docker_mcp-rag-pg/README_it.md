# docker_mcp-rag-pg — Stack Omnis RAG completo con PostgreSQL 18

Questa cartella offre una seconda configurazione Docker per il progetto:

- `postgres` con PostgreSQL 18 e `pgvector`
- `rag-server`
- `mcp-server`

Esiste accanto a `docker_mcp-rag/`, che usa PostgreSQL sull'host. `rag-server` e
`mcp-server` vengono costruiti dalle cartelle di servizio di `docker_mcp-rag/`.

## A cosa serve questo stack

Usa questa configurazione quando vuoi che il progetto funzioni subito su una macchina nuova:

- nessuna installazione locale di PostgreSQL richiesta
- schema e ruoli vengono creati automaticamente al primo avvio
- gli embedding si importano dal progetto nel database del container
- la voce esistente `omnis-rag-docker` in `.vscode/mcp.json` continua a funzionare

## File

```text
docker_mcp-rag-pg/
├── docker-compose.yml
├── .env.example
├── README.md
└── postgres-init/
    ├── 10-init-ragdb.sh          esegue una volta i file SQL qui sotto, su un volume vuoto
    └── sql/                      non eseguiti direttamente dall'entrypoint di postgres
        ├── 20-rag-bootstrap.sql  ruoli (password da .env)
        ├── 30-rag-schema.sql     schema v2 (idempotente, migra la v1)
        └── 40-rag-ranking.sql    rag.search_ranked
```

I file SQL si trovano in `sql/` perché l'entrypoint di postgres esegue da solo ogni `*.sql` di primo livello in
`/docker-entrypoint-initdb.d`: altrimenti il bootstrap verrebbe eseguito una seconda volta senza le variabili
delle password e fallirebbe.

## Primo avvio

1. Crea il file env:

```bash
cp .env.example .env
```

2. Modifica password e porte in `.env`.

Puoi configurare la porta host di PostgreSQL con:

```env
POSTGRES_HOST_PORT=5432
```

Se vuoi rendere il database raggiungibile da altre macchine, modifica anche:

```env
POSTGRES_BIND_HOST=0.0.0.0
```

3. Avvia lo stack:

```bash
cd docker_mcp-rag-pg
docker compose up --build -d
```

Al primo avvio PostgreSQL inizializza il volume del database ed esegue gli SQL
di `postgres-init/`. Il RAG server attende poi il database e parte non appena
riesce a connettersi e a caricare il modello di embedding.

### Aggiornamento dello schema su un volume esistente

Gli script di inizializzazione girano solo su un volume vuoto. Dopo una modifica dello schema ricrea il volume
del database (l'import ricostruisce i dati; il volume della cache del modello `hf_cache` resta):

```bash
docker compose rm -sf postgres
docker volume rm docker_mcp-rag-pg_postgres_data
docker compose up -d
python ../scripts/import_to_docker_postgres.py
```

oppure applica `sql/30-rag-schema.sql` e `sql/40-rag-ranking.sql` direttamente:

```bash
docker compose exec -T postgres psql -U postgres -d ragdb -v ON_ERROR_STOP=1 < postgres-init/sql/30-rag-schema.sql
docker compose exec -T postgres psql -U postgres -d ragdb -v ON_ERROR_STOP=1 < postgres-init/sql/40-rag-ranking.sql
```

## Import in PostgreSQL su Docker

`output/` (chunk ed embedding) non fa parte del repository. Costruiscila prima oppure copiala dalla macchina che l'ha creata.
(La build è descritta in [`Documentation/Pipeline_it.md`](../Documentation/Pipeline_it.md).)

**Dentro Docker (consigliato sui server: nessun Python sull'host, nessuna porta del database pubblicata):**

```bash
cd docker_mcp-rag-pg
docker compose --profile import run --rm importer
```

Il servizio `importer` esegue `scripts/import_to_postgres.py` nell'immagine di rag-server contro il
servizio `postgres` e termina (~30 s per ~6.000 chunk).

**Dall'host** (richiede il `.venv` della pipeline e la porta PostgreSQL pubblicata), dalla radice del repository:

```bash
python scripts/import_to_docker_postgres.py
```

Cosa fa lo script:

- carica `docker_mcp-rag-pg/.env` se presente
- punta `scripts/import_to_postgres.py` alla porta pubblicata di PostgreSQL su Docker
- passa oltre gli argomenti aggiuntivi, ad esempio `--allow-missing` per importare una build parziale mentre gli
  embedding sono ancora in calcolo

Se serve, puoi usare un file env personalizzato:

```bash
python scripts/import_to_docker_postgres.py --env-file docker_mcp-rag-pg/.env
```

## Ottimizzazione dopo l'import

Dopo un import consistente esegui `VACUUM ANALYZE` dentro il container PostgreSQL, così il
planner e gli indici risultano aggiornati:

```bash
cd docker_mcp-rag-pg
docker compose exec postgres psql -U rag_owner -d ragdb -c "VACUUM ANALYZE rag.embedding;"
docker compose exec postgres psql -U rag_owner -d ragdb -c "VACUUM ANALYZE rag.chunk;"
```

Importante:

- Esegui ogni `VACUUM` in una chiamata `psql -c` separata.
- `VACUUM` non può girare dentro un blocco di transazione: non combinare le due istruzioni
  in un unico `-c`.

## Deployment su un server Docker interno

Il repository contiene tutto ciò che serve al server: codice, SQL, chunk ed embedding. Il server
richiede Docker con il plugin Compose e git, senza Python né GPU. Le immagini e l'immagine `pgvector` sono
multi-architettura (amd64 e arm64).

### Prima installazione

```bash
git clone https://github.com/SDI76/Euromnis-OmnisDocRAG-example.git && cd Euromnis-OmnisDocRAG-example
cd docker_mcp-rag-pg
cp .env.example .env
```

Modifica `.env`:

| Impostazione | Valore sul server |
|---|---|
| `POSTGRES_PASSWORD`, `RAG_DB_PASS`, `RAG_DB_OWNER_PASS`, `RAG_DB_RO_PASS` | valori propri (applicati solo al primo avvio di un volume vuoto) |
| `POSTGRES_BIND_HOST` | `127.0.0.1` — il database resta locale; l'importer gira dentro Docker |
| `RAG_BIND_HOST` | `127.0.0.1` — solo l'MCP server parla con il rag-server (rete Docker) |
| `MCP_BIND_HOST` / `MCP_PORT` | `0.0.0.0` / `3000` — l'endpoint usato dai client |

```bash
docker compose up -d --build                        # primo avvio: download del modello ~2,2 GB in hf_cache
docker compose --profile import run --rm importer   # carica output/ nel database
docker compose ps                                    # rag-server healthy, mcp-server up
curl -s http://127.0.0.1:7071/health                 # numero di chunk per corpus
```

Il primo avvio del rag-server richiede alcuni minuti (download e caricamento del modello). L'MCP server parte
quando il rag-server è healthy.

I client si connettono a `http://<server>:3000/mcp` (Streamable HTTP), ad esempio in `.vscode/mcp.json` o `.mcp.json`:

```json
{ "omnis-doc-reference": { "type": "http", "url": "http://<server>:3000/mcp" } }
```

### Aggiornamento di un deployment esistente

```bash
cd Euromnis-OmnisDocRAG-example && git pull        # solo il codice; copia separatamente un output/ ricostruito
cd docker_mcp-rag-pg
docker compose up -d --build                        # ricostruisce rag-server / mcp-server se il loro codice è cambiato
docker compose --profile import run --rm importer   # serve solo se output/ è cambiato
```

Se l'SQL in `postgres-init/sql/` è cambiato (vedi il log di git), applicalo prima dell'import: gli script
di inizializzazione girano solo su un volume vuoto:

```bash
docker compose exec -T postgres psql -U postgres -d ragdb -v ON_ERROR_STOP=1 < postgres-init/sql/30-rag-schema.sql
docker compose exec -T postgres psql -U postgres -d ragdb -v ON_ERROR_STOP=1 < postgres-init/sql/40-rag-ranking.sql
```

**Aggiornamento di un server che usa ancora lo stack v1** (prima della revisione): ricrea invece il volume del
database. L'importer ricostruisce completamente i dati, la cache del modello resta:

```bash
docker compose rm -sf postgres
docker volume rm docker_mcp-rag-pg_postgres_data
docker compose up -d --build
docker compose --profile import run --rm importer
```

### Sicurezza

L'endpoint MCP non ha autenticazione. Pubblicalo solo su una rete interna (oppure limitalo con
il firewall dell'host) e tieni `POSTGRES_BIND_HOST` e `RAG_BIND_HOST` su `127.0.0.1`. L'endpoint `/embed`
del rag-server calcola gli embedding su richiesta e non deve essere raggiungibile dalla rete.

## Connessione a VS Code

Il workspace contiene già:

```json
{
  "servers": {
    "omnis-rag-docker": {
      "type": "http",
      "url": "http://localhost:3000/mcp"
    }
  }
}
```

Dopo l'avvio dello stack, riavvia l'MCP server in VS Code e connettiti a
`omnis-rag-docker`.

## Comandi comuni

Avvio:

```bash
docker compose up --build -d
```

Log:

```bash
docker compose logs -f
docker compose logs -f postgres
docker compose logs -f rag-server
docker compose logs -f mcp-server
```

Arresto:

```bash
docker compose down
```

Rimuovi solo il volume del database (l'import ricostruisce i dati):

```bash
docker compose rm -sf postgres
docker volume rm docker_mcp-rag-pg_postgres_data
```

`docker compose down -v` rimuove **tutti** i volumi, inclusa la cache del modello `hf_cache` da ~2,2 GB.

## Note

- Le password vengono applicate solo durante il bootstrap iniziale del database. Se le modifichi
  in seguito, ricrea il volume di PostgreSQL (vedi sopra).
- PostgreSQL 18 si aspetta il volume persistente in `/var/lib/postgresql`, non in
  `/var/lib/postgresql/data`. Il file compose usa già il layout di mount compatibile con PG18.
- `rag-server` e `mcp-server` vengono costruiti dalle cartelle di servizio di `docker_mcp-rag`, quindi nel repository
  esiste un solo percorso di codice per questi servizi.
- Gli script dei container devono mantenere i fine riga LF; `.gitattributes` lo impone nei checkout su Windows.
- L'immagine PostgreSQL si basa sull'immagine Docker ufficiale di `pgvector` per Postgres 18:
  https://github.com/pgvector/pgvector
