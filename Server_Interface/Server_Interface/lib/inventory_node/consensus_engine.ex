defmodule InventoryNode.ConsensusEngine do
  use GenServer
  require Logger

  @min_election_timeout 1500
  @max_election_timeout 3000
  @heartbeat_interval 500


  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, opts ++ [name: __MODULE__])
  end

  def handle_vote_request(term, candidate_id, signature) do
    GenServer.cast(__MODULE__, {:request_vote, term, candidate_id, signature})
  end

  def handle_vote_granted(term) do
    GenServer.cast(__MODULE__, {:vote_granted, term})
  end

  def handle_append_entries(term, leader_id) do
    GenServer.cast(__MODULE__, {:append_entries, term, leader_id})
  end


  @impl true
  def init(:ok) do
    # Lettura delle variabili d'ambiente da Docker Compose
    node_id = System.get_env("NODE_ID")
    python_host = System.get_env("PYTHON_HOST") |> String.to_charlist()
    python_port = System.get_env("PYTHON_PORT") |> String.to_integer()

    # e parsing della stringa PEERS
    peers = parse_peers(System.get_env("PEERS"))


    # Per tolleranza BFT standard a 1 nodo guasto/bizantino (f=1), servono 3f+1 nodi (4).
    # La maggioranza richiesta per vincere è 3.
    total_nodes = map_size(peers) + 1
    majority = 3 # Su 4 nodi, la maggioranza qualificata BFT è 3


    state = %{
      node_id: node_id,
      peers: peers,
      python_host: python_host,
      python_port: python_port,
      majority: majority,
      role: :follower,
      current_term: 0,
      voted_for: nil,
      votes_received: 0,
      leader_id: nil,
      timer_ref: nil
    }

    Logger.info("Nodo #{node_id} avviato. BFT Majority: #{majority}. Peers: #{inspect(Map.keys(peers))}")
    {:ok, reset_election_timer(state)}
  end

  # gestione dei messaggi asincroni (timeout, heartbeat, ecc.)

  @impl true
  def handle_info(:election_timeout, state) do
    new_term = state.current_term + 1
    Logger.info("Timeout! #{state.node_id} diventa Candidate per il Term #{new_term}")

    new_state = %{
      state |
      role: :candidate,
      current_term: new_term,
      voted_for: state.node_id,
      votes_received: 1,
      leader_id: nil
    }

    # Firma e invia la richiesta di voto a tutti gli altri container
    signature = sign_payload({:request_vote, new_term, state.node_id}, state.node_id)
    broadcast_to_peers(state.peers, {:request_vote, new_term, state.node_id, signature})

    {:noreply, reset_election_timer(new_state)}
  end

  @impl true
  def handle_info(:send_heartbeat, %{role: :leader} = state) do
    # Invia heartbeat in broadcast
    broadcast_to_peers(state.peers, {:append_entries, state.current_term, state.node_id})
    timer_ref = Process.send_after(self(), :send_heartbeat, @heartbeat_interval)
    {:noreply, %{state | timer_ref: timer_ref}}
  end
  def handle_info(:send_heartbeat, state), do: {:noreply, state}

  # --- Logica di Consenso e Gestione Bizantina (Task Asincroni) ---

  @impl true
  def handle_cast({:request_vote, candidate_term, candidate_id, signature}, state) do
    engine_pid = self()
    payload = {:request_vote, candidate_term, candidate_id}

    # Task asincrono: chiede a Python nel container 'python_validator' di verificare
    Task.start(fn ->
      is_valid = verify_with_python(payload, signature, candidate_id, state.python_host, state.python_port)
      send(engine_pid, {:signature_verified, candidate_id, candidate_term, is_valid})
    end)

    {:noreply, state}
  end

  @impl true
  def handle_info({:signature_verified, candidate_id, candidate_term, true}, state) do
    cond do
      candidate_term < state.current_term ->
        {:noreply, state}

      candidate_term > state.current_term ->
        Logger.info("Firma di #{candidate_id} valida. Voto concesso.")
        send_to_peer(state.peers, candidate_id, {:vote_granted, candidate_term})
        new_state = %{state | role: :follower, current_term: candidate_term, voted_for: candidate_id}
        {:noreply, reset_election_timer(new_state)}

      state.voted_for in [nil, candidate_id] ->
        send_to_peer(state.peers, candidate_id, {:vote_granted, candidate_term})
        {:noreply, reset_election_timer(%{state | voted_for: candidate_id})}

      true -> {:noreply, state}
    end
  end

  @impl true
  def handle_info({:signature_verified, candidate_id, _term, false}, state) do
    Logger.warning("Firma NON VALIDA o errore validatore da #{candidate_id}. Rifiuto.")
    {:noreply, state}
  end

  @impl true
  def handle_cast({:vote_granted, term}, %{role: :candidate, current_term: current_term} = state)
      when term == current_term do

    votes = state.votes_received + 1

    if votes >= state.majority do
      Logger.info("MAGGIORANZA (#{votes}/#{state.majority}) RAGGIUNTA! #{state.node_id} è il Leader (Term #{current_term})")

      if state.timer_ref, do: Process.cancel_timer(state.timer_ref)
      timer_ref = Process.send_after(self(), :send_heartbeat, 0)

      {:noreply, %{state | role: :leader, votes_received: votes, timer_ref: timer_ref, leader_id: state.node_id}}
    else
      {:noreply, %{state | votes_received: votes}}
    end
  end
  def handle_cast({:vote_granted, _}, state), do: {:noreply, state}

  @impl true
  def handle_cast({:append_entries, leader_term, leader_id}, state) do
    if leader_term >= state.current_term do
      new_state = %{
        state |
        role: :follower,
        current_term: leader_term,
        leader_id: leader_id
      }
      {:noreply, reset_election_timer(new_state)}
    else
      {:noreply, state}
    end
  end


  # --- Funzioni di supporto ---

  defp reset_election_timer(state) do
    if state.timer_ref, do: Process.cancel_timer(state.timer_ref)
    timeout = Enum.random(@min_election_timeout..@max_election_timeout)
    timer_ref = Process.send_after(self(), :election_timeout, timeout)
    %{state | timer_ref: timer_ref}
  end

  defp parse_peers(peers_env) do

    (peers_env || "")
    |> String.split(",", trim: true)
    |> Enum.into(%{}, fn peer ->
      [host, port] = String.split(String.trim(peer), ":")
      {host, {String.to_charlist(host), String.to_integer(port)}}
    end)
  end

  defp broadcast_to_peers(peers, message) do
    data = :erlang.term_to_binary(message)
    Enum.each(peers, fn {_peer_id, {host, port}} ->
      send_tcp(host, port, data)
    end)
  end

  defp send_to_peer(peers, peer_id, message) do
    # Dato l'ID del nodo (es "node_b"), recupera l'host e la porta e invia
    case Map.fetch(peers, peer_id) do
      {:ok, {host, port}} ->
        send_tcp(host, port, :erlang.term_to_binary(message))
      :error ->
        Logger.error("Peer #{peer_id} sconosciuto.")
    end
  end

  defp send_tcp(host, port, binary_data) do
    # Connessione usa-e-getta per l'invio del messaggio a un altro nodo Elixir
    case :gen_tcp.connect(host, port, [:binary, active: false], 1000) do
      {:ok, socket} ->
        :gen_tcp.send(socket, binary_data)
        :gen_tcp.close(socket)
      _ -> :ok
    end
  end

  defp verify_with_python(payload, signature, node_id, py_host, py_port) do
    request = %{action: "verify", payload: payload, signature: signature, node_id: node_id}

    case :gen_tcp.connect(py_host, py_port, [:binary, active: false], 2000) do
      {:ok, socket} ->
        :gen_tcp.send(socket, Jason.encode!(request))
        result = case :gen_tcp.recv(socket, 0, 2000) do
          {:ok, "valid"} -> true
          _ -> false
        end
        :gen_tcp.close(socket)
        result
      {:error, _} ->
        false
    end
  end

  defp sign_payload(_payload, _node_id) do
    # Qui implementerai la logica (o la chiamata a un tool crittografico)
    # per firmare il payload con la chiave privata del nodo.
    "firma_fittizia_base64"
  end
end
