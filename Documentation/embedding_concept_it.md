# Concetto di embedding e retrieval: RAG per Omnis Studio

## Problema di fondo

I token specifici di Omnis come `$cwind`, `$sendall`, `kTrue`, `kRelationalList` ed `evClick` compaiono
appena nei dati di addestramento dei modelli di embedding. Gli embedding densi catturano bene il
*significato* di una domanda ("how do I loop over a list"), ma sono inaffidabili per i nomi esatti.
Il retrieval combina quindi tre segnali: similarità semantica, fulltext pesato e corrispondenza di
nomi esatti.

---

## Architettura

```text
User query (English or German)
    │
    ├── Dense embedding (bge-m3)          → 60 nearest chunks, all corpora
    ├── Full text (weighted tsvector)     → 60 best chunks, OR over the query words
    └── Name detection ($search, mid(),   → chunks that document that name
        Begin reversible block, #ERRCODE)
                    │
        Weighted Reciprocal Rank Fusion + exact-name boost   (one global ranking)
                    │
        One hit per entry/section, top_k (default 8), snippet per hit
                    │
        Agent reads the list, fetches full text of 1–3 ids (get_omnis_doc)
```

L'ordinamento risiede nella funzione di database `rag.search_ranked`
(vedi [postgres_it.md](postgres_it.md)); il rag-server prepara la query (parole, sintassi di ricerca,
nomi candidati, mappatura tedesco → inglese delle parole comuni per il ramo fulltext).

### Perché un ordinamento globale invece di top-k per corpus

La v1 recuperava un numero fisso di chunk da ogni corpus e li ordinava con un punteggio RRF per
corpus. Il primo posto di ogni corpus riceveva lo stesso punteggio, quindi comandi o funzioni non
correlati si mescolavano alle risposte concettuali. Un unico ordinamento su tutti i candidati ha
risolto il problema: sulle 18 query di test originali l'MRR@5 è salito da 0,62 a 0,79 con il solo
ramo denso (vedi [retrieval_quality_analysis_it.md](retrieval_quality_analysis_it.md)).

### Perché il fulltext conta ancora — e perché è pesato

| Query | Semantico | Fulltext |
|---|---|---|
| "how to iterate over a list" | buono | debole (parole comuni) |
| "`binfrombase64`" | vicini (`binfrombase32`) | esatto |
| "`$sendall` syntax" | buono | buono |
| `"reversible block"` (frase) | — | esatto |
| "Wie lösche ich Zeilen aus einer Liste?" | buono (multilingue) | solo tramite mappatura delle parole |

Un ramo fulltext ingenuo sul contenuto grezzo (OR di tutte le parole, stesso peso) ha peggiorato i
risultati nell'analisi (MRR 0,50), perché i chunk lunghi con parole frequenti come "list" dominano.
Il ramo fulltext della v2 usa quindi pesi per campo (titolo A, percorso di intestazioni B, contenuto
C/D), rimozione delle stop word, normalizzazione della lunghezza e un peso di fusione inferiore a
quello del ramo denso (`RAG_W_FTS`, default 0.3, scelto con una scansione dei parametri con
`scripts/eval_retrieval.py`). I nomi esatti sono gestiti dal boost separato, non dal ranking fulltext.

---

## Modello di embedding

### In uso: `BAAI/bge-m3`

- multilingue (domande in tedesco su documentazione in inglese)
- locale tramite `sentence-transformers` — nessuna chiave API, nessun costo, nessuna dipendenza dal cloud
- 1024 dimensioni, vettori normalizzati, distanza coseno
- lo stesso modello per l'indicizzazione (`embed_and_store.py`) e per le query (`ragserver.py`)

```text
Model:       BAAI/bge-m3
Dimensions:  1024
Download:    ~2.2 GB (HuggingFace cache; Docker volume hf_cache)
Cost:        $0
```

### Cosa viene incorporato

L'`embed_text` di ogni chunk = una riga di contesto + il testo del chunk, per esempio

```text
Omnis command: OK message | Group: Message boxes | Flag affected: NO | Reversible: NO | … | DEPRECATED

## OK message
…
```

oppure `Omnis Programming manual | Chapter 7—SQL Programming › SQL Worker Objects › Overview`. La riga
di contesto dà ai chunk brevi il loro significato (quale voce, quale capitolo) e non viene mostrata al
lettore. L'embedding locale limita l'input a 512 token (`--max-seq-length`), il che accorcia solo i
chunk più lunghi; il loro inizio (titolo, metadati, sintassi) viene sempre incorporato.

### Costo di costruzione degli embedding

~6.000 chunk, ~1,7 M token:

| Hardware | Durata |
|---|---|
| Apple Silicon (MPS) / GPU NVIDIA | minuti |
| Solo CPU (12 thread) | 2–4 ore |

`embed_and_store.py` è incrementale (solo i chunk il cui hash del testo è cambiato), scrive checkpoint
e può usare il modello dentro il container rag-server in esecuzione
(`--server http://localhost:7071`).

### Archiviazione

`output/embeddings.jsonl` contiene una riga per chunk con id, hash del testo, modello, limite di
token e il vettore come byte float32 esatti in base64 (~5,6 KB per chunk). Il file deriva dalla
documentazione Omnis ed è quindi ignorato da git; gli embedding costruiti su una macchina veloce
vengono copiati sulla macchina con il database (vedi il runbook in [Pipeline_it.md](Pipeline_it.md)),
e un import non richiede alcun passo di embedding. Un elenco JSON di numeri avrebbe il doppio della
dimensione.

### Alternative considerate

- `text-embedding-3-large` (OpenAI): previsto all'inizio; sostituito da una pipeline completamente locale.
- Modelli per il codice (`CodeBERT` …): Omnis non è nei loro dati di addestramento.
- Un reranker cross-encoder (per esempio `ms-marco-MiniLM`) dopo la fusione è un possibile passo
  successivo; oggi non è usato — misura con `scripts/eval_retrieval.py` prima di aggiungerlo.

---

## Parametri di retrieval

| Parametro | Dove | Default |
|---|---|---|
| `mode` | tool / `/search` | `hybrid` (`semantic`, `fulltext`) |
| `top_k` | tool / `/search` | 8 (max 30) |
| `corpus` / `corpora` | tool / `/search` | tutti |
| candidati per ramo | `rag.search_ranked` | 60 |
| costante RRF | `RAG_RRF_K` | 60 |
| peso denso / fulltext | `RAG_W_DENSE` / `RAG_W_FTS` | 1.0 / 0.3 |
| boost per nome esatto | `rag.search_ranked` | 0.02 × parole nel nome |
| lunghezza dello snippet | `RAG_SNIPPET_CHARS` | 240 |

Metadati usati al momento della query: filtro per corpus, un risultato per `doc_key`, marcatore
`[deprecated]` nell'elenco dei risultati. Gli altri metadati (gruppo del comando, execute on client,
platform, pages) sono memorizzati con ogni chunk e mostrati nel testo completo.

---

## Come lo usa un agente

1. `search_omnis_docs` → elenco compatto (≈ 600–1.000 token per 8 risultati).
2. `get_omnis_doc` per gli id rilevanti (≈ 300–600 token per chunk).

Una domanda tipica costa ~1.500–2.000 token di contesto documentale. La v1 restituiva 15.000–25.000
token per ricerca, perché lo stesso testo veniva inviato fino a quattro volte.

Qualità attesa per area: [expected_outcome_it.md](expected_outcome_it.md).
