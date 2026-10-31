defmodule InventoryNode.ConsensusEngine do
  use GenServer
  require Logger

  # Maximum time to commit a block before changing proposer.
  @round_timeout 8000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, opts ++ [name: __MODULE__])
  end

  def request_proposal(reason, pending_count) do
    GenServer.call(__MODULE__, {:proposal_request, reason, pending_count}, 15_000)
  end

  @impl true
  def init(:ok) do
    node_id = System.get_env("NODE_ID") || "node_a"
    python_host = (System.get_env("PYTHON_HOST") || "localhost") |> String.to_charlist()
    python_port = (System.get_env("PYTHON_PORT") || "8000") |> String.to_integer()
    peers = parse_peers(System.get_env("PEERS"))

    # In PBFT, all nodes (including this node) are part of the validator set.
    validator_nodes = Enum.sort([node_id | Map.keys(peers)])
    total_nodes = length(validator_nodes)

    # N = 3f + 1 -> quorum = 2f + 1.
    # With four nodes, f = 1 and the quorum is 3.
    f = div(total_nodes - 1, 3)
    quorum = 2 * f + 1

    state = %{
      node_id: node_id,
      peers: peers,
      validators: validator_nodes,
      python_host: python_host,
      python_port: python_port,
      quorum: quorum,

      # BFT state.
      # Block height.
      current_height: nil,
      # Current attempt for this height.
      current_round: 0,
      timer_ref: nil,
      timeout_token: nil,
      temporary_signature: nil,

      # BFT phase votes; each map stores validator_id => signature.
      prepare_votes: %{},
      commit_votes: %{},
      commit_started: false,
      round_change_started: false,
      round_change_votes: %{},
      equivocation_evidence: MapSet.new(),
      equivocation_recovery_targets: %{},

      # Block currently being processed.
      pending_block: nil
    }

    Logger.info("Modified PoA-BFT started. Node: #{node_id}. Quorum: #{quorum}/#{total_nodes}.")
    send(self(), :initialize_from_python)
    {:ok, state}
  end

  @impl true
  def handle_cast(message, state) do
    case message do
      {:round_change, payload} ->
        handle_cast_round_change(payload, state)

      {:finalized_block, package} ->
        handle_cast_finalized_block(package, state)

      :trigger_block ->
        handle_cast_trigger_block(state)

      {:pre_prepare, height, round, proposer_id, block_data, signature} ->
        handle_cast_pre_prepare(height, round, proposer_id, block_data, signature, state)

      {:prepare_vote, height, round, block_hash, validator_id, signature} ->
        handle_cast_prepare_vote(height, round, block_hash, validator_id, signature, state)

      {:commit_proposal, height, round, proposer_id, block_data, proposer_signature,
       prepare_signatures} ->
        handle_cast_commit_proposal(
          height,
          round,
          proposer_id,
          block_data,
          proposer_signature,
          prepare_signatures,
          state
        )

      {:commit_vote, height, round, proposer_id, block_data, proposer_signature,
       prepare_signatures, block_hash, validator_id, signature} ->
        handle_cast_commit_vote(
          height,
          round,
          proposer_id,
          block_data,
          proposer_signature,
          prepare_signatures,
          block_hash,
          validator_id,
          signature,
          state
        )

      _ ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(message, state) do
    case message do
      :initialize_from_python ->
        handle_info_initialize_from_python(state)

      :round_timeout ->
        handle_info_round_timeout(state)

      {:round_timeout, token} when token == state.timeout_token ->
        handle_info_round_timeout(state)

      {:verified_round_change, height, target_round, validator_id, payload, true} ->
        handle_info_verified_round_change(
          height,
          target_round,
          validator_id,
          payload,
          state
        )

      {:verified_round_change, _, _, validator_id, _, false} ->
        handle_info_bad_round_change(validator_id, state)

      {:verified_pre_prepare, height, round, proposer_id, block_data, proposer_signature, true} ->
        handle_info_verified_pre_prepare(
          height,
          round,
          proposer_id,
          block_data,
          proposer_signature,
          state
        )

      {:verified_pre_prepare, _, _, proposer_id, _, _, false} ->
        handle_info_bad_pre_prepare(proposer_id, state)

      {:verified_prepare_vote, height, round, block_hash, validator_id, signature, true} ->
        handle_info_verified_prepare_vote(
          height,
          round,
          block_hash,
          validator_id,
          signature,
          state
        )

      {:verified_prepare_vote, _, _, _, validator_id, _, false} ->
        handle_info_bad_prepare_vote(validator_id, state)

      {:verified_commit_proposal, height, round, proposer_id, block_data, proposer_signature,
       prepare_signatures, true} ->
        handle_info_verified_commit_proposal(
          height,
          round,
          proposer_id,
          block_data,
          proposer_signature,
          prepare_signatures,
          state
        )

      {:verified_commit_proposal, _, _, proposer_id, _, _, _, false} ->
        handle_info_bad_commit_proposal(proposer_id, state)

      {:verified_commit_vote, height, round, proposer_id, block_data, proposer_signature,
       prepare_signatures, block_hash, validator_id, signature, true} ->
        handle_info_verified_commit_vote(
          height,
          round,
          proposer_id,
          block_data,
          proposer_signature,
          prepare_signatures,
          block_hash,
          validator_id,
          signature,
          state
        )

      {:verified_commit_vote, _, _, _, _, _, _, _, validator_id, _, false} ->
        handle_info_bad_commit_vote(validator_id, state)

      {:broadcast_round_change, payload} ->
        handle_info_broadcast_round_change(payload, state)

      {:send_finalized_block, package, target_ids} ->
        handle_info_send_finalized_block(package, target_ids, state)

      {:finalized_block_imported, height, block_hash, true} ->
        handle_info_finalized_block_imported(height, block_hash, state)

      {:finalized_block_imported, height, block_hash, false} ->
        Logger.warning("Finalized block #{height} (#{block_hash}) was not imported.")

        {:noreply, state}

      _ ->
        {:noreply, state}
    end
  end

  defp handle_info_round_timeout(state) do
    if state.commit_started do
      Logger.warning(
        "COMMIT for block #{state.current_height} is still in progress; waiting for quorum instead of changing rounds."
      )

      {:noreply, schedule_round_timeout(state)}
    else
      target_round = state.current_round + 1

      Logger.warning(
        "Block #{state.current_height} timed out. Starting ROUND_CHANGE for round #{target_round}."
      )

      payload = %{
        "flag" => "round_change",
        "reason" => "timeout",
        "height" => state.current_height,
        "target_round" => target_round,
        "validator_id" => state.node_id
      }

      case send_to_python_service(payload, state.python_host, state.python_port) do
        {:ok, %{"signature" => signature} = signed_payload} when is_binary(signature) ->
          broadcast_to_all(state.peers, {:round_change, signed_payload})

        other ->
          Logger.error("Failed to sign ROUND_CHANGE for timeout: #{inspect(other)}")
      end

      {:noreply, %{state | round_change_started: true}}
    end
  end

  # Round and proposer management (round-robin).

  defp schedule_round_timeout(state) do
    if state.timer_ref, do: Process.cancel_timer(state.timer_ref)
    token = make_ref()
    timer_ref = Process.send_after(self(), {:round_timeout, token}, @round_timeout)
    %{state | timer_ref: timer_ref, timeout_token: token}
  end

  defp start_round(state) do
    timed_state = schedule_round_timeout(state)

    # The proposer is deterministic: (height + round) mod the number of nodes.
    proposer_index = rem(state.current_height + state.current_round, length(state.validators))
    current_proposer = Enum.at(state.validators, proposer_index)

    # Clear votes from the previous round.
    new_state = %{
      timed_state
      | prepare_votes: %{},
        commit_votes: %{},
        commit_started: false,
        round_change_started: false,
        pending_block: nil,
        temporary_signature: nil
    }

    if current_proposer == state.node_id do
      Logger.info(
        "[Height #{state.current_height}] I am the proposer (round #{state.current_round}); waiting for the Python trigger."
      )
    else
      Logger.info("[Height #{state.current_height}] Expected proposer: #{current_proposer}.")
    end

    new_state
  end

  defp handle_info_initialize_from_python(state) do
    case send_to_python_service(%{"flag" => "chain_state"}, state.python_host, state.python_port) do
      {:ok, %{"next_height" => height}} when is_integer(height) and height > 0 ->
        Logger.info("Initial height synchronized with Python: #{height}.")
        {:noreply, start_round(%{state | current_height: height})}

      {:ok, response} ->
        Logger.error("Python returned an invalid blockchain state: #{inspect(response)}")
        Process.send_after(self(), :initialize_from_python, 1_000)
        {:noreply, state}

      {:error, reason} ->
        Logger.error("Failed to read blockchain state from Python: #{reason}")
        Process.send_after(self(), :initialize_from_python, 1_000)
        {:noreply, state}
    end
  end

  @impl true
  def handle_call({:proposal_request, reason, pending_count}, _from, state)
      when reason in ["mempool_full", "idle_timeout"] and is_integer(pending_count) and
             pending_count > 0 do
    cond do
      proposer_for(state, state.current_height, state.current_round) != state.node_id ->
        {:reply, %{"accepted" => false, "status" => "not_proposer"}, state}

      state.commit_started or state.round_change_started or is_map(state.pending_block) ->
        {:reply, %{"accepted" => false, "status" => "busy"}, state}

      true ->
        Logger.info(
          "Proposal trigger received from Python: #{reason}, #{pending_count} pending transactions."
        )

        proposed_state = propose_block(state)

        if is_map(proposed_state.pending_block) do
          proposed_state = schedule_round_timeout(proposed_state)

          {:reply,
           %{
             "accepted" => true,
             "status" => "ok",
             "height" => state.current_height,
             "round" => state.current_round
           }, proposed_state}
        else
          {:reply, %{"accepted" => false, "status" => "no_block"}, proposed_state}
        end
    end
  end

  def handle_call({:proposal_request, _reason, _pending_count}, _from, state) do
    {:reply, %{"accepted" => false, "status" => "invalid_request"}, state}
  end

  # ROUND CHANGE.

  defp handle_cast_round_change(payload, state) do
    engine_pid = self()
    verification_payload = Map.put(payload, "flag", "verified_round_change")

    Task.start(fn ->
      case send_to_python_service(verification_payload, state.python_host, state.python_port) do
        {:ok, %{"status" => is_valid}} when is_boolean(is_valid) ->
          send(
            engine_pid,
            {:verified_round_change, payload["height"], payload["target_round"],
             payload["validator_id"], payload, is_valid}
          )

        other ->
          Logger.warning("ROUND_CHANGE verification failed: #{inspect(other)}")
      end
    end)

    {:noreply, state}
  end

  defp handle_info_verified_round_change(height, target_round, validator_id, payload, state) do
    {state, is_new_evidence} = record_equivocation_evidence(payload, state)
    state = remember_equivocation_recovery_target(state, height, payload)

    if is_new_evidence do
      broadcast_to_all(state.peers, {:round_change, payload})
    end

    request_finalized_block_if_committed(height, payload, state)

    if height == state.current_height and target_round > state.current_round and
         not state.commit_started do
      current_votes = Map.get(state.round_change_votes, target_round, MapSet.new())
      new_votes = MapSet.put(current_votes, validator_id)

      new_round_change_map = Map.put(state.round_change_votes, target_round, new_votes)
      new_state = %{state | round_change_votes: new_round_change_map}

      if MapSet.size(new_votes) >= state.quorum do
        Logger.warning(
          "Round-change quorum reached. Moving to round #{target_round}."
        )

        final_state = %{
          new_state
          | current_round: target_round,
            round_change_votes: Map.delete(new_round_change_map, target_round)
        }

        {:noreply, start_round(final_state)}
      else
        {:noreply, new_state}
      end
    else
      {:noreply, state}
    end
  end

  defp handle_info_bad_round_change(validator_id, state),
    do: ignore_bad_sig(validator_id, state)

  # Phase 1: PRE-PREPARE (leader proposal).

  defp handle_cast_trigger_block(state) do
    proposer_index = rem(state.current_height + state.current_round, length(state.validators))
    current_proposer = Enum.at(state.validators, proposer_index)

    if current_proposer == state.node_id and is_nil(state.pending_block) and
         not state.round_change_started do
      {:noreply, propose_block(state)}
    else
      {:noreply, state}
    end
  end

  defp propose_block(state) do
    payload = %{
      "flag" => "prepare_block",
      "node_id" => state.node_id,
      "current_height" => state.current_height,
      "round" => state.current_round
    }

    case send_to_python_service(payload, state.python_host, state.python_port) do
      {:ok, %{"block_data" => block_data, "proposer_sign" => signature} = proposal}
      when is_map(block_data) and is_binary(signature) ->
        prepare_payload = %{
          "flag" => "prepare",
          "height" => state.current_height,
          "round" => state.current_round,
          "validator_id" => state.node_id,
          "block_data" => block_data
        }

        case send_to_python_service(prepare_payload, state.python_host, state.python_port) do
          {:ok, %{"signature" => prepare_signature}} when is_binary(prepare_signature) ->
            Logger.info("Proposing block #{state.current_height}, round #{state.current_round}.")

            pre_prepare =
              {:pre_prepare, state.current_height, state.current_round, state.node_id, block_data,
               signature}

            if InventoryNode.SimBehaviour.get() == :bizantine and
                 InventoryNode.ByzantineEngine.equivocation_scenario?() and
                 is_map(proposal["equivocation_block_data"]) and
                 is_binary(proposal["equivocation_sign"]) do
              {primary_peers, alternate_peers} =
                InventoryNode.ByzantineEngine.equivocation_partitions(Map.keys(state.peers))

              alternate_pre_prepare =
                {:pre_prepare, state.current_height, state.current_round, state.node_id,
                 proposal["equivocation_block_data"], proposal["equivocation_sign"]}

              send_to_peer_ids(primary_peers, state.peers, pre_prepare)
              send_to_peer_ids(alternate_peers, state.peers, alternate_pre_prepare)
            else
              broadcast_to_all(state.peers, pre_prepare)
            end

            %{
              state
              | pending_block: block_data,
                temporary_signature: signature,
                prepare_votes: %{state.node_id => prepare_signature}
            }

          other ->
            Logger.error("Firma PREPARE del proposer non disponibile: #{inspect(other)}")
            state
        end

      other ->
        Logger.warning("Nessun blocco da proporre al momento: #{inspect(other)}")
        state
    end
  end

  defp handle_cast_pre_prepare(height, round, proposer_id, block_data, signature, state) do
    engine_pid = self()

    payload = %{
      "flag" => "pre_prepare",
      "height" => height,
      "round" => round,
      "proposer_id" => proposer_id,
      "block_data" => block_data,
      "signature" => signature
    }

    Task.start(fn ->
      verified? =
        case send_to_python_service(payload, state.python_host, state.python_port) do
          {:ok, %{"status" => status}} -> status == true
          _ -> false
        end

      expected_proposer = proposer_for(state, height, round)
      valid_proposal? = verified? and proposer_id == expected_proposer

      send(
        engine_pid,
        {:verified_pre_prepare, height, round, proposer_id, block_data, signature,
         valid_proposal?}
      )
    end)

    {:noreply, state}
  end

  defp handle_info_verified_pre_prepare(
         height,
         round,
         proposer_id,
         block_data,
         proposer_signature,
         state
       ) do
    expected_proposer = proposer_for(state, height, round)

    cond do
      height != state.current_height or round != state.current_round or
          proposer_id != expected_proposer ->
        {:noreply, state}

      has_equivocation_evidence?(state, height, round, proposer_id) ->
        Logger.warning(
          "PRE-PREPARE ignored: equivocation already proven for height #{height}, round #{round}."
        )

        {:noreply, state}

      state.pending_block == block_data ->
        {:noreply, state}

      state.pending_block != nil ->
        report_pre_prepare_conflict(
          height,
          round,
          proposer_id,
          block_data,
          proposer_signature,
          state
        )

        {:noreply, state}

      true ->
        Logger.info("Valid PRE-PREPARE from #{proposer_id}. Sending PREPARE to the proposer.")

        payload = %{
          "flag" => "prepare",
          "height" => height,
          "round" => round,
          "validator_id" => state.node_id,
          "block_data" => block_data
        }

        case send_to_python_service(payload, state.python_host, state.python_port) do
          {:ok, %{"signature" => my_signature}} ->
            msg =
              {:prepare_vote, height, round, block_data["block_hash"], state.node_id,
               my_signature}

            send_unicast(proposer_id, state.peers, msg, state.node_id)

            {:noreply,
             %{state | pending_block: block_data, temporary_signature: proposer_signature}}

          other ->
            Logger.warning("Python PREPARE operation failed: #{inspect(other)}")
            {:noreply, state}
        end
    end
  end

  defp handle_info_bad_pre_prepare(proposer_id, state),
    do: ignore_bad_sig(proposer_id, state)

  # Phase 2: PREPARE (the proposer receives signatures from nodes by unicast).

  defp handle_cast_prepare_vote(height, round, block_hash, validator_id, signature, state) do
    engine_pid = self()

    proposer = proposer_for(state, height, round)

    if height == state.current_height and round == state.current_round and
         proposer == state.node_id and state.pending_block != nil and
         state.pending_block["block_hash"] == block_hash do
      payload = %{
        "flag" => "verified_prepare",
        "height" => height,
        "round" => round,
        "validator_id" => validator_id,
        "block_hash" => block_hash,
        "signature" => signature
      }

      Task.start(fn ->
        case send_to_python_service(payload, state.python_host, state.python_port) do
          {:ok, %{"status" => is_valid}} ->
            send(
              engine_pid,
              {:verified_prepare_vote, height, round, block_hash, validator_id, signature,
               is_valid}
            )

          other ->
            Logger.warning("PREPARE verification failed for #{validator_id}: #{inspect(other)}")
        end
      end)
    end

    {:noreply, state}
  end

  defp handle_info_verified_prepare_vote(
         height,
         round,
         block_hash,
         validator_id,
         signature,
         state
       ) do
    if height == state.current_height and round == state.current_round and
         state.pending_block != nil and state.pending_block["block_hash"] == block_hash and
         validator_id in state.validators and not state.commit_started do
      new_votes = Map.put(state.prepare_votes, validator_id, signature)

      if map_size(new_votes) >= state.quorum and
           state.node_id ==
             proposer_for(state, height, round) do
        Logger.info(
          "PREPARE quorum reached (#{map_size(new_votes)}/#{state.quorum}). " <>
            "Sending the proposal for COMMIT voting."
        )

        commit_proposal =
          {:commit_proposal, height, round, state.node_id, state.pending_block,
           state.temporary_signature, new_votes}

        broadcast_to_all(state.peers, commit_proposal)

        {:noreply, %{state | prepare_votes: new_votes}}
      else
        {:noreply, %{state | prepare_votes: new_votes}}
      end
    else
      {:noreply, state}
    end
  end

  defp handle_info_bad_prepare_vote(validator_id, state),
    do: ignore_bad_sig(validator_id, state)

  # Phase 3: COMMIT (a separate vote after the PREPARE certificate).

  defp handle_cast_commit_proposal(
         height,
         round,
         proposer_id,
         block_data,
         proposer_signature,
         prepare_signatures,
         state
       ) do
    engine_pid = self()

    expected_proposer = proposer_for(state, height, round)

    if height == state.current_height and round == state.current_round and
         proposer_id == expected_proposer and is_map(prepare_signatures) do
      payload = %{
        "flag" => "commit_proposal",
        "height" => height,
        "round" => round,
        "proposer_id" => proposer_id,
        "block_data" => block_data,
        "signature" => proposer_signature,
        "signatures" =>
          Enum.map(prepare_signatures, fn {validator_id, signature} ->
            %{"validator_id" => validator_id, "signature" => signature}
          end)
      }

      Task.start(fn ->
        case send_to_python_service(payload, state.python_host, state.python_port) do
          {:ok, %{"status" => true}} ->
            send(
              engine_pid,
              {:verified_commit_proposal, height, round, proposer_id, block_data,
               proposer_signature, prepare_signatures, true}
            )

          other ->
            Logger.warning("PREPARE certificate verification for COMMIT failed: #{inspect(other)}")

            send(
              engine_pid,
              {:verified_commit_proposal, height, round, proposer_id, block_data,
               proposer_signature, prepare_signatures, false}
            )
        end
      end)
    end

    {:noreply, state}
  end

  defp handle_info_verified_commit_proposal(
         height,
         round,
         proposer_id,
         block_data,
         proposer_signature,
         prepare_signatures,
         state
       ) do
    expected_proposer = proposer_for(state, height, round)

    cond do
      height != state.current_height or round != state.current_round or
          proposer_id != expected_proposer ->
        {:noreply, state}

      state.pending_block != nil and state.pending_block != block_data ->
        report_pre_prepare_conflict(
          height,
          round,
          proposer_id,
          block_data,
          proposer_signature,
          state
        )

        {:noreply, state}

      has_equivocation_evidence?(state, height, round, proposer_id) and
          not state.commit_started ->
        Logger.warning(
          "COMMIT ignored: equivocation by proposer #{proposer_id} was proven " <>
            "for height #{height}, round #{round}."
        )

        {:noreply, state}

      state.commit_started ->
        {:noreply, state}

      true ->
        {:noreply,
         start_commit_voting(
           state,
           height,
           round,
           proposer_id,
           block_data,
           proposer_signature,
           prepare_signatures
         )}
    end
  end

  defp handle_info_bad_commit_proposal(proposer_id, state),
    do: ignore_bad_sig(proposer_id, state)

  defp handle_cast_commit_vote(
         height,
         round,
         proposer_id,
         block_data,
         proposer_signature,
         prepare_signatures,
         block_hash,
         validator_id,
         signature,
         state
       ) do
    engine_pid = self()

    if height == state.current_height and round == state.current_round and
         proposer_id == proposer_for(state, height, round) and
         is_map(block_data) and block_data["block_hash"] == block_hash and
         is_map(prepare_signatures) and validator_id in state.validators do
      certificate_payload = %{
        "flag" => "commit_proposal",
        "height" => height,
        "round" => round,
        "proposer_id" => proposer_id,
        "block_data" => block_data,
        "signature" => proposer_signature,
        "signatures" =>
          Enum.map(prepare_signatures, fn {prepare_validator, prepare_signature} ->
            %{"validator_id" => prepare_validator, "signature" => prepare_signature}
          end)
      }

      vote_payload = %{
        "flag" => "verified_commit",
        "height" => height,
        "round" => round,
        "validator_id" => validator_id,
        "block_hash" => block_hash,
        "signature" => signature
      }

      Task.start(fn ->
        with {:ok, %{"status" => true}} <-
               send_to_python_service(certificate_payload, state.python_host, state.python_port),
             {:ok, %{"status" => valid?}} when is_boolean(valid?) <-
               send_to_python_service(vote_payload, state.python_host, state.python_port) do
          send(
            engine_pid,
            {:verified_commit_vote, height, round, proposer_id, block_data, proposer_signature,
             prepare_signatures, block_hash, validator_id, signature, valid?}
          )
        else
          {:ok, %{"status" => false}} ->
            Logger.warning("Invalid PREPARE certificate in COMMIT vote from #{validator_id}.")

          other ->
            Logger.warning("COMMIT vote verification failed for #{validator_id}: #{inspect(other)}")
        end
      end)
    end

    {:noreply, state}
  end

  defp handle_info_verified_commit_vote(
         height,
         round,
         proposer_id,
         block_data,
         proposer_signature,
         prepare_signatures,
         block_hash,
         validator_id,
         signature,
         state
       ) do
    cond do
      height != state.current_height or round != state.current_round or
        proposer_id != proposer_for(state, height, round) or
          validator_id not in state.validators ->
        {:noreply, state}

      is_map(state.pending_block) and state.pending_block["block_hash"] != block_hash ->
        report_pre_prepare_conflict(
          height,
          round,
          proposer_id,
          block_data,
          proposer_signature,
          state
        )

        Logger.warning("Ignoring conflicting COMMIT vote for block #{block_hash}.")
        {:noreply, state}

      has_equivocation_evidence?(state, height, round, proposer_id) and
          not state.commit_started ->
        Logger.warning(
          "Ignoring COMMIT vote after equivocation proof for height #{height}, round #{round}."
        )

        {:noreply, state}

      true ->
        state =
          if state.commit_started do
            state
          else
            start_commit_voting(
              state,
              height,
              round,
              proposer_id,
              block_data,
              proposer_signature,
              prepare_signatures
            )
          end

        if state.commit_started or withhold_commit_vote?(state, proposer_id) do
          votes = Map.put_new(state.commit_votes, validator_id, signature)
          new_state = %{state | commit_votes: votes}

          if map_size(votes) >= state.quorum do
            write_committed_block(new_state, height)
          else
            {:noreply, new_state}
          end
        else
          {:noreply, state}
        end
    end
  end

  defp handle_info_bad_commit_vote(validator_id, state),
    do: ignore_bad_sig(validator_id, state)

  defp start_commit_voting(
         state,
         height,
         round,
         proposer_id,
         block_data,
         proposer_signature,
         prepare_signatures
       ) do
    if withhold_commit_vote?(state, proposer_id) do
      %{state | pending_block: block_data, temporary_signature: proposer_signature}
    else
      commit_payload = %{
        "flag" => "commit",
        "height" => height,
        "round" => round,
        "validator_id" => state.node_id,
        "block_hash" => block_data["block_hash"]
      }

      case send_to_python_service(commit_payload, state.python_host, state.python_port) do
        {:ok, %{"signature" => signature}} when is_binary(signature) ->
          vote =
            {:commit_vote, height, round, proposer_id, block_data, proposer_signature,
             prepare_signatures, block_data["block_hash"], state.node_id, signature}

          broadcast_to_all(state.peers, vote)

          %{
            state
            | pending_block: block_data,
              temporary_signature: proposer_signature,
              commit_started: true
          }

        other ->
          Logger.error("COMMIT signature unavailable: #{inspect(other)}")
          state
      end
    end
  end

  defp withhold_commit_vote?(state, proposer_id) do
    InventoryNode.SimBehaviour.get() == :bizantine and
      InventoryNode.ByzantineEngine.scenario() == "split_brain" and
      proposer_id == state.node_id
  end

  defp write_committed_block(state, height) do
    Logger.info(
      "COMMIT quorum reached (#{map_size(state.commit_votes)}/#{state.quorum}). " <>
        "Writing block #{height}."
    )

    write_payload = %{
      "flag" => "write_block",
      "proposer_id" => proposer_for(state, height, state.pending_block["round"]),
      "proposer_signature" => state.temporary_signature,
      "height" => height,
      "block_data" => state.pending_block,
      "commit_signatures" =>
        Enum.map(state.commit_votes, fn {validator_id, signature} ->
          %{"validator_id" => validator_id, "signature" => signature}
        end)
    }

    case send_to_python_service(write_payload, state.python_host, state.python_port) do
      {:ok, %{"status" => true}} ->
        Logger.info("Block #{height} was successfully written to the Python service.")

        proposer_id = proposer_for(state, height, state.pending_block["round"])

        package = %{
          "block_data" => state.pending_block,
          "proposer_id" => proposer_id,
          "proposer_signature" => state.temporary_signature,
          "commit_signatures" => write_payload["commit_signatures"]
        }

        round = state.pending_block["round"]
        recovery_targets = Map.get(state.equivocation_recovery_targets, {height, round}, MapSet.new())

        if MapSet.size(recovery_targets) > 0 do
          target_ids = MapSet.to_list(recovery_targets)

          Logger.info(
            "Sending finalized block #{height} to equivocation reporter(s): #{Enum.join(target_ids, ", ")}."
          )

          send_to_peer_ids(target_ids, state.peers, {:finalized_block, package})
        end

        new_state = %{
          state
          | current_height: state.current_height + 1,
            current_round: 0,
            pending_block: nil,
            temporary_signature: nil,
            prepare_votes: %{},
            commit_votes: %{},
            commit_started: false,
            round_change_votes: %{},
            equivocation_recovery_targets:
              Map.delete(state.equivocation_recovery_targets, {height, round})
        }

        {:noreply, start_round(new_state)}

      other ->
        Logger.error("Failed to write block #{height}: #{inspect(other)}")
        {:noreply, state}
    end
  end

  defp report_pre_prepare_conflict(
         height,
         round,
         proposer_id,
         forged_block,
         forged_signature,
         state
       ) do
    payload = %{
      "flag" => "pre_prepare_conflict",
      "height" => height,
      "round" => round,
      "proposer_id" => proposer_id,
      "validator_id" => state.node_id,
      "forged_block_hash" => forged_block["block_hash"],
      "forged_signature" => forged_signature,
      "conflicting_block_hash" => state.pending_block["block_hash"],
      "conflicting_signature" => state.temporary_signature
    }

    engine_pid = self()

    Task.start(fn ->
      case send_to_python_service(payload, state.python_host, state.python_port) do
        {:ok, %{"status" => true, "proof" => proof}} when is_map(proof) ->
          round_change =
            proof
            |> Map.put("flag", "round_change")
            |> Map.put("target_round", round + 1)

          send(engine_pid, {:broadcast_round_change, round_change})

        other ->
          Logger.warning(          "No valid equivocation proof: #{inspect(other)}")
      end
    end)

    :ok
  end

  defp handle_info_broadcast_round_change(payload, state) do
    broadcast_to_all(state.peers, {:round_change, payload})
    {:noreply, state}
  end

  defp record_equivocation_evidence(payload, state) do
    with true <- is_map(payload),
         height when is_integer(height) <- payload["height"],
         round when is_integer(round) <- payload["round"],
         proposer_id when is_binary(proposer_id) <- payload["proposer_id"],
         true <- is_binary(payload["forged_block_hash"]),
         true <- is_binary(payload["conflicting_block_hash"]) do
      key = {height, round, proposer_id}

      if MapSet.member?(state.equivocation_evidence, key) do
        {state, false}
      else
        Logger.warning(
          "Valid equivocation proof for proposer #{proposer_id}, height #{height}, round #{round}."
        )

        updated_state = %{
          state
          | equivocation_evidence: MapSet.put(state.equivocation_evidence, key)
        }

        if height == state.current_height and round == state.current_round and
             not state.commit_started do
          {%{
             updated_state
             | pending_block: nil,
               temporary_signature: nil,
               prepare_votes: %{},
               commit_votes: %{},
               round_change_started: true
           }, true}
        else
          {updated_state, true}
        end
      end
    else
      _ -> {state, false}
    end
  end

  defp has_equivocation_evidence?(state, height, round, proposer_id) do
    MapSet.member?(state.equivocation_evidence, {height, round, proposer_id})
  end

  defp remember_equivocation_recovery_target(state, height, payload) do
    with true <- equivocation_proof?(payload),
         round when is_integer(round) <- payload["round"],
         reporter_id when is_binary(reporter_id) <- payload["validator_id"],
         true <- reporter_id in Map.keys(state.peers),
         true <- height == state.current_height,
         true <- round == state.current_round,
         true <- state.commit_started do
      targets =
        Map.update(
          state.equivocation_recovery_targets,
          {height, round},
          MapSet.new([reporter_id]),
          &MapSet.put(&1, reporter_id)
        )

      %{state | equivocation_recovery_targets: targets}
    else
      _ -> state
    end
  end

  defp equivocation_proof?(payload) when is_map(payload) do
    is_integer(payload["height"]) and is_integer(payload["round"]) and
      is_binary(payload["proposer_id"]) and is_binary(payload["validator_id"]) and
      is_binary(payload["forged_block_hash"]) and
      is_binary(payload["forged_signature"]) and
      is_binary(payload["conflicting_block_hash"]) and
      is_binary(payload["conflicting_signature"])
  end

  defp equivocation_proof?(_payload), do: false

  defp request_finalized_block_if_committed(height, payload, state)
       when is_integer(height) and is_integer(state.current_height) and
              height < state.current_height do
    if equivocation_proof?(payload) do
      engine_pid = self()
      reporter_id = payload["validator_id"]

      Task.start(fn ->
        case send_to_python_service(
               %{"flag" => "get_finalized_block", "height" => height},
               state.python_host,
               state.python_port
             ) do
          {:ok, %{"status" => true} = response} ->
            package = Map.delete(response, "status")
            send(engine_pid, {:send_finalized_block, package, [reporter_id]})

          {:ok, %{"status" => false}} ->
            Logger.info(
              "No local COMMIT certificate is available for height #{height} " <>
                "(report from #{inspect(payload["proposer_id"])})."
            )

          other ->
            Logger.warning("Failed to retrieve finalized block #{height}: #{inspect(other)}")
        end
      end)
    end

    :ok
  end

  defp request_finalized_block_if_committed(_height, _payload, _state), do: :ok

  defp handle_info_send_finalized_block(package, target_ids, state) do
    target_ids = Enum.filter(target_ids, &Map.has_key?(state.peers, &1))

    if target_ids != [] do
      send_to_peer_ids(target_ids, state.peers, {:finalized_block, package})
    end

    {:noreply, state}
  end

  defp handle_cast_finalized_block(package, state) when is_map(package) do
    block = package["block_data"]

    if is_map(block) and is_integer(block["height"]) and is_binary(block["block_hash"]) do
      engine_pid = self()
      payload = Map.put(package, "flag", "import_finalized_block")

      Task.start(fn ->
        case send_to_python_service(payload, state.python_host, state.python_port) do
          {:ok, %{"status" => true}} ->
            send(
              engine_pid,
              {:finalized_block_imported, block["height"], block["block_hash"], true}
            )

          {:ok, %{"status" => false}} ->
            send(
              engine_pid,
              {:finalized_block_imported, block["height"], block["block_hash"], false}
            )

          other ->
            Logger.warning(
              "Failed to import finalized block #{block["height"]}: #{inspect(other)}"
            )
        end
      end)
    else
      Logger.warning("Malformed finalized-block package; ignoring it.")
    end

    {:noreply, state}
  end

  defp handle_cast_finalized_block(_package, state) do
    Logger.warning("Malformed finalized-block package; ignoring it.")
    {:noreply, state}
  end

  defp handle_info_finalized_block_imported(height, block_hash, state) do
    if height == state.current_height do
      Logger.info(
        "Finalized block #{height} (#{block_hash}) imported with a COMMIT certificate."
      )

      next_state = %{
        state
        | current_height: height + 1,
          current_round: 0,
          pending_block: nil,
          temporary_signature: nil,
          prepare_votes: %{},
          commit_votes: %{},
          commit_started: false,
          round_change_started: false,
          round_change_votes: %{}
      }

      {:noreply, start_round(next_state)}
    else
      {:noreply, state}
    end
  end

  # Helpers.

  defp proposer_for(state, height, round)
       when is_integer(height) and height > 0 and is_integer(round) and round >= 0 do
    Enum.at(state.validators, rem(height + round, length(state.validators)))
  end

  defp proposer_for(_state, _height, _round), do: nil

  defp ignore_bad_sig(node_id, state) do
    Logger.error("Invalid signature from #{node_id}. Possible Byzantine validator!")
    {:noreply, state}
  end

  defp broadcast_to_all(peers, message) do
    case InventoryNode.SimBehaviour.get() do
      :noresponse ->
        :ok

      :bizantine ->
        case InventoryNode.ByzantineEngine.broadcast_plan(message, Map.keys(peers)) do
          :all -> do_broadcast(peers, message)
          :drop -> :ok
          {:send_to, target_ids} -> send_to_peer_ids(target_ids, peers, message)
        end

      _ ->
        do_broadcast(peers, message)
    end
  end

  # Send a message to one peer (for example, a PREPARE vote to the proposer).
  defp send_unicast(target_id, peers, message, current_node_id) do
    if target_id == current_node_id do
      GenServer.cast(__MODULE__, message)
    else
      case Map.get(peers, target_id) do
        {host, port} ->
          data = :erlang.term_to_binary(message)
          Task.start(fn -> send_tcp(target_id, host, port, data) end)
          :ok

        nil ->
          Logger.error("Cannot find host/port for unicast target #{target_id}.")
      end
    end
  end

  defp do_broadcast(peers, message) do
    GenServer.cast(__MODULE__, message)

    send_to_peer_ids(Map.keys(peers), peers, message)
  end

  defp send_to_peer_ids(peer_ids, peers, message) do
    data = :erlang.term_to_binary(message)

    Enum.each(peer_ids, fn peer_id ->
      {host, port} = Map.fetch!(peers, peer_id)

      {:ok, _pid} = Task.start(fn -> send_tcp(peer_id, host, port, data) end)
    end)

    :ok
  end

  defp send_tcp(peer_id, host, port, binary_data) do
    case :gen_tcp.connect(host, port, [:binary, active: false], 1000) do
      {:ok, socket} ->
        framed = <<byte_size(binary_data)::32-big, binary_data::binary>>
        result = :gen_tcp.send(socket, framed)
        :gen_tcp.close(socket)

        case result do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.warning("Failed to send message to peer #{peer_id}: #{inspect(reason)}")
        end

      {:error, reason} ->
        Logger.warning("Failed to connect to peer #{peer_id}: #{inspect(reason)}")
    end
  end

  defp parse_peers(peers_env) do
    (peers_env || "")
    |> String.split(",", trim: true)
    |> Enum.into(%{}, fn peer ->
      case String.split(String.trim(peer), "@", parts: 2) do
        [peer_id, host_port] ->
          [host, port] = String.split(host_port, ":", parts: 2)
          {peer_id, {String.to_charlist(host), String.to_integer(port)}}

        [host_port] ->
          [host, port] = String.split(host_port, ":", parts: 2)
          {host, {String.to_charlist(host), String.to_integer(port)}}
      end
    end)
  end

  defp send_to_python_service(payload, py_host, py_port) do
    InventoryNode.PythonClient.call(payload, py_host, py_port)
  end
end
