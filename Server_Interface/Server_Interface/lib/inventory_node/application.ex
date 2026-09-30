defmodule InventoryNode.Application do

  use Application

  @impl true
  def start(_type, _args) do
    my_id = System.get_env("NODE_ID") || "node_A"


  cluster_map = File.read!("cluster.json")
    |> Jason.decode!()

  # Rimuovi te stesso dalla lista dei peer da contattare
  peers = Map.delete(cluster_map, my_id)
    children = [
      # Starts a worker by calling: InventoryNode.Worker.start_link(arg)
      # {InventoryNode.Worker, arg}
      InventoryNode.Mempool,
      InventoryNode.ConsensusEngine,
      # Ascolta i client esterni (Java, Web) in JSON
     {Server_Interface.ClientListener, 5000},

      # Ascolta gli altri nodi Elixir in Erlang Binary
     {Server_Interface.ClusterListener, 4000},
    ]


    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: InventoryNode.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
