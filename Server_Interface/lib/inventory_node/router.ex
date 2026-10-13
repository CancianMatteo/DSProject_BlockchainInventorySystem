defmodule InventoryNode.Router do



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
        transaction =send_to_python_service(%{
          "flag" => "transaction",
          "from_node" => from_node,
          "tx_type" => tx_type,
          "item_id" => item_id,
          "quantity" => quantity,
          "location" => location,
          "timestamp" => timestamp,
          "tx_id" => tx_id
        }, python_host, python_port)

        if transaction["from_node"] not in Map.keys(peers) do
          transaction = Map.put(transaction, "from_node", Node.self())
          broadcast_to_peers(peers, transaction)
        end



       # KEYS SETUP OPERATION
    {:setup_keys} ->
      IO.puts("Setup delle chiavi pubbliche e private per la crittografia")
      case send_to_python_service(%{flag: "setup_keys", from_node: Node.self()}, python_host, python_port) do
        %{"flag" => "setup_keys", "pub_key" => pub_key} ->
            broadcast_to_peers(peers, {:setup_keys_warning, Node.self(), pub_key})

        %{"flag" => "error", "reason" => reason} ->
              {:error, reason}

            _ ->
              {:error, "Risposta Python malformata"}
        end

        # KEYS SETUP WARNING OPERATION
    {:setup_keys_warning, from_node, pub_key} ->
      IO.puts("Ricevuto avviso di setup chiavi da #{inspect(from_node)}")
      case send_to_python_service(%{flag: "setup_keys_warning", from_node: from_node, pub_key: pub_key}, python_host, python_port) do
        %{"flag" => "setup_keys_warning", "status" => "success"} ->
          IO.puts("Chiave pubblica del nodo #{inspect(from_node)} registrata correttamente.")

        %{"flag" => "error", "reason" => reason} ->
              {:error, reason}

            _ ->
              {:error, "Risposta Python malformata"}
        end


    #     # NEW BLOCK REQUEST OPERATION
    # %{"flag" => "new_block_req", "block_data" => block_data, "signature" => signature} ->
    #   IO.puts("Ricevuta richiesta di nuovo blocco: #{inspect(block_data)}")
    #   case send_to_python_service(%{flag: "new_block_req", block_data: block_data}, python_host, python_port) do
    #     {:ok, response} ->
    #       IO.puts("Risposta dal servizio Python: #{inspect(response)}")
    #       response

    #     {:error, reason} ->
    #       IO.puts("Errore dal servizio Python: #{inspect(reason)}")
    #     end


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
    case :gen_tcp.connect(py_host, py_port, [:binary, active: false], 2000) do
      {:ok, socket} ->
        :gen_tcp.send(socket, Jason.encode!(payload))
        result = case :gen_tcp.recv(socket, 0, 2000) do
          {:ok, response_json} ->
            case Jason.decode(response_json) do
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
