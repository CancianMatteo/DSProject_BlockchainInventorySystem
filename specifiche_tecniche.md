# Dettagli Implementativi: Router e Struttura Transazioni (Elixir)

Questo documento definisce i dettagli implementativi per la gestione delle transazioni nel sistema di inventario basato su blockchain permissioned[cite: 1], prendendo spunto dall'implementazione corrente in Elixir. In particolare, si concentra sulla struttura JSON dei payload inviati dai client al backend, gestiti dai listener del livello di rete.

## Contesto Architetturale

Come illustrato nell'immagine "image_fcef1b.png"[cite: 1], il sistema Elixir funge da interfaccia di rete (Server Interface)[cite: 1]. Nello specifico, il modulo `ClusterListener` (visibile nello screenshot) si occupa di ascoltare le comunicazioni intra-cluster (tra i nodi validatori) su una porta dedicata, decodificando i messaggi binari tramite `:erlang.binary_to_term` e inoltrandoli a `InventoryNode.Router.handle_payload`[cite: 1]. Parallelamente, è presente un `ClientListener` (non mostrato in dettaglio, ma deducibile dalla struttura dei file) che accetta richieste in ingresso dai client[cite: 1].

Il modulo `InventoryNode.Router` analizzato funge da dispatcher, inoltrando le richieste (come le transazioni o il setup delle chiavi) al servizio Python (che gestirà la Mempool e la logica di consenso BFT).

## Struttura del Payload JSON per le Transazioni

Sulla base del codice Elixir fornito nel `Router`, e in allineamento con i requisiti del progetto (FR-1, FR-2, FR-3), quando un client (nodo operatore) invia una transazione al backend (tramite il `ClientListener` che si trova in ascolto sulla porta 5000 del host base), il payload JSON deve rispettare la seguente struttura:

```json per le transazioni
{
  "flag": "transaction",
  "from_node": "string" (client),
  "tx_type": "string",
  "item_id": "string",
  "quantity": "int",
  "location": "string",
  "timestamp": "string",
  "tx_id": "string",
}


## API Python deve gestire i seguenti messaggi:

- JSON di forma {flag: "setup_keys", from_node: Node.self(), pub_key: pub_key}: deve generare chiave pubblica e privata del nodo richiedente e salvarle per le future firme, ritornando a questo messaggio un JSON {"flag": "setup_keys", "pub_key": pub_key}. Inoltre deve essere presente un dizionario con le chiavi pubbliche degli altri peers (nodo_A: pubkey_a)

- JSON di forma {flag: "setup_keys_warning", from_node: from_node, pub_key: pub_key}: ricevi la chiave pubblica di un'altro nodo appena acceso e si deve registrare nel dizionario di chiavi pubbliche degli altri nodi. Deve restituire un JSON {"flag" => "setup_keys_warning", "status" => "success"}.

