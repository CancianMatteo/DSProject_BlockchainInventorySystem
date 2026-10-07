# Dettagli Implementativi: Router e Struttura Transazioni (Elixir)

Questo documento definisce i dettagli implementativi per la gestione delle transazioni nel sistema di inventario basato su blockchain permissioned[cite: 1], prendendo spunto dall'implementazione corrente in Elixir. In particolare, si concentra sulla struttura JSON dei payload inviati dai client al backend, gestiti dai listener del livello di rete.

## Contesto Architetturale

Come illustrato nell'immagine "image_fcef1b.png"[cite: 1], il sistema Elixir funge da interfaccia di rete (Server Interface)[cite: 1]. Nello specifico, il modulo `ClusterListener` (visibile nello screenshot) si occupa di ascoltare le comunicazioni intra-cluster (tra i nodi validatori) su una porta dedicata, decodificando i messaggi binari tramite `:erlang.binary_to_term` e inoltrandoli a `InventoryNode.Router.handle_payload`[cite: 1]. Parallelamente, è presente un `ClientListener` (non mostrato in dettaglio, ma deducibile dalla struttura dei file) che accetta richieste in ingresso dai client[cite: 1].

Il modulo `InventoryNode.Router` analizzato funge da dispatcher, inoltrando le richieste (come le transazioni o il setup delle chiavi) al servizio Python (che gestirà la Mempool e la logica di consenso BFT).

## Struttura del Payload JSON per le Transazioni

Sulla base del codice Elixir fornito nel `Router`, e in allineamento con i requisiti del progetto (FR-1, FR-2, FR-3), quando un client (nodo operatore) invia una transazione al backend (tramite il `ClientListener` che si trova in ascolto sulla porta 5000 del host base), il payload JSON deve rispettare la seguente struttura:

```json per le transazioni


## API Python deve gestire i seguenti messaggi:

-JSON di forma {
  "flag": "transaction",
  "from_node": "string" (client),
  "tx_type": "string",
  "item_id": "string",
  "quantity": "int",
  "location": "string",
  "timestamp": "string",
  "tx_id": "string",
} Le transazioni ricevute sono solo da mettere in una lista (o meglio ancora un set) di 'transazioni pendenti'. Queste poi vengono rimosse quando un blocco proposto e CONFERMATO viene scritto nella blockchain.

- JSON di forma {flag: "setup_keys", from_node: Node.self()}: deve generare chiave pubblica e privata del nodo richiedente e salvarle per le future firme, ritornando a questo messaggio un JSON {"flag": "setup_keys", "pub_key": pub_key}. Inoltre deve essere presente un dizionario con le chiavi pubbliche degli altri peers (nodo_A: pubkey_a)

- JSON di forma {flag: "setup_keys_warning", from_node: from_node, pub_key: pub_key}: ricevi la chiave pubblica di un'altro nodo appena acceso e si deve registrare nel dizionario di chiavi pubbliche degli altri nodi. Deve restituire un JSON {"flag" => "setup_keys_warning", "status" => "success"}.


- JSON di forma {flag: "prepare_block", node_id: Node.self() (string) , current_height: current_height (int)}: prepara un blocco della block chain e restituisce un json di forma:
{"block_data":
  {"hash": "0x8f4b2c9a...e31d",
  "header": {
    "height": 101,
    "previous_hash": "0x3a1b...99df",
    "timestamp": 1696322400,
    "proposer": "0xValidatorC_Address",
    "round": 1,
    "transactions_root": "0x7c4e...11bb",
    "state_root": "0x9d2a...55cc",
  },
  "transactions": [
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
  ]
},
"proposer_sign": "(signature_proposer)"
}

- JSON di forma {
      "flag" => "round_change",
      "height" => state.current_height,
      "target_round" => target_round,
      "validator_id" => state.node_id,
      "signature" => nil
    } : Bisogna semplicemente aggiungere la firma del nodo che lo richiede e ritornare lo stesso JSON ma con la firma


- JSON di forma {"flag" => "pre_prepare_conflict",
 "height" => height, 
 "round" => round, 
 "proposer_id"=>proposer_id,
  "block_data" => block_data, 
  "signature" =>signature,
  "conflicting_block"=> state.pending_block,
"conflicting_signature" => state.temporary_signature
  } : Dovresti verificare che 'block_data' e la sua 'signature' corrispondano a quelli del leader che la proppone 'proposer_id', lo stesso per "conflicting_block" e "conflicting_signature". Se entrambi sono firmati da 'proposer_id' e i blocchi sono diversi allora restituisci un JSON con {"status": boolean, "validator_signature": signature} con "status" = true e la firma del nodo che sta controllando su le proof (proof è "validator_id","block_data","signature","conflicting_block","conflicting_signature") se il leader ha proposto effettivamente due blocchi diversi (bizantino), false altrimenti


DUE TIPI DI ROUND CHANGE (timeout e doppia proposta di blocchi diversi):
- JSON di forma {
      "flag" => "verified_round_change",
      "height" => state.current_height,
      "target_round" => target_round,
      "validator_id" => state.node_id,
      "signature" => signature
    } : in questo caso bisogna verificare la 'signature' del nodo "validator_id" con la sua chiave pubblica, ritornando un JSON con {"status": true} o {"status": false}

- JSON di forma  {
      "flag" => "verified_round_change",
      "height" => height,
      "target_round" => round + 1,
      "validator_id" => state.node_id,
      "conflicting_block" => state.pending_block, 
      "conflicting_signature" => state.temporary_signature,
      "forged_block" => block_data,
      "forged_signature" => signature,
      validator_signature: proof["validator_signature"]
            } : Dovresti verificare che 'block_data' e la sua 'signature' corrispondano a quelli del leader che la proppone 'proposer_id', lo stesso per "conflicting_block" e "conflicting_signature". Se entrambi sono firmati da 'proposer_id' e i blocchi sono diversi allora restituisci un JSON con {"status": boolean}. Verifica anche la firma del validatore con la sua chiave pubblica sulla proof (proof è "validator_id","block_data","signature","conflicting_block","conflicting_signature")

- JSON di forma {"flag" => "pre_prepare",
 "height" => height,
  "round" => round,
   "proposer_id"=>proposer_id,
    "block_data" => block_data,
     "signature" =>signature} : verifica la signature fatta per il 'proposer_id' per il 'block_data' usando la sua chiave pubblica, restituisce un JSON {"is_valid": boolean} 


- JSON di forma {"flag" => "prepare", 
"height" => height,
 "round" => round,
  "validator_id" => state.node_id,
   "block_data" => block_data} : firma il 'block_data' con la chiave privata del nodo che lo richiede e restituisci un JSON {"signature" : signature} 

- JSON di forma {"flag" => "verified_prepare",
                  "height" => height, 
                  "round" => round, 
                  "validator_id" => validator_id, 
                  "signature" => signature} : verifica la firma 'signature' con la chiave pubblica del 'validator_id' e ritorna un JSON del tipo {"status": boolean} con 'true' se corrisponde la firma o 'false' altrimenti
              
- JSON di forma {"flag" => "commit", 
                  "height" => height, 
                  "round" => round,
                  "validator_id" => state.node_id} : restituisci un JSON {"signature" : signature} del nodo 'validator_id'


- JSON di forma {"flag" => "verified_commit", 
                  "height" => height,
                  "round" => round,
                    "validator_id" => validator_id,
                    "signature" => signature} : verifica la firma 'signature' con la chiave pubblica del 'validator_id' e ritorna un JSON del tipo {"status": boolean} con 'true' se corrisponde la firma o 'false' altrimenti

- JSON di forma {"flag" => "write_block", 
                  "height" => height,
                  "block_data" => state.pending_block} : scrivi il blocco "block_data" definitivamente sulla blockchain

                  

  




