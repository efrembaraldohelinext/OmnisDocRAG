# 1. Miglioramento atteso

La qualità del retrieval attesa è la stessa in tutte le varianti di runtime supportate:

- PostgreSQL locale + `rag-server` locale + bridge MCP stdio
- `docker_mcp-rag/` con PostgreSQL sull'host
- `docker_mcp-rag-pg/` con PostgreSQL 18 dentro Docker

Tutte usano gli stessi corpus, lo stesso modello di embedding `BAAI/bge-m3` e la stessa funzione di ricerca PostgreSQL (`rag.search_ranked`).

## Baseline senza RAG

L'AI ha solo una conoscenza di base di Omnis. Omnis è un linguaggio proprietario di nicchia, quasi assente da internet. Il codice generato sembrerebbe sintatticamente plausibile, ma sarebbe sbagliato nella sostanza. Stima: circa `~5%` di sintassi corretta per le domande specifiche.

## Con la documentazione indicizzata

| Area | Senza RAG | Con RAG | Limite |
| --- | --- | --- | --- |
| Chiamate di funzione (`abs()`, `replace()`, `OJSON.*`) | ~5% | ~90% | `FunctionRef` è completo |
| Sintassi dei comandi (`Calculate`, `Do`, `If`, opzioni) | ~5% | ~90% | `CommandRef` è completo |
| Pattern di notation (`$assign`, `$sendall`, `$open`) | ~15% | ~70% | La Programming Guide è forte sul piano concettuale |
| Proprietà per oggetto (`$visible`, `$textcolor`, ...) | ~10% | ~80% | Corpus notation dall'help di Omnis 11.1 (doc pack) |
| Codice dei gestori di eventi | ~10% | ~50% | Documentato solo in parte |
| Pattern SQL | ~10% | ~75% | Ben coperto nella Programming Guide |

## Quadro complessivo realistico

Per i compiti standard ("scrivimi un metodo che costruisce una lista e la scorre"), il codice generato direttamente eseguibile dovrebbe passare da circa `~5%` a `~70-80%`.

Le proprietà degli oggetti (quali proprietà ha un Data Grid?) non sono nei PDF; arrivano dal corpus notation, che viene costruito dall'help di Omnis 11.1 quando il doc pack è disponibile. Senza il doc pack questa lacuna resta.

Confronto con GitHub Copilot per i linguaggi noti: Copilot raggiunge circa `~85-90%` di sintassi corretta, perché ha visto milioni di esempi. Con il RAG, Omnis può raggiungere circa `~70-80%`, un risultato molto valido per un linguaggio che nessun LLM ha mai visto davvero.

---

# 2. Costo in token dell'architettura

## Retrieval in due passi

Una ricerca restituisce una lista compatta — per ogni risultato una riga (corpus, titolo, sorgente, id) e uno snippet di
~240 caratteri. Dimensione tipica: 8 risultati ≈ 2–4 KB ≈ 600–1,000 token. Poi l'agente recupera il testo
completo di 1–3 id rilevanti con `get_omnis_doc` (i chunk sono ≤ 450 parole, ~300–600 token ciascuno).

| Passo | Token |
| --- | --- |
| Ricerca (8 risultati, snippet) | ~600–1,000 |
| Testo completo di 2 chunk | ~600–1,200 |
| Totale tipico per domanda | ~1,500–2,000 |

Prima del rework una singola ricerca restituiva 50–105 KB (il testo era incluso fino a quattro volte),
cioè ~15,000–25,000 token per chiamata.

## Prompt completo per turno

- System prompt (contesto Omnis, istruzioni): `~800 tokens`
- Contesto RAG (iniettato): `~2,500 tokens`
- Cronologia della conversazione (cresce nel tempo): `~1,000 tokens`
- Domanda dell'utente + codice: `~500 tokens`
- Input totale per turno: `~5,000 tokens`
- Output (codice generato + spiegazione): `~1,000 tokens`

## Costo con `claude-sonnet-4-6`

- Input: `$3.00 / 1M tokens -> 5,000 tokens = $0.015`
- Output: `$15.00 / 1M tokens -> 1,000 tokens = $0.015`
- Per turno: `~$0.030`
- Compito agentico (5-8 turni): `~$0.15-0.24`

## Costo una tantum dell'embedding (intero corpus)

- circa 6,000 chunk e ~1.7 M token in totale con tutti e quattro i corpus (build dell'autore; la tua sarà diversa)
- Embedding locale: minuti su GPU / Apple Silicon, alcune ore su una semplice CPU; in seguito
  vengono rielaborati solo i chunk modificati

Nel repository attuale questo costo è di fatto `$0`, perché gli embedding sono generati in locale con `BAAI/bge-m3` tramite `sentence-transformers`.

In passato, anche un percorso di embedding basato su OpenAI sarebbe stato trascurabile con questa dimensione del corpus.

---

# Quadro complessivo

L'architettura RAG costa circa `~$0.015` in più per turno rispetto all'uso senza RAG, a causa del contesto iniettato. È il compromesso:

- Senza RAG: economico (`~$0.010/turn`), ma solo `~5%` di codice corretto
- Con RAG: `~$0.030/turn`, ma circa `~75%` di codice corretto

Per un IDE agentico il rapporto costi/benefici è molto vantaggioso. La leva più grande per migliorare ancora sarebbe ottenere in qualche modo l'accesso alle proprietà degli oggetti, estraendole dall'help online di Omnis oppure registrando sviluppatori Omnis reali mentre lavorano e usando il risultato come esempi few-shot.
