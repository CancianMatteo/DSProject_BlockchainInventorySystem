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
    (peers_env || "")
    |> String.split(",", trim: true)
    |> Enum.into(%{}, fn peer ->
      [host, port] = String.split(String.trim(peer), ":")
      {host, {String.to_charlist(host), String.to_integer(port)}}
    end)
  end

  # ---------------------------------------------------------------------------
  # Dispatch
  # ---------------------------------------------------------------------------

  def handle_payload(payload) do
    python_host = python_host()
    python_port = python_port()
    peers = parse_peers(System.get_env("PEERS"))

    case payload do

       # TRANSACTION OPERATION
    %{
      "flag" => "transaction",
      "from_node" => from_node,
      "tx_type" => tx_type,
      "item_id" => item_id,
      "quantity" => quantity,
      "location" => location,
      "timestamp" => timestamp,
      "tx_id" => tx_id
    } ->
        IO.puts("richiesta di transazione: #{quantity} unità dell'oggetto #{item_id} nel magazzino #{location}")
        # logica da gestere in mempool python
        transaction = send_to_python_service(%{
          "flag" => "transaction",
          "from_node" => from_node,
          "tx_type" => tx_type,
          "item_id" => item_id,
          "quantity" => quantity,
          "location" => location,
          "timestamp" => timestamp,
          "tx_id" => tx_id
        }, python_host, python_port)

        case transaction do
          {:ok, tx} ->
            my_id = node_id()
            # Inonda la transazione solo se proviene da un nodo esterno a questo
            # gruppo E la mempool Python l'ha effettivamente inserita (il campo
            # "duplicate" impedisce i loop di re-inoltro tra i nodi).
            if tx["duplicate"] != true and tx["from_node"] != my_id and tx["from_node"] not in Map.keys(peers) do
              tx2 = tx |> Map.put("from_node", my_id) |> Map.delete("duplicate")
              broadcast_to_peers(peers, tx2)
            end

          {:error, reason} ->
            Logger.error("Invio transazione a Python fallito: #{inspect(reason)}")
        end


       # KEYS SETUP OPERATION
    {:setup_keys} ->
      IO.puts("Setup delle chiavi pubbliche e private per la crittografia")
      case send_to_python_service(%{"flag" => "setup_keys", "from_node" => node_id()}, python_host, python_port) do
        {:ok, %{"flag" => "setup_keys", "pub_key" => pub_key}} ->
            broadcast_to_peers(peers, {:setup_keys_warning, node_id(), pub_key})

        {:ok, %{"flag" => "error", "reason" => reason}} ->
              {:error, reason}

        {:ok, _} ->
              {:error, "Risposta Python malformata"}

        {:error, reason} ->
              {:error, reason}
      end

        # KEYS SETUP WARNING OPERATION
    {:setup_keys_warning, from_node, pub_key} ->
      IO.puts("Ricevuto avviso di setup chiavi da #{inspect(from_node)}")
      case send_to_python_service(%{"flag" => "setup_keys_warning", "from_node" => to_string(from_node), "pub_key" => pub_key}, python_host, python_port) do
        {:ok, %{"flag" => "setup_keys_warning", "status" => "success"}} ->
          IO.puts("Chiave pubblica del nodo #{inspect(from_node)} registrata correttamente.")

        {:ok, %{"flag" => "error", "reason" => reason}} ->
              {:error, reason}

        {:ok, _} ->
              {:error, "Risposta Python malformata"}

        {:error, reason} ->
              {:error, reason}
      end


     # ROUND CHANGE OPERATION
    {:round_change, round_payload} ->
      GenServer.cast(InventoryNode.ConsensusEngine, {:round_change, round_payload})


     # CONSENSUS OPERATIONS
    {:pre_prepare, height, round, proposer_id, block_data, signature} ->
      GenServer.cast(InventoryNode.ConsensusEngine, {:pre_prepare, height, round, proposer_id, block_data, signature})


    {:prepare, height, round, validator_id, signature} ->
      GenServer.cast(InventoryNode.ConsensusEngine, {:prepare, height, round, validator_id, signature})


    {:commit, height, round, validator_id, signature} ->
      GenServer.cast(InventoryNode.ConsensusEngine, {:commit, height, round, validator_id, signature})


   #CATCH ALL
  other ->
     IO.puts("Payload non riconosciuto: #{inspect(other)}")
   end
 end

  # Funzioni di supporto

  defp send_to_python_service(payload, py_host, py_port) do
    InventoryNode.PythonClient.call(payload, py_host, py_port)
  end


  defp broadcast_to_peers(peers, message) do
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
        # Il ClusterListener riceve con `packet: 4`: prepone il header di lunghezza.
        framed = <<byte_size(binary_data)::32-big, binary_data::binary>>
        result = :gen_tcp.send(socket, framed)
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

end