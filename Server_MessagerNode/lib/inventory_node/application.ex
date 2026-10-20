defmodule InventoryNode.Application do

  use Application

  @impl true
  def start(_type, _args) do
    is_byzantine = System.get_env("BYZANTINE_MODE") == "true"
    engine_module =
      if is_byzantine do
        InventoryNode.ByzantineEngine
      else
        InventoryNode.ConsensusEngine
      end

    cluster_port =
      case System.get_env("ELIXIR_CLUSTER_PORT") do
        nil -> 4000
        "" -> 4000
        value -> String.to_integer(value)
      end

    children = [
      # Motore di consenso BFT-PoA
      engine_module,

      # Ascolta gli altri nodi Elixir in Erlang Binary (packet: 4 framing)
      {InventoryNode.ClusterListener, cluster_port},

      # HTTP listener per il backend Python
      {InventoryNode.HTTPListener, []}
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: InventoryNode.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
