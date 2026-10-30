defmodule InventoryNode.Router do
  @moduledoc """
  Dispatches payloads received over TCP (Erlang-term framing) from peer nodes.

  Consensus messages are forwarded to `InventoryNode.ConsensusEngine` via
  `GenServer.cast/2` so that `self()` inside the engine callbacks is the
  engine process itself (messages such as `{:verified_*, ...}` are sent back
  to the engine with `send/2`).
  """
  require Logger

  # ---------------------------------------------------------------------------
  # Environment helpers
  # ---------------------------------------------------------------------------

  defp node_id do
    System.get_env("NODE_ID") || "node_a"
  end

  defp python_host do
    (System.get_env("PYTHON_HOST") || "localhost")
    |> String.to_charlist()
  end

  defp python_port do
    (System.get_env("PYTHON_PORT") || "8000")
    |> String.to_integer()
  end

  defp parse_peers(peers_env) do
    # Formati supportati: "id@host:port" (host diverso dall'id, deploy
    # multi-VPS con IP pubblici) e "host:port" (l'id coincide con l'host,
    # come nelle docker-compose locali).
    (peers_env || "")
    |> String.split(",", trim: true)
    |> Enum.into(%{}, fn peer ->
      case String.split(String.trim(peer), "@", parts: 2) do
        [peer_id, host_port] ->
          [host, port] = String.split(host_port, ":", parts: 2)
          {peer_id, {String.to_charlist(host), String.to_integer(port)}}

        [host_port] ->
          [host, port] = String.split(host_port, ":", parts: 2)
          {host, {String.to_charlist(host), String.to_integer(port)}}
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Dispatch
  # ---------------------------------------------------------------------------

  def handle_payload(payload) do
    # Modalità noresponse: il nodo non risponde a nessuno.
    case InventoryNode.SimBehaviour.get() do
      :noresponse -> :ok
      mode -> do_handle_payload(payload, mode)
    end
  end

  defp do_handle_payload(payload, _sim_mode) do
    python_host = python_host()
    python_port = python_port()
    peers = parse_peers(System.get_env("PEERS"))

    case payload do
      # PYTHON BLOCK-TRIGGER OPERATION
      %{"flag" => "trigger_block"} ->
        GenServer.cast(InventoryNode.ConsensusEngine, :trigger_block)

      # TRANSACTION OPERATION
      %{"flag" => "transaction"} = transaction ->
        IO.puts(
          "Richiesta di transazione: #{Map.get(transaction, "quantity")} unità " <>
            "dell'oggetto #{Map.get(transaction, "item_id")} nel magazzino " <>
            "#{Map.get(transaction, "location")}"
        )

        relay_node = Map.get(transaction, "relay_node")
        python_transaction = Map.delete(transaction, "relay_node")
        result = send_to_python_service(python_transaction, python_host, python_port)

        case result do
          {:ok, tx} ->
            my_id = node_id()
            # relay_node non è firmato e viene rimosso prima dell'invio a Python.
            if tx["duplicate"] != true and relay_node not in Map.keys(peers) do
              broadcast_to_peers(peers, Map.put(python_transaction, "relay_node", my_id))
            end

          {:error, reason} ->
            Logger.error("Invio transazione a Python fallito: #{inspect(reason)}")
        end

      # ROUND CHANGE OPERATION
      {:round_change, round_payload} ->
        GenServer.cast(InventoryNode.ConsensusEngine, {:round_change, round_payload})

      # CONSENSUS OPERATIONS
      {:pre_prepare, height, round, proposer_id, block_data, signature} ->
        GenServer.cast(
          InventoryNode.ConsensusEngine,
          {:pre_prepare, height, round, proposer_id, block_data, signature}
        )

      {:prepare_vote, height, round, block_hash, validator_id, signature} ->
        GenServer.cast(
          InventoryNode.ConsensusEngine,
          {:prepare_vote, height, round, block_hash, validator_id, signature}
        )

      {:commit_proposal, height, round, proposer_id, block_data, proposer_signature, signatures} ->
        GenServer.cast(
          InventoryNode.ConsensusEngine,
          {:commit_proposal, height, round, proposer_id, block_data, proposer_signature,
           signatures}
        )

      {:commit_vote, height, round, proposer_id, block_data, proposer_signature,
       prepare_signatures, block_hash, validator_id, signature} ->
        GenServer.cast(
          InventoryNode.ConsensusEngine,
          {:commit_vote, height, round, proposer_id, block_data, proposer_signature,
           prepare_signatures, block_hash, validator_id, signature}
        )

      # CATCH ALL
      other ->
        IO.puts("Payload non riconosciuto: #{inspect(other)}")
    end
  end

  # Funzioni di supporto

  defp send_to_python_service(payload, py_host, py_port) do
    InventoryNode.PythonClient.call(payload, py_host, py_port)
  end

  defp broadcast_to_peers(peers, message) do
    case InventoryNode.SimBehaviour.get() do
      :noresponse ->
        # Modalità noresponse: il nodo non parla con nessuno.
        :ok

      :bizantine ->
        do_broadcast_to_peers(peers, message)

      _ ->
        do_broadcast_to_peers(peers, message)
    end
  end

  defp do_broadcast_to_peers(peers, message) do
    data = :erlang.term_to_binary(message)

    Enum.each(peers, fn {peer_id, {host, port}} ->
      {:ok, _pid} = Task.start(fn -> send_tcp(peer_id, host, port, data) end)
    end)

    :ok
  end

  defp send_tcp(peer_id, host, port, binary_data) do
    case :gen_tcp.connect(host, port, [:binary, active: false], 1000) do
      {:ok, socket} ->
        # Il ClusterListener riceve con `packet: 4`: prepone il header di lunghezza.
        framed = <<byte_size(binary_data)::32-big, binary_data::binary>>
        result = :gen_tcp.send(socket, framed)
        :gen_tcp.close(socket)

        case result do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.warning("Invio del messaggio al peer #{peer_id} fallito: #{inspect(reason)}")
        end

      {:error, reason} ->
        Logger.warning("Connessione al peer #{peer_id} fallita: #{inspect(reason)}")
    end
  end
end
