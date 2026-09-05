defmodule InventoryNode.Listener do

  use Task # modulo per creare processi in background
  require Logger

  def start_link(port) do
    Task.start_link(__MODULE__, :listen, [port])
  end


  defp listen(port) do
    # socket tcp
    {:ok, socket} = :gen_tcp.listen(port, [:binary, active: false, reuseaddr: true])
    Logger.info("In ascolto sulla porta #{port}")

    loop_acceptor(socket)
  end


  defp loop_acceptor(socket) do
    {:ok, client} = :gen_tcp.accept(socket)

    # Spawna un processo isolato solo per questo client
    Task.start(fn -> serve(client) end)

    # Torniamo subito in ascolto per il prossimo client
    loop_acceptor(socket)
  end


  defp serve(client) do
    case :gen_tcp.recv(client, 0) do
      {:ok, data} ->
        # Decodifichiamo i byte (es. usando il formato binario nativo di Erlang)
        payload = :erlang.binary_to_term(data)

        # ECCO IL COLLEGAMENTO AL ROUTER!
        InventoryNode.Router.handle_payload(payload)

        # Se la connessione è persistente, continuiamo ad ascoltare
        serve(client)

      {:error, :closed} ->
        # Il client si è disconnesso
        :ok
    end
  end
end
