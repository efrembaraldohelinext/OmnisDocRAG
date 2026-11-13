# Concetto RAG: documentazione di Omnis Studio

## Obiettivo

Omnis Studio è un linguaggio proprietario di nicchia; i modelli linguistici conoscono poco i suoi
comandi, le sue funzioni e la sua notazione e producono codice plausibile ma errato. Questo progetto
trasforma la documentazione Omnis in una base di conoscenza ricercabile, che gli agenti di
programmazione interrogano tramite MCP prima di scrivere codice Omnis.

Requisiti:

- **completa** — ogni comando, funzione, membro di notazione e sezione del manuale contenuti nelle fonti
- **ricercabile per significato e per parole** — domande in inglese o tedesco, nomi esatti, frasi
- **economica per chiamata** — risposte compatte; testo completo solo su richiesta
- **locale** — nessuna API cloud, riproducibile dai file di questo repository (+ doc pack facoltativo)

---

## Fonti

| Fonte | Contenuto | Versione Omnis |
|---|---|---|
| `CommandRef.pdf` (357 pagine, 508 segnalibri) | ogni comando 4GL con tabella di metadati, sintassi, opzioni, descrizione, esempio; sezioni di panoramica, codici di errore | Studio 11 (rev. 35659) |
| `FunctionRef.pdf` (157 pagine, nessun segnalibro) | ogni funzione con tabella di metadati, sintassi, descrizione, esempio | Studio 11 (rev. 35659) |
| `Programming_Omnis.pdf` (614 pagine, 17 capitoli, nessun segnalibro) | concetti e pattern: librerie, variabili, metodi, OOP, liste, SQL, report, finestre, localizzazione, VCS, deployment | Studio 11 |
| Omnis doc pack (facoltativo) | Markdown costruito dall'help di Omnis 11.1: comandi, funzioni, **notazione** (1.121 nodi) | 11.1 |

I PDF sono i file distribuiti da Omnis (FunctionRef e Programming sono stati risalvati perché gli
originali erano difficili da leggere). Il riferimento della notazione — quali proprietà e metodi ha un
oggetto — esiste solo nell'help di Omnis, non nei PDF; il doc pack lo aggiunge.

---

## Corpora

| Corpus | Unità di chunk | Metadati |
|---|---|---|
| `omnis-commands` | un comando (+ sezioni di panoramica e codici di errore) | group, flag affected, reversible, execute on client, platform, deprecated, pages |
| `omnis-functions` | una funzione | group, execute on client, platform, pages |
| `omnis-programming` | una sottosezione con il suo percorso di intestazioni (capitolo › sezione › sottosezione) | chapter, section, pages |
| `omnis-notation` | una panoramica del nodo + gruppi di membri | node path, section, deprecated members |

Decisioni di progetto ancora valide dal concetto originale:

- **Unità naturali.** Comandi e funzioni sono voci autonome; un chunk non mescola mai due voci.
- **Le voci deprecate restano** nell'indice (il codice legacy va comunque compreso) ma sono marcate,
  così gli agenti le spiegano invece di proporle.
- **Metadati nell'embedding.** Una riga di contesto (nome della voce, gruppo, flag o percorso di
  intestazioni) viene incorporata nell'embedding con il chunk, così anche i chunk brevi portano il
  loro significato.
- **Embedding locali.** `BAAI/bge-m3`, multilingue, 1024 dimensioni — per l'indicizzazione e per le
  query.

---

## Architettura

```text
Omnis PDF/*.pdf ─┐
doc pack (opt.) ─┤ extract.py → chunk.py → validate.py → embed_and_store.py → import
                 ▼
          PostgreSQL + pgvector  (schema rag: corpus → document → chunk → embedding)
                 ▼
          rag-server  /search  /chunks  /embed  /health
                 ▼
          MCP: search_omnis_docs · get_omnis_doc · search_omnis_syntax · search_omnis_concepts
                 ▼
          coding agent (VS Code, Claude Code, Codex, …)
```

Topologie di runtime (il livello MCP non esegue mai il retrieval da solo):

1. Locale: PostgreSQL → `rag-server` (Python) → bridge stdio `OmnisRAGServer/mcp-bridge/mcpserver.mjs`
2. Docker con PostgreSQL sull'host: `docker_mcp-rag/` (rag-server + mcp-server, porta HTTP 3000)
3. Stack Docker completo: `docker_mcp-rag-pg/` (PostgreSQL 18 + pgvector + entrambi i server)

---

## Come funziona il retrieval

1. La query viene incorporata in un embedding (ramo semantico), divisa in parole per il ramo fulltext
   pesato (stop word rimosse, parole tedesche comuni di Omnis mappate in inglese) e analizzata per
   trovare nomi Omnis.
2. Il database ordina tutti i corpora insieme: i vettori più vicini, le migliori corrispondenze
   fulltext e i chunk che documentano un nome della query vengono fusi in **un unico** ordinamento.
3. Si restituisce un risultato per voce/sezione, come riga con titolo, fonte, pagine, id e snippet.
4. L'agente recupera il testo completo degli id rilevanti.

Dettagli: [embedding_concept_it.md](embedding_concept_it.md), [postgres_it.md](postgres_it.md).
Estrazione e chunking: [chunking_concept_it.md](chunking_concept_it.md).
Misurazioni e motivi di questo progetto: [retrieval_quality_analysis_it.md](retrieval_quality_analysis_it.md).

---

## Controllo qualità

- **In fase di build:** `scripts/validate.py` — ogni comando con segnalibro e ogni tabella di funzione
  dei PDF deve essere presente, nessuna riga di codice come titolo, nessun testo danneggiato, tutti i
  campi del chunk presenti; confronto incrociato con il doc pack.
- **Retrieval:** `scripts/eval_retrieval.py` — 40 domande (comandi, funzioni, notazione, concetti,
  SQL, tedesco, nomi esatti) con risultati attesi; Hit@5 e MRR@5 per modalità. Eseguilo prima e dopo
  ogni modifica.
- **Runtime:** `scripts/test_mcp_rag_bridge.py` — test end-to-end dei tool MCP.
