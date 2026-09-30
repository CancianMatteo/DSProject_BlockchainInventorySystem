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
    {:setup_keys, pub_key} ->
      IO.puts("Setup delle chiavi pubbliche e private per la crittografia")
      case send_to_python_service(%{flag: "setup_keys", from_node: Node.self(), pub_key: pub_key}, python_host, python_port) do
        {:ok, pub_key} ->
          broadcast_to_peers(peers, {:setup_keys_warning, Node.self(), pub_key})

        {:error, reason} ->
          IO.puts("Errore dal servizio Python: #{inspect(reason)}")
        end

        # KEYS SETUP WARNING OPERATION
    {:setup_keys_warning, from_node, pub_key} ->
      IO.puts("Ricevuto avviso di setup chiavi da #{inspect(from_node)}")
      case send_to_python_service(%{flag: "setup_keys_warning", from_node: from_node, pub_key: pub_key}, python_host, python_port) do
        {:ok, pub_key} ->
          IO.puts("Chiave pubblica del nodo #{inspect(from_node)} registrata correttamente.")

        {:error, reason} ->
          IO.puts("Errore dal servizio Python: #{inspect(reason)}")
        end

        # NEW BLOCK REQUEST OPERATION
    %{"flag" => "new_block_req", "block_data" => block_data, "signature" => signature} ->
      IO.puts("Ricevuta richiesta di nuovo blocco: #{inspect(block_data)}")
      case send_to_python_service(%{flag: "new_block_req", block_data: block_data}, python_host, python_port) do
        {:ok, response} ->
          IO.puts("Risposta dal servizio Python: #{inspect(response)}")
          response

        {:error, reason} ->
          IO.puts("Errore dal servizio Python: #{inspect(reason)}")
        end

    end



  #CATCH ALL
  def handle_payload(unknown_payload) do
    IO.puts("ricevuto un payload non riconosciuto:")
    IO.inspect(unknown_payload)
  end


  # Funzioni di supporto

  def send_to_python_service(payload, python_host, python_port) do
  # coding the payload to JSON
  json_request = Jason.encode!(payload)

  case :gen_tcp.connect(python_host, python_port, [:binary, active: false], 2000) do
    {:ok, socket} ->
      :gen_tcp.send(socket, json_request)

      # JSON response from Python
      result = case :gen_tcp.recv(socket, 0, 2000) do
        {:ok, raw_json} ->

          parsed_response = Jason.decode!(raw_json)

          # JSON to elixir tuple
          case parsed_response do

            {:ok, %{"flag" => "setup_keys", "pub_key" => pub_key}} ->
              {:ok, pub_key}

            {:ok, %{"flag" => "setup_keys_warning", "status" => "success"}} ->
              {:ok, "setup_keys_warning"}

            {:ok,%{ _ => data}} ->
              {:ok, data}

            {:error, %{"status" => "error", "reason" => reason}} ->
              {:error, reason}

            _ ->
              {:error, "Risposta Python malformata"}
          end

        {:error, reason} ->
          {:error, "Timeout o errore di lettura: #{inspect(reason)}"}
      end

      :gen_tcp.close(socket)
      result

    {:error, reason} ->
      {:error, "Impossibile connettersi a Python: #{inspect(reason)}"}
  end
end

  defp broadcast_to_peers(peers, message) do
    data = :erlang.term_to_binary(message)
    Enum.each(peers, fn {_peer_id, {host, port}} ->
      send_tcp(host, port, data)
    end)
  end

  end
end
