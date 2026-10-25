defmodule InventoryNode.ByzantineEngine do
  @moduledoc """
  Fault-injection plans used by the active ConsensusEngine.

  This module is deliberately not a GenServer: it must not run as a second
  consensus engine.
  """

  @scenarios ~w(invalid_signature split_brain equivocation leader_offline)

  def scenario do
    case System.get_env("BIZANTINE_SCENARIO", "invalid_signature") do
      value when value in @scenarios -> value
      value -> raise ArgumentError, "unsupported BIZANTINE_SCENARIO: #{value}"
    end
  end

  def equivocation_scenario?, do: scenario() == "equivocation"

  def broadcast_plan({:commit_proposal, _, _, _, _, _, _}, peers) do
    case scenario() do
      "split_brain" -> {:send_to, peers |> Enum.sort() |> Enum.take(2)}
      "leader_offline" -> :drop
      _ -> :all
    end
  end

  def broadcast_plan({:round_change, _}, _peers) do
    if scenario() == "leader_offline", do: :drop, else: :all
  end

  def broadcast_plan(_message, _peers), do: :all

  def equivocation_partitions(peers) do
    sorted_peers = Enum.sort(peers)
    primary_count = div(length(sorted_peers) + 1, 2)
    Enum.split(sorted_peers, primary_count)
  end
end
