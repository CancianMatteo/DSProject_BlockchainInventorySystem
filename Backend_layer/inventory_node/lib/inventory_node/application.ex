defmodule InventoryNode.Application do

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Starts a worker by calling: InventoryNode.Worker.start_link(arg)
      # {InventoryNode.Worker, arg}
      InventoryNode.Mempool,
      InventoryNode.ConsensusEngine,
      {InventoryNode.Listener, 4000}
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: InventoryNode.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
