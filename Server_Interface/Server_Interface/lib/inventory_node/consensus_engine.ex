defmodule InventoryNode.ConsensusEngine do
  use GenServer
  require Logger

  @round_timeout 5000 # Tempo massimo per chiudere un blocco prima di cambiare Proposer

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
      current_height: 1,      # Numero del blocco
      current_round: 0,       # Tentativo corrente per questa altezza
      timer_ref: nil,

      # Accumulatori per le fasi BFT
      prepare_votes: MapSet.new(),
      commit_votes: MapSet.new(),

      # Dati del blocco in lavorazione
      pending_block: nil
    }

    Logger.info("BFT-PoA Avviato. Nodo: #{node_id}. Quorum: #{quorum}/#{total_nodes}")
    {:ok, start_round(state)}
  end


  # GESTIONE DEL ROUND E PROPOSER (ROUND-ROBIN)


  defp start_round(state) do
    if state.timer_ref, do: Process.cancel_timer(state.timer_ref)
    timer_ref = Process.send_after(self(), :round_timeout, @round_timeout)

    # Il proposer è deterministico: (Altezza + Round) mod numero totale di nodi
    proposer_index = rem(state.current_height + state.current_round, length(state.validators))
    current_proposer = Enum.at(state.validators, proposer_index)

    # Pulisce i voti del round precedente
    new_state = %{state |
      timer_ref: timer_ref,
      prepare_votes: MapSet.new(),
      commit_votes: MapSet.new(),
      pending_block: nil
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
    Logger.warning("Timeout blocco #{state.current_height}. Avvio Round Change a #{state.current_round + 1}")
    # Se il proposer è collassato o bizantino, si incrementa il round e si passa al prossimo
    new_state = %{state | current_round: state.current_round + 1}
    {:noreply, start_round(new_state)}
  end

  # FASE 1: PRE-PREPARE (proposta del leader)


  defp propose_block(state) do
   msg = %{flag: "prepare_block", node_id: Node.self()}
    block_data = send_to_python_service(msg, state.python_host, state.python_port)

    payload = %{
      "flag" => "pre_prepare",
      "height" => state.current_height,
      "round" => state.current_round,
      "proposer_id" => state.node_id,
      "block" => block_data
    }

    signature = send_to_python_service(payload, state.python_host, state.python_port)
    msg = {:pre_prepare, state.current_height, state.current_round, state.node_id, block_data, signature}

    # Invia a TUTTI
    broadcast_to_all(state.peers, state.node_id, msg)
    state
  end

  @impl true
  def handle_cast({:pre_prepare, height, round, proposer_id, block_data, signature}, state) do
    engine_pid = self()
    payload = %{"flag" => "pre_prepare", "height" => height, "round" => round, "proposer_id" => proposer_id, "block" => block_data, "signature" => signature, "proposer_id" => proposer_id}

    # Verifica la firma asincronamente
    Task.start(fn ->
      is_valid = send_to_python_service(payload, state.python_host, state.python_port)
      send(engine_pid, {:verified_pre_prepare, height, round, proposer_id, block_data, is_valid})
    end)
    {:noreply, state}
  end

  @impl true
  def handle_info({:verified_pre_prepare, height, round, proposer_id, block_data, true}, state) do
    # Verifica che la proposta sia per l'altezza corrente e dal vero Proposer deterministico
    expected_proposer = Enum.at(state.validators, rem(height + round, length(state.validators)))

    if height == state.current_height and round == state.current_round and proposer_id == expected_proposer do
      Logger.info("Pre-Prepare valido da #{proposer_id}. Avvio fase PREPARE.")

      # invia broadcast a TUTTI che si è d'accordo
      payload = %{"flag" => "prepare", "height" => height, "round" => round, "validator_id" => state.node_id}
      signature = send_to_python_service(payload, state.python_host, state.python_port)

      msg = {:prepare, height, round, state.node_id, signature}
      broadcast_to_all(state.peers, state.node_id, msg)

      {:noreply, %{state | pending_block: block_data}}
    else
      {:noreply, state}
    end
  end
  def handle_info({:verified_pre_prepare, _, _, proposer_id, _, false}, state), do: ignore_bad_sig(proposer_id, state)


  # FASE 2: PREPARE (verifica broadcast)

  @impl true
  def handle_cast({:prepare, height, round, validator_id, signature}, state) do
    engine_pid = self()
    payload = %{"flag" => "prepare", "height" => height, "round" => round, "validator_id" => validator_id, "signature" => signature}

    Task.start(fn ->
      is_valid = send_to_python_service(payload, state.python_host, state.python_port)
      send(engine_pid, {:verified_prepare, height, round, validator_id, is_valid})
    end)
    {:noreply, state}
  end

  @impl true
  def handle_info({:verified_prepare, height, round, validator_id, true}, state) do
    if height == state.current_height and round == state.current_round do
      new_votes = MapSet.put(state.prepare_votes, validator_id)

      # se raggiungiamo il Quorum (2f + 1) e non avevamo ancora committato
      if MapSet.size(new_votes) == state.quorum do
        Logger.info("Quorum PREPARE raggiunto! Avvio fase COMMIT.")

        # COMMIT
        payload = %{"flag" => "commit", "height" => height, "round" => round, "validator_id" => state.node_id}
        signature = send_to_python_service(payload, state.python_host, state.python_port)

        msg = {:commit, height, round, state.node_id, signature}
        broadcast_to_all(state.peers, state.node_id, msg)
      end

      {:noreply, %{state | prepare_votes: new_votes}}
    else
      {:noreply, state} # messaggio obsoleto
    end
  end
  def handle_info({:verified_prepare, _, _, validator_id, false}, state), do: ignore_bad_sig(validator_id, state)


  # FASE 3: COMMIT (finalizzazione)

  @impl true
  def handle_cast({:commit, height, round, validator_id, signature}, state) do
    engine_pid = self()
    payload = %{"flag" => "commit", "height" => height, "round" => round, "validator_id" => validator_id, "signature" => signature}

    Task.start(fn ->
      is_valid = send_to_python_service(payload, state.python_host, state.python_port)
      send(engine_pid, {:verified_commit, height, round, validator_id, is_valid})
    end)
    {:noreply, state}
  end

  @impl true
  def handle_info({:verified_commit, height, round, validator_id, true}, state) do
    if height == state.current_height and round == state.current_round do
      new_votes = MapSet.put(state.commit_votes, validator_id)

      if MapSet.size(new_votes) == state.quorum do
        Logger.info("BLOCCO #{height} COMMITTATO!")

        # scrittura del blocco sul servizio Python (simulazione di scrittura su DB)
        payload = %{"flag" => "write_block", "height" => height, "block_data" => state.pending_block}
        case send_to_python_service(payload, state.python_host, state.python_port) do
          true -> Logger.info("Blocco #{height} scritto correttamente sul servizio Python.")
          false -> Logger.error("Errore nella scrittura del blocco #{height} sul servizio Python.")
        end

        # si passa al prossimo blocco, resettando il round a 0
        new_state = %{state |
          current_height: state.current_height + 1,
          current_round: 0
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

  # --- Funzioni di Supporto Rete e Python ---

  defp ignore_bad_sig(node_id, state) do
    Logger.error("Firma invalida da #{node_id}. Possibile nodo Bizantino!")
    {:noreply, state}
  end

  defp broadcast_to_all(peers, self_id, message) do
    GenServer.cast(__MODULE__, message)

    data = :erlang.term_to_binary(message)
    Enum.each(peers, fn {_peer_id, {host, port}} ->
      send_tcp(host, port, data)
    end)
  end

  defp send_tcp(host, port, binary_data) do
    case :gen_tcp.connect(host, port, [:binary, active: false], 1000) do
      {:ok, socket} ->
        :gen_tcp.send(socket, binary_data)
        :gen_tcp.close(socket)
      _ -> :ok
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
        :gen_tcp.send(socket, Jason.encode!(payload))
        result = case :gen_tcp.recv(socket, 0, 2000) do
          {:ok, response_json} ->
            case Jason.decode(response_json) do
              {:ok, %{"status" => "valid"}} -> true


              _ -> false
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
end
