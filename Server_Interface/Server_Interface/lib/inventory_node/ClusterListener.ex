defmodule Server_Interface.ClusterListener do
  use Task
  require Logger

  def start_link(port) do
    Task.start_link(__MODULE__, :listen, [port])
  end

  def listen(port) do

    {:ok, socket} = :gen_tcp.listen(port, [:binary, packet: 4, active: false, reuseaddr: true])
    Logger.info("Cluster Listener (Erlang) in ascolto sulla porta #{port}")
    loop_acceptor(socket)
  end

  defp loop_acceptor(socket) do
    {:ok, client} = :gen_tcp.accept(socket)
    Task.start(fn -> serve(client) end)
    msg = {:setup_keys, "pub_key"} # setup iniziale delle chiavi pubbliche tra nodi
    Task.start(fn -> InventoryNode.Router.handle_payload(msg) end)

    loop_acceptor(socket)
  end

  defp serve(client) do
    case :gen_tcp.recv(client, 0) do
      {:ok, data} ->
        payload = :erlang.binary_to_term(data, [:safe])

        InventoryNode.Router.handle_payload(payload)

        serve(client)

      {:error, _} -> :ok
    end
  end
end
