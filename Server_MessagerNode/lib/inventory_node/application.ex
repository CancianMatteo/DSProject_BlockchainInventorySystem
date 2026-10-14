defmodule InventoryNode.Application do

  use Application

  @impl true
  def start(_type, _args) do
    my_id = System.get_env("NODE_ID")
    is_byzantine = System.get_env("BYZANTINE_MODE") == "true"
  engine_module =
      if is_byzantine do
        InventoryNode.ByzantineEngine
      else
        InventoryNode.ConsensusEngine
      end

  cluster_map = File.read!("cluster.json")
    |> Jason.decode!()

  # Rimuovi te stesso dalla lista dei peer da contattare
  peers = Map.delete(cluster_map, my_id)
    children = [

      # {InventoryNode.Worker, arg}
      engine_module,
      # Ascolta la componente Python e messaggi ritrasmessi dal cliente in JSON
     {Server_Interface.ClientListener, 8000},

      # Ascolta gli altri nodi Elixir in Erlang Binary
     {Server_Interface.ClusterListener, 4000},
    ]


    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: InventoryNode.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
