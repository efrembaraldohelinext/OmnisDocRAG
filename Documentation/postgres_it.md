# Schema PostgreSQL — Omnis RAG (v2)

Sorgenti SQL (condivise tra lo stack Docker e la configurazione locale):

- `docker_mcp-rag-pg/postgres-init/sql/20-rag-bootstrap.sql` — ruoli (Docker, con password da `.env`)
- `docker_mcp-rag-pg/postgres-init/sql/30-rag-schema.sql` — tabelle, vettore fulltext, corpus
- `docker_mcp-rag-pg/postgres-init/sql/40-rag-ranking.sql` — `rag.search_ranked`

PostgreSQL locale: `scripts/setup_db.sql` e `scripts/setup_ranking.sql` includono i file precedenti.
Entrambi i file dello schema sono idempotenti; `30-rag-schema.sql` migra un database v1 (elimina la vecchia
colonna `content_tsv` e le funzioni per corpus).

---

## Tabelle

```text
rag.corpus     (corpus_id, name, description)
  └── rag.document  (document_id, corpus_id, external_id, title, meta)          uno per chunk
        └── rag.chunk  (chunk_id, document_id, chunk_index, content, meta,
                        title, heading, symbols text[], search_tsv tsvector)
              └── rag.embedding  (chunk_id, model, embedding_dim, v vector(1024))
```

- `document.external_id` = id del chunk da `chunk.py` (`cmd_ok_message`, `not_list_properties_1`, …).
- `meta->>'doc_key'` raggruppa le parti di una voce; `part` / `parts` le numerano.
- `symbols`: nomi normalizzati che il chunk documenta (`do method`, `mid`, `ojson.jsontolistorrow`,
  `line`, `search`, …) — minuscolo, senza `$`, `#`, `()`.

| Corpus | Contenuto |
|---|---|
| `omnis-commands` | Command Reference: comandi, sezioni di panoramica, tabelle dei codici di errore |
| `omnis-functions` | Function Reference |
| `omnis-programming` | Manuale Programming, capitoli 1–17 |
| `omnis-notation` | nodi della notation con proprietà, metodi, eventi (doc pack) |

---

## Vettore fulltext

Costruito dal trigger `trg_chunk_search_tsv` (funzione `rag.build_search_tsv`):

| Peso | Campo | Configurazione | Scopo |
|---|---|---|---|
| A | title | `english` + `simple` | nomi delle voci, senza e con stemming |
| B | heading path | `english` | capitolo › sezione › sottosezione |
| C | content | `simple` | token esatti (`binfrombase64`, `errcode`) |
| D | content | `english` | prosa con stemming (`lists` → `list`) |

Il ranking usa `ts_rank_cd('{0.2,0.4,0.7,1.0}', search_tsv, query, 1)` (normalizzato per lunghezza).

---

## Indici

```sql
CREATE INDEX ix_chunk_search_tsv ON rag.chunk USING GIN (search_tsv);
CREATE INDEX ix_chunk_symbols    ON rag.chunk USING GIN (symbols);
CREATE INDEX ix_embedding_hnsw   ON rag.embedding USING hnsw (v vector_cosine_ops) WITH (m = 16, ef_construction = 128);
```

---

## `rag.search_ranked`

```sql
SELECT * FROM rag.search_ranked(
  p_query_vec     := '<1024-dim vector>'::vector,   -- NULL = nessun ramo semantico
  p_terms         := ARRAY['list','search'],         -- parole combinate in OR; NULL = nessun ramo fulltext
  p_websearch     := NULL,                           -- query grezza con "phrase", OR, -word (prevale su p_terms)
  p_boost_symbols := ARRAY['search'],                -- nomi trovati nella query
  p_corpora       := NULL,                           -- NULL = tutti i corpus
  p_top_k         := 8,
  p_candidate_k   := 60,
  p_w_dense       := 1.0,
  p_w_fts         := 0.3,
  p_rrf_k         := 60);
```

1. **dense**: i 60 chunk più vicini per distanza coseno, su tutti i corpus selezionati.
2. **fts**: i 60 chunk migliori per rank fulltext pesato. Le parole sono combinate in OR nelle configurazioni `english` e
   `simple`; `p_websearch` usa invece `websearch_to_tsquery`.
3. **exact**: chunk il cui `symbols` contiene un nome della query; boost `0.02 × words in the name`.
4. **fusion**: `w_dense / (60 + dense_rank) + w_fts / (60 + fts_rank) + boost` — un unico ranking globale.
5. **grouping**: un risultato per `doc_key`; snippet `ts_headline` per i primi risultati.

Il rag-server costruisce `p_terms` (stop word rimosse, parole tedesche comuni di Omnis mappate in inglese),
rileva la sintassi di ricerca per `p_websearch` e ricava `p_boost_symbols` dalla query.

---

## Ruoli

| Ruolo | Diritti |
|---|---|
| `rag_owner` | possiede schema e oggetti; esegue i file SQL |
| `rag_app` | lettura/scrittura dei dati (import, rag-server) |
| `rag_ro` | sola lettura |

---

## Dopo un import massivo

```bash
cd docker_mcp-rag-pg
docker compose exec postgres psql -U rag_owner -d ragdb -c "VACUUM ANALYZE rag.embedding;"
docker compose exec postgres psql -U rag_owner -d ragdb -c "VACUUM ANALYZE rag.chunk;"
```

`VACUUM` non può girare dentro un blocco di transazione — un'istruzione per ogni `-c`.
