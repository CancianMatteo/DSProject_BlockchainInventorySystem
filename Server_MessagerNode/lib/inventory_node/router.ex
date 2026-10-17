defmodule InventoryNode.Router

  def handle_payload(payload) do
    python_host = System.get_env("PYTHON_HOST") |> String.to_charlist()
    python_port = System.get_env("PYTHON_PORT") |> String.to_integer()
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
        # logica da gestire in mempool python
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
            if tx["from_node"] not in Map.keys(peers) do
              tx2 = Map.put(tx, "from_node", Node.self())
              broadcast_to_peers(peers, tx2)
            end

          {:error, reason} ->
            Logger.error("Invio transazione a Python fallito: #{inspect(reason)}")
        end


       # KEYS SETUP OPERATION
    {:setup_keys} ->
      IO.puts("Setup delle chiavi pubbliche e private per la crittografia")
      case send_to_python_service(%{flag: "setup_keys", from_node: Node.self()}, python_host, python_port) do
        {:ok, %{"flag" => "setup_keys", "pub_key" => pub_key}} ->
            broadcast_to_peers(peers, {:setup_keys_warning, Node.self(), pub_key})

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
      case send_to_python_service(%{flag: "setup_keys_warning", from_node: from_node, pub_key: pub_key}, python_host, python_port) do
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
    {:round_change, payload} ->
      InventoryNode.ConsensusEngine.handle_cast({:round_change, payload})


    # CONSENSUS OPERATIONS
    {:pre_prepare, height, round, block_data_and_signatures} ->
      InventoryNode.ConsensusEngine.handle_cast({:pre_prepare, height, round, block_data_and_signatures})


    {:prepare, height, round, node_id, signature} ->
      InventoryNode.ConsensusEngine.handle_cast({:prepare, height, round, node_id, signature})


    {:commit, height, round, node_id, signature} ->
      InventoryNode.ConsensusEngine.handle_cast({:commit, height, round, node_id, signature})



   #CATCH ALL
  {_, _} ->
     IO.puts("Payload non riconosciuto: #{inspect(payload)}")
   end
 end

  # Funzioni di supporto
  defp send_to_python_service(payload, py_host, py_port) do
    InventoryNode.PythonClient.call(payload, py_host, py_port)
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

end
