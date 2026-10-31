defmodule InventoryNode.Application do
  use Application

  @impl true
  def start(_type, _args) do
    # Simulated behaviour faults are now a *runtime* mode
    # (InventoryNode.SimBehaviour, set via POST /api/v1/simbehaviour/*), not a
    # separate boot-time engine: there is a single ConsensusEngine whose
    # broadcast/Router/Python behaviour is gated on the current mode.

    cluster_port =
      case System.get_env("ELIXIR_CLUSTER_PORT") do
        nil -> 4000
        "" -> 4000
        value -> String.to_integer(value)
      end

    children = [
      # PoA-BFT consensus engine.
      InventoryNode.ConsensusEngine,

      # Listen for other Elixir nodes using Erlang Binary framing (packet: 4).
      {InventoryNode.ClusterListener, cluster_port},

      # HTTP listener for the Python backend.
      {InventoryNode.HTTPListener, []}
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: InventoryNode.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
