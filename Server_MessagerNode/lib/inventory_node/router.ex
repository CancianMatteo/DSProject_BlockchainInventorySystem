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
    # Supported formats: "id@host:port" (host differs from the ID, for
    # multi-VPS deployments with public IPs) and "host:port" (the ID matches
    # the host, as in local Docker Compose deployments).
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
    # In noresponse mode, this node does not respond to any peer.
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
          "Transaction request: #{Map.get(transaction, "quantity")} units " <>
            "of item #{Map.get(transaction, "item_id")} at location " <>
            "#{Map.get(transaction, "location")}"
        )

        relay_node = Map.get(transaction, "relay_node")
        python_transaction = Map.delete(transaction, "relay_node")
        result = send_to_python_service(python_transaction, python_host, python_port)

        case result do
          {:ok, tx} ->
            my_id = node_id()
            # relay_node is unsigned and is removed before sending the request to Python.
            if tx["duplicate"] != true and relay_node not in Map.keys(peers) do
              broadcast_to_peers(peers, Map.put(python_transaction, "relay_node", my_id))
            end

          {:error, reason} ->
            Logger.error("Failed to forward transaction to Python: #{inspect(reason)}")
        end

      # ROUND CHANGE OPERATION
      {:round_change, round_payload} ->
        GenServer.cast(InventoryNode.ConsensusEngine, {:round_change, round_payload})

      {:finalized_block, package} ->
        GenServer.cast(InventoryNode.ConsensusEngine, {:finalized_block, package})

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
        IO.puts("Unrecognized payload: #{inspect(other)}")
    end
  end

  # Helpers.

  defp send_to_python_service(payload, py_host, py_port) do
    InventoryNode.PythonClient.call(payload, py_host, py_port)
  end

  defp broadcast_to_peers(peers, message) do
    case InventoryNode.SimBehaviour.get() do
      :noresponse ->
        # In noresponse mode, this node does not communicate with peers.
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
        # The ClusterListener uses `packet: 4` and prepends the length header.
        framed = <<byte_size(binary_data)::32-big, binary_data::binary>>
        result = :gen_tcp.send(socket, framed)
        :gen_tcp.close(socket)

        case result do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.warning("Failed to send message to peer #{peer_id}: #{inspect(reason)}")
        end

      {:error, reason} ->
        Logger.warning("Failed to connect to peer #{peer_id}: #{inspect(reason)}")
    end
  end
end
