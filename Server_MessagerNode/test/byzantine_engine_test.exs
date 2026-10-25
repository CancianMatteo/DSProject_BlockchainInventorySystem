defmodule InventoryNode.ByzantineEngineTest do
  use ExUnit.Case, async: false

  alias InventoryNode.ByzantineEngine

  setup do
    previous_scenario = System.get_env("BIZANTINE_SCENARIO")

    on_exit(fn ->
      if previous_scenario do
        System.put_env("BIZANTINE_SCENARIO", previous_scenario)
      else
        System.delete_env("BIZANTINE_SCENARIO")
      end
    end)

    :ok
  end

  test "split-brain sends commit proposals to only two sorted peers" do
    System.put_env("BIZANTINE_SCENARIO", "split_brain")

    assert ByzantineEngine.broadcast_plan(
             {:commit_proposal, 1, 0, "node_a", %{}, "signature", %{}},
             ["node_d", "node_b", "node_c"]
           ) == {:send_to, ["node_b", "node_c"]}
  end

  test "leader-offline drops commit proposals and its timeout vote" do
    System.put_env("BIZANTINE_SCENARIO", "leader_offline")

    assert ByzantineEngine.broadcast_plan(
             {:commit_proposal, 1, 0, "node_a", %{}, "signature", %{}},
             ["node_b", "node_c"]
           ) == :drop

    assert ByzantineEngine.broadcast_plan({:round_change, %{}}, ["node_b", "node_c"]) == :drop
  end

  test "equivocation divides peers into disjoint primary and alternate groups" do
    System.put_env("BIZANTINE_SCENARIO", "equivocation")

    {primary, alternate} =
      ByzantineEngine.equivocation_partitions(["node_d", "node_b", "node_c"])

    assert primary == ["node_b", "node_c"]
    assert alternate == ["node_d"]
    assert MapSet.disjoint?(MapSet.new(primary), MapSet.new(alternate))
  end
end
