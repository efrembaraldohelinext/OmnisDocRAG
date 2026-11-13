# Concetto di estrazione e chunking

## Panoramica

| Corpus | Fonte | Unità di chunk |
|---|---|---|
| `omnis-commands` | `CommandRef.pdf` (+ doc pack per le aggiunte) | 1 comando; sezioni di panoramica |
| `omnis-functions` | `FunctionRef.pdf` (+ doc pack per le aggiunte) | 1 funzione |
| `omnis-programming` | `Programming_Omnis.pdf`, tutti i capitoli | 1 sottosezione con percorso di intestazioni |
| `omnis-notation` | Omnis doc pack (help HTML), facoltativo | 1 panoramica del nodo + gruppi di membri |

Pipeline: `extract.py` → `chunk.py` → `validate.py` → `embed_and_store.py` → `import_to_postgres.py`.
Ogni passo legge da `output/` il risultato del passo precedente.

---

## Perché i PDF sono difficili

I manuali in `Omnis PDF/` (non fanno parte di questo repository) sono i file distribuiti da Omnis;
FunctionRef e Programming sono stati risalvati (PDFium, macOS Preview) perché gli originali erano
difficili da leggere. Le conseguenze:

| Proprietà | CommandRef | FunctionRef | Programming |
|---|---|---|---|
| Segnalibri | 508 (uno per comando) | nessuno | nessuno |
| Intestazioni marcate nel PDF | no | no | no |
| Font del titolo della voce | Montserrat-Bold 8 pt, uguale alle etichette "Syntax" | uguale | — |
| Titoli di sezione | — | — | Montserrat-Bold 9.2 pt (sezioni), 7.7 pt (sottosezioni), 11 pt (capitoli) |
| Font del codice | LMMono10 **10 pt** | LMMono10 10 pt | LMMono10 **9.6 pt** — più grande dei titoli di sezione |
| Spaziatura del codice | glifi posizionati senza caratteri spazio | uguale | uguale |

`pymupdf4llm` converte le pagine in buon Markdown (tabelle, elenchi, testo in grassetto) ma deduce le
intestazioni dalla dimensione del font. Di conseguenza

- ha trasformato le **righe di codice in intestazioni** (220 dei 1.543 chunk di programming della v1
  avevano una riga di codice come titolo),
- ha reso alcuni titoli di voce come **testo in grassetto** invece che come intestazione, quindi il
  chunker della v1 ha fuso la voce con la precedente (66 comandi su 499 e ≥ 25 funzioni sono andati
  persi),
- ha perso le **legature "fi"/"fl" dentro le tabelle** ("specifed", "frst", "fag") — PyMuPDF espande
  una legatura in due caratteri nella stessa posizione e la sua estrazione delle tabelle scarta il
  secondo.

---

## Estrazione (`scripts/extract.py`)

**Principio: struttura dal PDF, contenuto da pymupdf4llm.**

1. `pymupdf4llm` rende ogni pagina in Markdown (`page_chunks=True`).
2. La **spaziatura del codice** viene riparata per pagina con `pdfplumber` (raggruppamento di parole
   con tolleranza x sulle righe LMMono), abbinando le righe per la loro forma senza spazi.
3. Le **legature** vengono riparate con un vocabolario costruito dal testo semplice della pagina (che
   è intatto): una parola sconosciuta viene corretta quando esattamente un'inserzione di "i" o "l"
   dopo una "f" produce una parola nota. 1.158 riparazioni, per esempio `specifed → specified`,
   `usequalifers → usequalifiers`, `fag → flag`.
4. La **struttura del documento** viene letta dal PDF stesso (span PyMuPDF con font e posizione):
   - **CommandRef / FunctionRef:** una voce inizia alla riga in grassetto subito prima dell'etichetta
     della sua tabella di metadati ("Command group" / "Function group"). I segnalibri, quando ci
     sono, rendono canonici i titoli; i segnalibri senza tabella ("FileOps error codes", "Web
     Command Error Codes") diventano sezioni.
   - **Programming:** intestazioni di capitolo / sezione / sottosezione in base al font
     (Montserrat-Bold a 11 / 9.2 / ~7.7 pt, riga isolata). Le righe LMMono non sono mai
     intestazioni. Quando ci sono i segnalibri, si usano quelli.
5. Il Markdown della pagina viene **tagliato in corrispondenza di quei marcatori**. Un marcatore si
   individua come riga Markdown isolata; se manca la riga del titolo (titolo reso dentro una
   tabella), il taglio avviene sulla tabella di metadati. La ricerca della voce successiva parte
   dopo la tabella della voce corrente, quindi nessuna voce può assorbire la successiva.
6. Il **markup delle intestazioni viene riscritto** in modo coerente: titolo della voce `##`,
   etichette (`Syntax`, `Options`, `Description`, `Example`) `###`; ogni altra intestazione dedotta
   da pymupdf4llm diventa testo, e quelle simili a codice diventano blocchi di codice. Queste
   riscritture non toccano mai i blocchi di codice.
7. Le **tabelle di metadati** vengono lette dalle coordinate del PDF (celle di intestazione e valore
   sotto di esse), non dal Markdown generato, che compare in tre varianti di tabella e talvolta come
   testo semplice. Le celle di intestazione troncate al bordo della pagina ("Pla") vengono abbinate
   per prefisso.
8. Casi speciali: l'elenco dei **comandi obsoleti** si trova in pagine di indice a più colonne che la
   conversione in Markdown scarta; viene letto dal testo semplice della pagina. Gli elenchi dei
   gruppi di funzioni a più colonne di FunctionRef (pagine 3–7) vengono saltati — il gruppo di ogni
   funzione è nei suoi metadati.

Output: `output/extracted/<source>.json` (unità con titolo, percorso di intestazioni, pagine, Markdown,
metadati) e `output/<source>_extracted.md` per l'ispezione manuale.

---

## Chunking (`scripts/chunk.py`)

### Formato uniforme del chunk

```json
{
  "id": "cmd_ok_message",
  "corpus": "omnis-commands",
  "title": "OK message",
  "heading_path": ["OK message"],
  "text": "## OK message\n\nCommand group: Message boxes | Flag affected: NO | ...",
  "embed_text": "Omnis command: OK message | Group: Message boxes | ... | DEPRECATED\n\n## OK message ...",
  "metadata": {"source": "CommandRef", "omnis_version": "11", "page_start": 178, "doc_key": "cmd_ok_message", ...}
}
```

- `text` è ciò che riceve il lettore; `embed_text` aggiunge una riga di contesto ed è ciò che viene
  incorporato.
- `doc_key` raggruppa le parti di una voce; la ricerca restituisce un risultato per `doc_key`.
- Limite di dimensione: 450 parole. Le voci più lunghe vengono divise ai confini dei paragrafi; i
  singoli blocchi troppo grandi vengono divisi per righe di tabella (intestazione ripetuta), righe
  di codice o frasi. Ogni parte ripete l'intestazione della voce (titolo e riga di metadati).

### Comandi e funzioni

- Una voce = un chunk; la riga di metadati (`Command group: … | Flag affected: … | …`) sostituisce la
  tabella resa.
- Campi di metadati: `command_name`, `command_group`, `flag_affected`, `reversible`,
  `execute_on_client`, `platform` (funzioni: `function_name`, `function_signature`,
  `function_group`, …), `page_start`, `page_end`.
- Con il doc pack:
  - `deprecated`, `deprecation` e `modern_equivalent` provengono dall'help di Omnis 11.1 (il PDF non
    ha un flag affidabile). Lì 153 comandi sono classificati come legacy, per esempio `OK message`
    (`deprecated_no_replacement`).
  - Le voci presenti nell'help 11.1 ma non nel PDF (Studio 11.0, rev. 35659) vengono aggiunte
    dall'help: `If`, `Else If`, `While`, `Until`, `coalesce()`, `bool()`, `charat()`,
    `FileOps.$copy()` … (`source: OmnisDocPack`).
  - I comandi del PDF che l'help 11.1 non elenca più ricevono `in_help_11_1: false` e una nota (119
    comandi legacy come i gruppi DDE e Advise).

### Manuale Programming

- Un chunk per sottosezione; `heading_path` = capitolo › sezione › sottosezione, ripetuto nella riga
  di contesto dell'embedding. Sono inclusi tutti i 17 capitoli (la v1 escludeva i capitoli 1 e 4).
- Le unità senza un vero corpo (un'intestazione seguita direttamente da una sottointestazione)
  vengono fuse nell'unità successiva della stessa sezione invece di diventare chunk quasi vuoti.

### Notazione (doc pack)

I PDF non contengono alcun riferimento della notazione. Con il doc pack (`--omnisdoc PATH` o
`OMNISDOC_PACK`) ogni pagina di notazione (1.121 nodi) diventa:

- un **chunk di nodo**: descrizione più i nomi delle sue proprietà, dei suoi metodi, eventi, membri
  standard e nodi figli (per esempio `Children: $bobjs $objs $toolbars …`),
- **chunk di membri** di ~300 parole: `- \`$line\` — The current line in the list …`, con i membri
  deprecati marcati.

---

## Validazione (`scripts/validate.py`)

Controlli bloccanti (exit code 1):

- CommandRef: ogni segnalibro dal primo comando in poi ha un'unità (499/499).
- FunctionRef: voci = tabelle di metadati nel PDF (357/357).
- Programming: capitoli 1–17 consecutivi; nessun titolo di sezione somiglia a codice.
- Nessun danno da legature; id univoci; nessun chunk vuoto o troppo grande; tutti i campi presenti.

Informativi: comandi e funzioni presenti solo nel doc pack o solo nel PDF.
Report: `output/validation_report.json`.
