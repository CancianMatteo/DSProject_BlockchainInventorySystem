defmodule InventoryNode.ClusterListener do
  use Task
  require Logger

  def start_link(port) do
    Task.start_link(__MODULE__, :listen, [port])
  end

  def listen(port) do

    {:ok, socket} = :gen_tcp.listen(port, [:binary, packet: 4, active: false, reuseaddr: true])
    Logger.info("Cluster Listener (Erlang) in ascolto sulla porta #{port}")
    msg = {:setup_keys} # setup iniziale delle chiavi pubbliche tra nodi
    Task.start(fn -> InventoryNode.Router.handle_payload(msg) end)

    loop_acceptor(socket)
  end

  defp loop_acceptor(socket) do
    {:ok, client} = :gen_tcp.accept(socket)
    Task.start(fn -> serve(client) end)

    loop_acceptor(socket)
  end

  defp serve(client) do
    # Modalità noresponse: la connessione viene accettata ma non processata.
    if InventoryNode.SimBehaviour.get() == :noresponse do
      :gen_tcp.close(client)
      :ok
    else
      handle_connection(client)
    end
  end

  defp handle_connection(client) do
    case :gen_tcp.recv(client, 0) do
      {:ok, data} ->
        payload = :erlang.binary_to_term(data, [:safe])

        InventoryNode.Router.handle_payload(payload)

        handle_connection(client)

      {:error, _} -> :ok
    end
  end
end
