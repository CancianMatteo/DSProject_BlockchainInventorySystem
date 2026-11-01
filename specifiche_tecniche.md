# Specifiche tecniche: gossip e consenso PoA-BFT

Questo documento descrive il flusso effettivamente implementato dai nodi
Elixir e i contratti JSON dell'endpoint Python interno. Elixir gestisce rete,
round, proposer e quorum; Python gestisce mempool, hash e operazioni
crittografiche.

## Workflow end-to-end

1. **Avvio del cluster.** Sono avviati tutti e quattro i nodi. Ogni servizio
   Python possiede la propria coppia Ed25519 privata/pubblica e il registro
   delle identità e delle chiavi pubbliche degli altri tre validatori. La
   configurazione usa `NODE_ID`, `VALIDATOR_PRIVATE_KEY` e
   `VALIDATOR_PUBLIC_KEYS`; la chiave privata non viene mai trasmessa.
2. **Creazione della transazione.** Un client sceglie l'API Python di un nodo e
   invia `POST /api/v1/chain/add_transaction`. La transazione contiene
   l'identità del client (`client_ID`), articolo, quantità, posizione,
   identificativo univoco e firma Ed25519 sul JSON canonico. Python autentica
   la sessione, verifica che `client_ID` corrisponda all'utente, verifica la
   firma e inserisce la transazione nella mempool. La richiesta include anche
   `client_public_key`: la firma non è verificabile senza la chiave pubblica.
3. **Gossip della transazione.** Python inoltra la transazione validata al
   proprio Elixir con `POST /api/v1/python_call` usando un oggetto piatto con
   `flag: "transaction"`. Elixir la invia al proprio Python e poi la diffonde
   ai peer con il termine Erlang. Un peer riceve la transazione dal proprio
   Elixir tramite lo stesso `python_call`, la valida e la memorizza senza
   reinoltrarla: il campo di trasporto `relay_node` impedisce i loop.
4. **Avvio della proposta.** Quando la mempool locale raggiunge
   `BLOCK_TRANSACTION_THRESHOLD`, Python invia a Elixir
   `{"flag":"trigger_block"}`. Elixir chiede al proposer del round corrente di
   preparare il blocco; il proposer ottiene da Python `block_data` con numero,
   round, transazioni, hash e `proposer_sign`. Il trigger è idempotente: un
   proposer con una proposta già attiva non ne crea una seconda.
5. **Consenso.** Il proposer diffonde `pre_prepare`; i nodi verificano la
   proposta e votano `prepare`. Dopo il quorum PREPARE viene diffuso
   `commit_proposal`; i validatori verificano il certificato PREPARE e firmano
   COMMIT. Dopo il quorum COMMIT, Elixir passa a Python il blocco, la firma del
   proposer e le firme COMMIT raccolte. Python verifica di nuovo firma del
   proposer, quorum e firme COMMIT, quindi persiste il blocco e il certificato.
6. **Conflitto e recupero.** Una prova valida di equivocation ricevuta prima
   dell'avvio del voto COMMIT blocca il voto locale e viene inoltrata agli
   altri validatori. Se il voto COMMIT era già iniziato e il blocco principale
   raggiunge il quorum, i nodi che lo finalizzano conservano il certificato
   COMMIT. Quando arriva la prova, possono recuperare quel pacchetto dal
   database Python e diffonderlo; un nodo che conserva la proposta alternativa
   verifica il certificato COMMIT, importa il blocco idempotentemente e
   riallinea l'altezza. Il certificato PREPARE non viene usato come prova di
   finalizzazione.
7. **Conferma e sincronizzazione.** Le transazioni incluse passano da
   `pending` a `finalized`. Il client interroga
   `POST /api/v1/chain/transaction_status` per la conferma della singola
   transazione e usa `POST /api/v1/chain/blockchain_sync` per riallineare la
   catena e l'inventario.

Il timeout di round di Elixir (`8` secondi) non è un secondo criterio per
creare automaticamente un blocco: serve a cambiare proposer/round quando il
consenso non progredisce. Il blocco viene proposto solo quando Python segnala
che esistono transazioni e il proposer riceve `trigger_block`; il timer può
comunque far avanzare il round se il proposer non risponde.

## Componenti e trasporto

- Il backend Python espone l'API client e `POST /api/v1/python_call` sulla porta container `8000`. Il deploy espone le porte host `8001`-`8004`, come descritto in [PORTS.md](./PORTS.md).
- Per l'avvio locale con Docker Compose, genera una volta il file di ambiente con `python3 Server_Python/generate_validator_keys.py` dalla root del repository, quindi esegui `docker compose up --build -d`.
  Il comando stampa le credenziali dell'amministratore iniziale per il login del client.
- `InventoryNode.PythonClient` invia al servizio Python un oggetto JSON e restituisce a Elixir la mappa JSON ricevuta; in caso di HTTP non riuscito o risposta JSON malformata restituisce `{:error, reason}`.
- `ClusterListener` riceve messaggi tra nodi come termini Erlang con framing `packet: 4`; `InventoryNode.Router` li inoltra al motore di consenso.
- Non viene usato un listener Elixir per i client: i client parlano con l'API Python. Le porte interne degli altri listener sono configurate nel deploy e riepilogate in [PORTS.md](./PORTS.md).

## Identità, chiavi e serializzazione

Gli ID dei validatori sono configurati staticamente tramite `NODE_ID` e gli
indirizzi `PEERS` di Elixir. Ogni backend riceve la propria chiave privata
Ed25519 Base64 in `VALIDATOR_PRIVATE_KEY`; tutti ricevono lo stesso oggetto
`VALIDATOR_PUBLIC_KEYS`, che associa ogni ID alla chiave pubblica corrispondente.
Non esistono endpoint o messaggi di scambio iniziale: le chiavi devono essere
configurate correttamente prima dell'avvio. Il `validator_id` deve coincidere
con l'ID del nodo e con la chiave associata nel registro statico.

Compose fornisce anche `SERVER_SIGN_PRIVATE_KEY` per la firma delle risposte
server. In questo progetto viene impostata sulla chiave privata Ed25519 del
validatore locale, a meno che non si configuri una chiave server separata.

Python serializza i contenuti firmati in JSON canonico (chiavi ordinate e separatori deterministici) e usa firme Ed25519 codificate in Base64. Il `block_hash` è SHA-256 del contenuto canonico del blocco.
Le firme della proposta e dei voti sono distinte: la prima prova chi ha proposto il blocco, le seconde costituiscono il certificato di quorum.

### Contratto della transazione

`quantity` è un intero diverso da zero: positivo significa ingresso e negativo
significa uscita. Il contratto usa `trans_id` come identificativo.
I campi firmati dal client sono `item_id`, `quantity`, `location`, `client_ID`,
`client_public_key`, `trans_id`, `timestamp` e `item_catalog`; Python inoltra
gli stessi dati a Elixir aggiungendo `flag: "transaction"` e rinominando la
firma in `client_signature`. Il primo Python autentica il client; i peer
verificano la firma usando la chiave pubblica inclusa nella transazione.

La consegna Python-Elixir è persistita in una coda per `trans_id`. Il client
riceve `forwarding_status` (`forwarded`, `failed` o `not_queued`) e un worker
ritenta le consegne fallite; duplicati sono innocui perché il mempool usa
`trans_id` come chiave idempotente.

## Miglioramenti futuri

- validazione della firma su un timestamp con finestra temporale;
- rifiuto delle transazioni oltre una età massima;
- nonce opzionale e cache anti-replay;
- metriche e endpoint operativo (`GET /api/v1/chain/forwarding_monitor`) per profondità della coda, tentativi e errori
  di forwarding.

## Sequenza PoA-BFT modificata

I validatori sono ordinati per ID in modo lessicografico, sia in Elixir sia in Python. Per un'altezza `height` e un round `round`, il proposer atteso è `validators[(height + round) mod numero_validatori]`.
Con `N = 3f + 1`, il quorum è `2f + 1`.

Python controlla periodicamente la mempool: quando ci sono almeno 200
transazioni pendenti, oppure ci sono transazioni pendenti e sono trascorsi 10
minuti dall'ultimo blocco committato (dall'avvio, se la chain è vuota), invia
`POST /api/v1/proposal_request` al nodo Elixir locale. Elixir risponde
`accepted: true` e avvia il normale PRE-PREPARE solo se è il proposer del round
corrente e non sta già gestendo un blocco. Se non è leader, Python ritenta al
controllo successivo. Ogni blocco contiene al massimo 200 transazioni.

Il timeout di round è 8000 ms. Il timeout non cambia da solo il proposer:
ciascun nodo firma e diffonde `ROUND_CHANGE`, e il round avanza solo quando è
raggiunto il quorum BFT. Una nuova proposta riparte dal normale flusso di
consenso e non salta le verifiche o le fasi di commit.

All'avvio, Elixir chiede a Python `chain_state` e imposta l'altezza corrente a
`next_height` restituita dal database locale (`ultimo blocco + 1`, oppure 1 se
la chain è vuota). Se Python non è ancora raggiungibile o la risposta non è
valida, Elixir ritenta e non avvia i round finché non ha uno stato valido.

### 1. Avvio del round e PRE-PREPARE

1. Elixir avvia il timeout BFT di 8000 ms e calcola il proposer.
2. Python invia il trigger di proposta quando è raggiunta una delle soglie.
   Elixir concede la proposta solo al proposer attuale; a quel punto chiede a
   Python di preparare il blocco.
3. Python costruisce il blocco dalla mempool, lo firma come proposer e
   restituisce blocco e firma.
4. Prima di inviare la proposta, il proposer chiede a Python la propria firma
   PREPARE per partecipare al quorum interno. Poi invia il messaggio
   `pre_prepare` a tutti i peer.
5. Ogni nodo chiede a Python di verificare hash, firma del proposer e scelta
   deterministica del proposer. Se la proposta è valida, firma PREPARE e
   invia il voto **unicast** al proposer.

### 2. PREPARE: raccolta del quorum di preparazione

Il proposer verifica ogni voto PREPARE con Python e lo registra una sola volta per `validator_id`. Ogni firma è legata a `height`, `round` e `block_hash`, quindi non può essere riutilizzata per un blocco diverso. Al raggiungimento di `2f + 1` firme PREPARE, il proposer invia a tutti i nodi una `commit_proposal` con il blocco, la firma del proposer e il certificato PREPARE. Questa proposta apre una nuova votazione: **non scrive il blocco**.

Ogni destinatario chiede a Python di verificare la firma del proposer, il blocco e tutte le firme PREPARE del certificato. Solo se il certificato contiene almeno `2f + 1` voti distinti e validi, il nodo partecipa alla fase COMMIT e firma il proprio voto COMMIT. Un certificato PREPARE valido è quindi la condizione per votare COMMIT, non il quorum finale di scrittura.

Un nodo che non aveva ricevuto il `pre_prepare` può apprendere la proposta attraverso un voto COMMIT: il voto porta anche il blocco, la firma del proposer e il certificato PREPARE. Il ricevente verifica la prova, adotta la proposta e vota COMMIT una sola volta per altezza e round. Questo recupera il caso in cui il proposer invia `commit_proposal` solo a una parte dei peer.

### 3. COMMIT: votazione e scrittura

Ogni validatore che accetta la `commit_proposal` firma un voto COMMIT legato a
`height`, `round`, `validator_id` e `block_hash`, poi lo invia a tutti i peer.
Ogni nodo, compreso il proposer, verifica individualmente le firme ricevute con
Python e conta al massimo un voto per validatore.
Ogni voto COMMIT include anche la proposta firmata e il certificato PREPARE, così che un nodo non informato possa verificarli prima di partecipare alla votazione.

Un nodo scrive il blocco solo quando ha raccolto almeno `2f + 1` voti COMMIT distinti e validi per lo stesso blocco. La scrittura avviene localmente su Python; il nodo avanza all'altezza successiva solo dopo la risposta positiva di `write_block`. Non è sufficiente ricevere la `commit_proposal` o il quorum PREPARE.

Una volta iniziata la votazione COMMIT, un timeout non cancella la proposta né avvia un round incompatibile: il nodo continua ad attendere i voti, secondo l'ipotesi di consegna eventuale dei messaggi. Il `ROUND_CHANGE` per timeout si usa quando la fase COMMIT non è ancora iniziata.

Le firme PREPARE restano necessarie per il quorum interno, ma non fanno parte
del certificato persistito o mostrato al client. Dopo il quorum COMMIT, il
payload `write_block` contiene soltanto la firma del proposer e la mappa
`validator_signatures.commit`, cioè le firme COMMIT dei validatori distinti.

### 4. ROUND_CHANGE

Un timeout o una prova valida di doppia proposta avvia il passaggio al round successivo. Ogni nodo conta al massimo un voto per validatore e round target; il nuovo round parte al raggiungimento del quorum.

- **Timeout:** il nodo chiede a Python di firmare il proprio `ROUND_CHANGE`.
- **Equivocazione:** il nodo invia a Python due hash e le firme del proposer. Se il proposer ha firmato entrambi gli hash diversi per la stessa altezza e round, Python produce una prova compatta firmata dal validatore accusatore. La prova contiene hash e firme, non i blocchi completi.
- I peer verificano la firma del timeout oppure, per l'equivocazione, le due firme del proposer e la firma dell'accusatore prima di contare il voto.

## Contratto JSON Python<-Elixir di `POST /api/v1/python_call`

Ogni richiesta è un singolo oggetto JSON con il campo `flag`. Le risposte indicate sono oggetti JSON. Gli errori di input o di servizio devono essere restituiti come HTTP non-2xx con un messaggio d'errore, non come successo fittizio.

| `flag` richiesta | Operazione Python | Risposta attesa |
|------------------|-------------------|-----------------|
| `chain_state` | Leggere l'ultimo blocco committato per inizializzare l'altezza del motore Elixir. | `{"next_height":2}`; restituisce `1` quando la chain è vuota. |
| `transaction` | Validare la firma del client, validare la transazione e inserirla idempotentemente nella mempool. Non alterare i campi firmati. | Transazione ricevuta con `status` e `duplicate`. |
| `trigger_block` | Chiedere al motore locale di valutare la proposta del round corrente. | HTTP `200` con `{"ok":true,"routed":true}`; la proposta parte solo se il nodo locale è il proposer. |
| `prepare_block` | Ordinare le transazioni pendenti e preparare il blocco successivo per il round richiesto. Firmare la coppia altezza/round/proposer/hash. | `{"flag":"prepare_block","block_data":{...},"proposer_sign":"<base64>"}`; se la mempool è vuota `block_data` è `null`. |
| `pre_prepare` | Verificare il blocco, il suo hash, il proposer atteso e la firma della proposta. | `{"status":true}` oppure `{"status":false}`. |
| `prepare` | Firmare un voto PREPARE legato a fase, altezza, round, validator e hash del blocco. | `{"flag":"prepare","signature":"<base64>"}`. |
| `verified_prepare` | Verificare il voto PREPARE usando la chiave pubblica del `validator_id` e il `block_hash` atteso. | `{"status":true}` oppure `{"status":false}`. |
| `commit_proposal` | Verificare la proposta e il certificato PREPARE: firme valide, validator distinti e quorum `2f+1`. Non scrivere il blocco in questa fase. | `{"status":true}` oppure `{"status":false}`. |
| `commit` | Firmare il voto COMMIT locale, legato a fase, altezza, round, validator e hash del blocco. | `{"flag":"commit","signature":"<base64>"}`. |
| `verified_commit` | Verificare la firma di un voto COMMIT per il relativo hash del blocco. Elixir conta i voti validi e applica il quorum. | `{"status":true}` oppure `{"status":false}`. |
| `write_block` | Verificare che il blocco estenda la testa corrente, salvarlo e rimuovere dalla mempool le transazioni confermate. | `{"status":true}` oppure errore HTTP/non-successo. |
| `round_change` | Firmare il payload di cambio round, inclusi `height`, `target_round`, `validator_id` e motivo. | Lo stesso payload con `signature`. |
| `verified_round_change` | Verificare la firma del timeout oppure la prova compatta di doppia proposta. | `{"status":true}` oppure `{"status":false}`. |
| `pre_prepare_conflict` | Verificare le due firme del proposer su hash distinti e creare una prova firmata dall'accusatore. | `{"status":true,"proof":{...}}`; in assenza di prova `{"status":false,"proof":null}`. |

Con `BIZANTINE_SCENARIO=equivocation`, la risposta `prepare_block` include anche `equivocation_block_data` e `equivocation_sign`: sono un secondo blocco con lo stesso height, round e parent, ma con un sottoinsieme distinto delle transazioni, e la relativa firma del proposer. Entrambe le proposte devono essere firmate con la chiave privata locale; non si usano firme contraffatte per simulare l'equivocation.

### Campi e contenuti firmati

**`prepare_block`**

Richiesta:

```json
{
  "flag": "prepare_block",
  "node_id": "node_a",
  "current_height": 1,
  "round": 0
}
```

Python determina l'altezza successiva dalla propria testa persistita (il campo `current_height` è informativo), usa `round` nel blocco e restituisce un `block_data` compatibile con la struttura corrente: `height`, `round`, `prev_block_hash`, `transactions` e `block_hash`. Se non ci sono transazioni, restituisce `block_data: null`.

La firma del proposer copre `{height, round, proposer_id, block_hash}`. `pre_prepare` riceve questi campi più `block_data` e `signature`.

**Voto PREPARE**

Richiesta di firma:

```json
{
  "flag": "prepare",
  "height": 1,
  "round": 0,
  "validator_id": "node_a",
  "block_data": {"block_hash": "..."}
}
```

Il contenuto firmato è `{phase:"prepare", height, round, validator_id, block_hash}`. Per verificare il voto il motore invia `flag: "verified_prepare"`, gli stessi metadati, `block_hash` e `signature`.

**Proposta di COMMIT con certificato PREPARE**

Il messaggio tra peer è il termine `{:commit_proposal, height, round, proposer_id, block_data, proposer_signature, prepare_signatures}`; `prepare_signatures` è una mappa `validator_id => signature`. Il Router la inoltra al motore, che la converte in una lista JSON per la verifica:

```json
{
  "flag": "commit_proposal",
  "height": 1,
  "round": 0,
  "proposer_id": "node_a",
  "block_data": {"height": 1, "round": 0, "block_hash": "..."},
  "signature": "<firma-proposer>",
  "signatures": [
    {"validator_id": "node_a", "signature": "<firma-prepare>"},
    {"validator_id": "node_b", "signature": "<firma-prepare>"},
    {"validator_id": "node_c", "signature": "<firma-prepare>"}
  ]
}
```

La risposta Python `{"status":true}` autorizza quel nodo a votare COMMIT, non a scrivere direttamente il blocco. Ogni nodo firma un voto COMMIT e propaga il termine con la prova completa:

```elixir
{:commit_vote, height, round, proposer_id, block_data, proposer_signature,
 prepare_signatures, block_hash, validator_id, signature}
```

`prepare_signatures` è la mappa `validator_id => signature` già descritta nella `commit_proposal`. Prima di contare il voto, ogni destinatario verifica sia il certificato PREPARE allegato sia la firma COMMIT del mittente.

Il messaggio corrispondente inviato a Python per la verifica è:

```json
{
  "flag": "verified_commit",
  "height": 1,
  "round": 0,
  "block_hash": "...",
  "validator_id": "node_b",
  "signature": "<firma-commit>"
}
```

Python risponde con `{"status":true}` o `{"status":false}`. Elixir conta solo voti validi e distinti per lo stesso blocco; il nodo invia `write_block` soltanto dopo aver raggiunto il quorum COMMIT `2f + 1`.

**ROUND_CHANGE per timeout**

La richiesta `round_change` include `reason: "timeout"`, `height`, `target_round` e `validator_id`. Python restituisce lo stesso oggetto con `signature`. Il destinatario cambia `flag` in `verified_round_change` per richiedere la verifica; il contenuto firmato non include il campo di instradamento `flag`.

**Prova compatta di equivocation**

Richiesta di verifica locale:

```json
{
  "flag": "pre_prepare_conflict",
  "height": 1,
  "round": 0,
  "proposer_id": "node_b",
  "validator_id": "node_a",
  "forged_block_hash": "...",
  "forged_signature": "...",
  "conflicting_block_hash": "...",
  "conflicting_signature": "..."
}
```

Python verifica che i due hash siano diversi e che entrambe le firme del proposer siano valide per la stessa altezza e round. La firma dell'accusatore copre il contenuto canonico:

```json
{
  "flag": "pre_prepare_conflict",
  "height": 1,
  "round": 0,
  "validator_id": "node_a",
  "hash_1": "<forged_block_hash>",
  "hash_2": "<conflicting_block_hash>"
}
```

La risposta `proof` contiene `flag: "pre_prepare_conflict_proof"`, altezza, round, proposer e validator, entrambi gli hash e le rispettive firme, più `validator_signature`. Elixir cambia il flag in `round_change` e aggiunge `target_round = round + 1`. Ogni peer verifica che `target_round` sia coerente, ricontrolla le firme del proposer e verifica la firma dell'accusatore prima di conteggiare il voto.

**Finalizzazione e recupero con COMMIT**

Quando il quorum COMMIT è raggiunto, Elixir invia a Python `write_block` con
`block_data`, `proposer_id`, `proposer_signature` e `commit_signatures`:

```json
{
  "flag": "write_block",
  "proposer_id": "node_b",
  "proposer_signature": "<firma-proposer>",
  "block_data": {"height": 1, "round": 0, "block_hash": "..."},
  "commit_signatures": [
    {"validator_id": "node_a", "signature": "<firma-commit>"},
    {"validator_id": "node_b", "signature": "<firma-commit>"},
    {"validator_id": "node_c", "signature": "<firma-commit>"}
  ]
}
```

Il contenuto firmato da ogni voto COMMIT include `phase: "commit"`,
`height`, `round`, `validator_id` e `block_hash`. Python rifiuta firme PREPARE
presentate come COMMIT o firme duplicate, e richiede il quorum `2f + 1`.
`block_votes.phase` identifica la fase persistita; le righe storiche senza
questa colonna vengono migrate come `prepare`, mentre le nuove finalizzazioni
salvano i voti `commit`.

Per una prova di equivocation successiva alla finalizzazione, Elixir chiede a
Python riceve `get_finalized_block` con l'altezza:

```json
{"flag": "get_finalized_block", "height": 1}
```

Se il blocco e il certificato COMMIT persistiti sono validi, la risposta è:

```json
{
  "status": true,
  "block_data": {
    "height": 1,
    "round": 0,
    "prev_block_hash": null,
    "transactions": [
      {
        "trans_id": "<transaction-id>",
        "item_id": "item-1",
        "quantity": 1,
        "location": "warehouse-1",
        "client_ID": "operator@example.test",
        "timestamp": "<ISO-8601>",
        "client_public_key": "<chiave-pubblica-Base64>",
        "signature": "<firma-client-Base64>",
        "item_catalog": {
          "item-1": {
            "itemName": "Item",
            "brand": "Brand",
            "category": "General"
          }
        }
      }
    ],
    "block_hash": "..."
  },
  "proposer_id": "node_b",
  "proposer_signature": "<firma-proposer>",
  "commit_signatures": [
    {"validator_id": "node_a", "signature": "<firma-commit>"},
    {"validator_id": "node_b", "signature": "<firma-commit>"},
    {"validator_id": "node_c", "signature": "<firma-commit>"}
  ]
}
```

Se il blocco non è presente o non ha un certificato valido, Python restituisce
`{"status": false}`.

Il messaggio gossip `{:finalized_block, package}` viene ricevuto dal Router e
inoltrato a `import_finalized_block`, che riceve lo stesso pacchetto aggiungendo
`"flag": "import_finalized_block"`. Python verifica nuovamente certificato e
firma del proposer e controlla che il blocco estenda la testa locale. In caso
positivo restituisce `{"status": true}` (e `duplicate: true` se già presente);
una ripetizione dello stesso blocco è idempotente, mentre un blocco che non
estende la catena locale viene rifiutato.

## Transazioni e gossip

Una transazione inviata dal client a Python contiene i campi applicativi
`item_id`, `quantity`, `location`, `client_ID`, `signature` e
`client_public_key`, oltre ai campi necessari al dominio (`trans_id`,
`timestamp` e, per nuovi articoli, `item_catalog`).

Una transazione inoltrata da Python a Elixir conserva i campi firmati dal
client, ma usa il nome `client_signature` richiesto dal protocollo interno.
Il payload HTTP verso Elixir è:

```json
{
  "flag": "transaction",
  "client_ID": "client@example.com",
  "trans_id": "uuid",
  "item_id": "item-1",
  "quantity": 2,
  "location": "warehouse-1",
  "client_public_key": "<base64>",
  "client_signature": "<base64>"
}
```

Il campo `relay_node` è l'unico metadato di trasporto non firmato; Elixir lo
rimuove prima della validazione Python e lo usa per evitare i loop di gossip.
I peer Python usano `client_public_key` contenuta nella transazione per
verificare `client_signature`; non devono cercare la chiave del client nel
registro `VALIDATOR_PUBLIC_KEYS`. Quel registro contiene solo le chiavi dei
quattro validatori e serve per le firme di consenso.

Le transazioni duplicate non vengono reinoltrate. Dopo la conferma del blocco, Python rimuove dalla mempool le transazioni incluse.

## Modalità di simulazione bizantina

In modalità bizantina le transazioni valide seguono lo stesso percorso delle altre modalità: vengono validate, aggiunte alla mempool e inoltrate ai peer.
La fault injection altera esclusivamente i messaggi di consenso. Per selezionare lo scenario, impostare lo stesso `BIZANTINE_SCENARIO` nel container Elixir e in quello Python del nodo bizantino:

| Valore | Comportamento simulato | Difesa attesa |
|---|---|---|
| `split_brain` | Il proposer invia `commit_proposal` solo ai primi due peer ordinati e non vota COMMIT. I voti COMMIT dei peer portano il certificato PREPARE e vengono diffusi a tutti. | I peer non informati verificano la prova e votano COMMIT; ogni nodo scrive solo dopo aver contato `2f+1` voti. |
| `equivocation` | Il proposer invia due blocchi distinti, entrambi firmati, a due partizioni. Il blocco alternativo contiene un sottoinsieme delle transazioni del blocco principale, con la stessa altezza e lo stesso parent. | Ogni validatore onesto fissa una sola proposta per altezza/round e segnala le due firme del proposer; non firma entrambi i blocchi. |
| `leader_offline` | Il proposer invia PRE-PREPARE e raccoglie PREPARE, ma non invia `commit_proposal` né il proprio `ROUND_CHANGE`. | In assenza di voti COMMIT, i nodi onesti raggiungono il quorum `ROUND_CHANGE` dopo il timeout e passano al round successivo. |
| `invalid_signature` | Il blocco mantiene dati e hash coerenti, ma il nodo bizantino genera firme di consenso non verificabili (inclusa la firma del proposer). | I peer rifiutano le firme invalide; i validatori onesti possono comunque raggiungere il quorum `2f+1`. |

Il valore predefinito è `invalid_signature`. Lo scenario `equivocation` richiede almeno due transazioni pendenti; con meno di due, l'endpoint `prepare_block` restituisce un errore esplicito. `ByzantineEngine` è un supporto di fault injection chiamato dal `ConsensusEngine`, non un secondo motore avviato nella supervision tree. La modalità `noresponse` continua invece a scartare il traffico secondo il proprio comportamento dedicato.
