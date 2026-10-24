defmodule InventoryNode.ByzantineEngine do
  use GenServer
  require Logger

  @round_timeout 10000 # tempo massimo per chiudere un blocco prima di cambiare Proposer

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, opts ++ [name: __MODULE__])
  end

  @impl true
  def init(:ok) do
    node_id = System.get_env("NODE_ID")
    python_host = System.get_env("PYTHON_HOST") |> String.to_charlist()
    python_port = System.get_env("PYTHON_PORT") |> String.to_integer()
    peers = parse_peers(System.get_env("PEERS"))

    # In PBFT tutti i nodi (incluso se stesso) formano la lista dei validatori
    validator_nodes = Enum.sort([node_id | Map.keys(peers)])
    total_nodes = length(validator_nodes)

    # N = 3f + 1 -> Quorum = 2f + 1
    # 4 nodi -> f=1 -> Quorum = 3
    f = div(total_nodes - 1, 3)
    quorum = 2 * f + 1

    state = %{
      node_id: node_id,
      peers: peers,
      validators: validator_nodes,
      python_host: python_host,
      python_port: python_port,
      quorum: quorum,

      # Stato BFT
      current_height: 1,      # numero del blocco
      current_round: 0,       # tentativo corrente per questa altezza
      timer_ref: nil,
      temporary_signature: nil,

      # contatori per le fasi BFT
      prepare_votes: MapSet.new(),
      commit_votes: MapSet.new(),
      round_change_votes: %{},

      # Dati del blocco in lavorazione
      pending_block: nil,
      temporary_signature: nil
    }

    Logger.info("BFT-PoA Avviato. Nodo: #{node_id}. Quorum: #{quorum}/#{total_nodes}")
    {:ok, start_round(state)}
  end


  # GESTIONE DEL ROUND E PROPOSER (ROUND-ROBIN)


  defp start_round(state) do
    if state.timer_ref, do: Process.cancel_timer(state.timer_ref)
    timer_ref = Process.send_after(self(), :round_timeout, @round_timeout)

    # il proposer è deterministico: (altezza + round) mod (numero totale di nodi)
    proposer_index = rem(state.current_height + state.current_round, length(state.validators))
    current_proposer = Enum.at(state.validators, proposer_index)

    # pulisce i voti del round precedente
    new_state = %{state |
      timer_ref: timer_ref,
      prepare_votes: MapSet.new(),
      commit_votes: MapSet.new(),
      pending_block: nil,
      temporary_signature: nil
    }

    if current_proposer == state.node_id do
      Logger.info("[Altezza #{state.current_height}] Sono il Proposer (Round #{state.current_round})")
      propose_block(new_state)
    else
      Logger.info("[Altezza #{state.current_height}] Proposer atteso: #{current_proposer}")
      new_state
    end
  end

  @impl true
  def handle_info(:round_timeout, state) do
    target_round = state.current_round + 1
    Logger.warning("Timeout blocco #{state.current_height}. Avvio fase ROUND_CHANGE verso il round #{target_round}")

    # richiede la firma per il cambio round
    payload = %{
      "flag" => "round_change",
      "height" => state.current_height,
      "target_round" => target_round,
      "validator_id" => state.node_id,
      "signature" => nil
    }
    payload = send_to_python_service(payload, state.python_host, state.python_port)

    # crea il messaggio e lo invia a tutti i peers
    msg = {:round_change, payload}
    broadcast_to_all(state.peers, msg)

    # si aspettiamo il quorum
    {:noreply, state}
  end


  # ROUND CHANGE (in caso di: timeout o proposer bizantino (2 blocchi diversi proposti))

  @impl true
  def handle_cast({:round_change, payload}, state) do
    engine_pid = self()

    round_payload = payload
                    |> Map.put("flag", "verified_round_change") # assicura che il flag sia corretto

    # asincrona
    Task.start(fn ->
      is_valid = send_to_python_service(round_payload, state.python_host, state.python_port)

      Logger.info("Firma ROUND_CHANGE verificata per round #{round_payload["target_round"]} da #{round_payload["validator_id"]}")
      send(engine_pid, {:verified_round_change, round_payload["height"], round_payload["target_round"], round_payload["validator_id"], is_valid["status"]})

    end)

    {:noreply, state}
  end


  @impl true
  def handle_info({:verified_round_change, height, target_round, validator_id, true}, state) do
    # Accettiamo il voto solo se riguarda l'altezza corrente e un round futuro
    if height == state.current_height and target_round > state.current_round do

      # recupera i voti attuali per questo specifico target_round, oppure crea un nuovo MapSet
      current_votes = Map.get(state.round_change_votes, target_round, MapSet.new())
      new_votes = MapSet.put(current_votes, validator_id)

      new_round_change_map = Map.put(state.round_change_votes, target_round, new_votes)
      new_state = %{state | round_change_votes: new_round_change_map}

      Logger.info("Ricevuto voto ROUND_CHANGE per round #{target_round} da #{validator_id} (#{MapSet.size(new_votes)}/#{state.quorum})")

      # Quorum (2f + 1)
      if MapSet.size(new_votes) == state.quorum do
        Logger.warning("Quorum raggiunto per il cambio round. Transizione al round #{target_round}")

        # aggiorniamo il round corrente e puliamo i voti di questo target_round
        final_state = %{new_state |
          current_round: target_round,
          round_change_votes: Map.delete(new_round_change_map, target_round)
        }

        # con il consenso della rete, possiamo far ripartire il giro
        {:noreply, start_round(final_state)}
      else
        {:noreply, new_state}
      end
    else
      # ignora voti per altezze passate o round vecchi
      {:noreply, state}
    end
  end

  def handle_info({:verified_round_change, _, _, validator_id, false}, state), do: ignore_bad_sig(validator_id, state)



  # FASE 1: PRE-PREPARE (proposta del leader)

  defp propose_block(state) do
   payload = %{flag: "prepare_block", node_id: Node.self(), current_height: state.current_height}
    block_data_and_signature = send_to_python_service(payload, state.python_host, state.python_port)

    case block_data_and_signature do
      %{} ->
        Logger.warning("Nessun blocco da proporre al momento. (Nessuna transazione in coda, crash del nodo o comportamento bizantino del Proposer)")
        state

      %{"block_data" => block_data, "proposer_sign" => signature} ->
        Logger.info("Proponendo nuovo blocco: #{inspect(block_data_and_signature)}")
        msg = {:pre_prepare, state.current_height, state.current_round, state.node_id, block_data, signature}
        broadcast_to_all(state.peers, msg)
        # IL LEADER SALVA IL BLOCCO E SI AUTOVOTA SUBITO
        new_votes = MapSet.put(state.prepare_votes, state.node_id)

        # Restituisce lo stato aggiornato
        %{state |
          pending_block: block_data,
          temporary_signature: signature,
          prepare_votes: new_votes
        }
    end
  end


@impl true
def handle_cast({:pre_prepare, height, round, proposer_id, block_data, signature}) do

  payload = %{
    "flag" => "pre_prepare",
    "height" => height,
    "round" => round,
    "proposer_id" => proposer_id,
    "block_data" => block_data,
    "signature" => signature
  }


  Task.start(fn ->
    is_valid = send_to_python_service(payload, state.python_host, state.python_port)

    if is_valid["status"] do
      expected_proposer = Enum.at(state.validators, rem(height + round, length(state.validators)))


      if proposer_id == expected_proposer do

        # È DA CAMBIARE QUESTO E SPOSTARLO SULLA FUNZIONE PREPARE (BISOGNA FARE IL CONTROLLO TRAMITE HASH DEL BLOCCO)
        # CONTROLLO SU PENDING BLOCK
        if state.pending_block != nil do
          # Creiamo un nuovo payload aggiornato:
          conflict_payload =
            payload
            |> Map.put("flag", "pre_prepare_conflict")
            |> Map.put("conflicting_block", state.pending_block)
            |> Map.put("conflicting_signature", state.temporary_signature)

          proof = send_to_python_service(conflict_payload, state.python_host, state.python_port)

          if proof["status"] do
            msg = {:round_change, %{
              "flag" => "round_change",
              "height" => height,
              "target_round" => round + 1,
              "validator_id" => state.node_id,
              "conflicting_block" => state.pending_block, # Corretto: mancava "state."
              "conflicting_signature" => state.temporary_signature,
              "forged_block" => block_data,
              "forged_signature" => signature,
              validator_signature: proof["validator_signature"]
            }}

            broadcast_to_all(state.peers, msg)
            Logger.warning("Conflitto di blocco rilevato da #{proposer_id}. Avvio ROUND_CHANGE verso il round #{round + 1}")
          end

        else
          # ESEGUITO SOLO SE pending_block == nil
          send(engine_pid, {:verified_pre_prepare, height, round, proposer_id, block_data, is_valid["status"]})
        end

      end
    else
      send(engine_pid, {:verified_pre_prepare, height, round, proposer_id, block_data, is_valid["status"]})

    end
  end)

  # Questo è fondamentale: handle_cast deve finire ritornando {:noreply, state}
  {:noreply, state}
end


  @impl true
  def handle_info({:verified_pre_prepare, height, round, proposer_id, block_data, true}, state) do
    # verifica che la proposta sia per l'altezza corrente e dal vero Proposer deterministico
    expected_proposer = Enum.at(state.validators, rem(height + round, length(state.validators)))

    # controllo di: altezza blockchain, round corrente e che il proposer sia quello atteso
    if height == state.current_height and round == state.current_round and proposer_id == expected_proposer do
      Logger.info("Pre-Prepare valido da #{proposer_id}. Avvio fase PREPARE.")

      # invia broadcast a tutti che si è d'accordo
      payload = %{"flag" => "prepare", "height" => height, "round" => round, "validator_id" => state.node_id, "block_data" => block_data}
      signature = send_to_python_service(payload, state.python_host, state.python_port)

      case signature do
        %{"signature" => signature} ->
          msg = {:prepare, height, round, state.node_id, signature}
          broadcast_to_all(state.peers, msg)

          # AGGIUNGE IMMEDIATAMENTE IL PROPRIO VOTO ALLO STATO LOCALE
          new_votes = MapSet.put(state.prepare_votes, state.node_id)

          # aggiorna lo stato
          {:noreply, %{state |
            pending_block: block_data,
            temporary_signature: my_signature,
            prepare_votes: new_votes # <- Stato aggiornato col proprio voto
          }}

        _ ->
          Logger.warning("Errore nella componente python")
          {:noreply, state}
    else
      {:noreply, state}
    end
  end
end
  def handle_info({:verified_pre_prepare, _, _, proposer_id, _, false}, state), do: ignore_bad_sig(proposer_id, state)


  # FASE 2: PREPARE (verifica broadcast)

  @impl true
  def handle_cast({:prepare, height, round, validator_id, signature}) do
    if height == state.current_height and round == state.current_round do
      payload = %{"flag" => "verified_prepare", "height" => height, "round" => round, "validator_id" => validator_id, "signature" => signature}

      Task.start(fn ->
        is_valid = send_to_python_service(payload, state.python_host, state.python_port)
        send(engine_pid, {:verified_prepare, height, round, validator_id, is_valid["status"]})
      end)
    end

    {:noreply, state}
  end
  end

  @impl true
  def handle_info({:verified_prepare, height, round, validator_id, true}, state) do
    if height == state.current_height and round == state.current_round do
      new_votes = MapSet.put(state.prepare_votes, validator_id)

      # se raggiungiamo il Quorum (2f + 1) e non avevamo ancora committato
      if MapSet.size(new_votes) >= state.quorum do
        Logger.info("Quorum PREPARE raggiunto! Avvio fase COMMIT.")

        # COMMIT
        payload = %{"flag" => "commit", "height" => height, "round" => round, "validator_id" => state.node_id}
        signature = send_to_python_service(payload, state.python_host, state.python_port)


        msg = {:commit, height, round, state.node_id, signature["signature"]}
        broadcast_to_all(state.peers, msg)

        # IL NODO AGGIUNGE SUBITO IL PROPRIO VOTO DI COMMIT
        new_commit_votes = MapSet.put(state.commit_votes, state.node_id)

        {:noreply, %{state |
          prepare_votes: new_prepare_votes,
          commit_votes: new_commit_votes
        }}
      else
        {:noreply, %{state | prepare_votes: new_votes}}
      end

    else
      {:noreply, state} # messaggio obsoleto
    end
  end
  def handle_info({:verified_prepare, _, _, validator_id, false}, state), do: ignore_bad_sig(validator_id, state)


  # FASE 3: COMMIT (finalizzazione)

  @impl true
  def handle_cast({:commit, height, round, validator_id, signature}, state) do
    if height == state.current_height and round == state.current_round and validator_id != state.node_id do
    engine_pid = self()
    payload = %{"flag" => "verified_commit", "height" => height, "round" => round, "validator_id" => validator_id, "signature" => signature}

    Task.start(fn ->
      is_valid = send_to_python_service(payload, state.python_host, state.python_port)
      send(engine_pid, {:verified_commit, height, round, validator_id, is_valid["status"]})
    end)
  end
    {:noreply, state}
  end

  @impl true
  def handle_info({:verified_commit, height, round, validator_id, true}, state) do
    if height == state.current_height and round == state.current_round do
      new_votes = MapSet.put(state.commit_votes, validator_id)

      if MapSet.size(new_votes) >= state.quorum do
        Logger.info("BLOCCO #{height} COMMITTATO!")

        # scrittura del blocco sul servizio Python (simulazione di scrittura su DB)
        payload = %{"flag" => "write_block", "height" => height, "block_data" => state.pending_block}
        case Task.start(fn ->
        result = send_to_python_service(payload, state.python_host, state.python_port)

        case result do
         %{"status" => true} ->
           Logger.info("Blocco #{height} scritto correttamente sul servizio Python.")

         %{"status" => false} ->
           Logger.error("Errore nella scrittura del blocco #{height} sul servizio Python.")

         other ->
           Logger.error("Risposta inattesa scrivendo il blocco #{height}: #{inspect(other)}")
       end
     end)

        # si passa al prossimo blocco, resettando il round a 0
        new_state = %{state |
          current_height: state.current_height + 1,
          current_round: 0,
          pending_block: nil,
          temporary_signature: nil,
          prepare_votes: MapSet.new(), # Assicurati di svuotare i set per il blocco successivo
          commit_votes: MapSet.new()   # Svuota i set per il blocco successivo
        }
        {:noreply, start_round(new_state)}
      else
        {:noreply, %{state | commit_votes: new_votes}}
      end
    else
      {:noreply, state}
    end
  end
  def handle_info({:verified_commit, _, _, validator_id, false}, state), do: ignore_bad_sig(validator_id, state)




  # Funzioni di supporto

  defp ignore_bad_sig(node_id, state) do
    Logger.error("Firma invalida da #{node_id}. Possibile nodo Bizantino!")
    {:noreply, state}
  end

  defp broadcast_to_all(peers, message) do
    GenServer.cast(__MODULE__, message)

    data = :erlang.term_to_binary(message)
    Enum.each(peers, fn {peer_id, {host, port}} ->
      case Task.start(fn -> send_tcp(peer_id, host, port, data) end) do
        {:ok, _pid} ->
          :ok

        {:error, reason} ->
          Logger.error("Impossibile avviare l'invio al peer #{peer_id}: #{inspect(reason)}")
      end
    end)

    :ok
  end

  defp send_tcp(peer_id, host, port, binary_data) do
    case :gen_tcp.connect(host, port, [:binary, active: false], 1000) do
      {:ok, socket} ->
        result = :gen_tcp.send(socket, binary_data)
        :gen_tcp.close(socket)

        case result do
          :ok -> :ok
          {:error, reason} ->
            Logger.warning("Invio del messaggio al peer #{peer_id} fallito: #{inspect(reason)}")
        end

      {:error, reason} ->
        Logger.warning("Connessione al peer #{peer_id} fallita: #{inspect(reason)}")
    end
  end

  defp parse_peers(peers_env) do
    (peers_env || "")
    |> String.split(",", trim: true)
    |> Enum.into(%{}, fn peer ->
      [host, port] = String.split(String.trim(peer), ":")
      {host, {String.to_charlist(host), String.to_integer(port)}}
    end)
  end



  defp send_to_python_service(payload, py_host, py_port) do
    case :gen_tcp.connect(py_host, py_port, [:binary, active: false], 2000) do
      {:ok, socket} ->
        :gen_tcp.send(socket, JSON.encode!(payload))
        result = case :gen_tcp.recv(socket, 0, 2000) do
          {:ok, response_json} ->
            case JSON.decode(response_json) do
              {:ok, parsed_response} -> parsed_response
              {:error, reason} ->
                Logger.error("Errore nel parsing della risposta JSON dal servizio Python: #{inspect(reason)}")
                false
            end
          {:error, reason} ->
            Logger.error("Errore di lettura dal servizio Python: #{inspect(reason)}")
            false
        end
        :gen_tcp.close(socket)
        result
      _ -> false
    end
  end
