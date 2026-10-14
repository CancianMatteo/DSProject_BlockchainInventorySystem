defmodule Server_Interface.ClientListener do
  use Task
  require Logger

  def start_link(port) do
    Task.start_link(__MODULE__, :listen, [port])
  end

  def listen(port) do
    {:ok, socket} = :gen_tcp.listen(port, [:binary, packet: :line, active: false, reuseaddr: true])
    Logger.info("Client Listener (JSON) in ascolto sulla porta #{port}")
    loop_acceptor(socket)
  end

  defp loop_acceptor(socket) do
    {:ok, client} = :gen_tcp.accept(socket)
    Task.start(fn -> serve(client) end)
    loop_acceptor(socket)
  end

  defp serve(client) do
    case :gen_tcp.recv(client, 0) do
      {:ok, data} ->
        case Jason.decode(data) do
          {:ok, payload} when is_map(payload) ->

            InventoryNode.Router.handle_payload(payload)

          {:ok, _other} -> Logger.warning("JSON non è un oggetto")
          {:error, reason} -> Logger.warning("JSON non valido: #{inspect(reason)}")
        end
        serve(client)

      {:error, _} -> :ok
    end
  end
end
