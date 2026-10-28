defmodule InventoryNode.ConsensusEngine do
  use GenServer
  require Logger

  # tempo massimo per chiudere un blocco prima di cambiare Proposer
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

    # In PBFT tutti i nodi (incluso se stesso) formano la lista dei validatori
    validator_nodes = Enum.sort([node_id | Map.keys(peers)])
    total_nodes = length(validator_nodes)

    # N = 3f + 1 -> Quorum = 2f + 1
    # 4 nodi -> f=1 -> Quorum = 3
    f = div(total_nodes - 1, 3)
    quorum = 2 * f + 1

    state = %{
      node_id: node_id,
      peers: peers,
      validators: validator_nodes,
      python_host: python_host,
      python_port: python_port,
      quorum: quorum,

      # Stato BFT
      # numero del blocco
      current_height: nil,
      # tentativo corrente per questa altezza
      current_round: 0,
      timer_ref: nil,
      timeout_token: nil,
      temporary_signature: nil,

      # contatori per le fasi BFT (prepare_votes ora mappa validator_id => signature)
      prepare_votes: %{},
      commit_votes: %{},
      commit_started: false,
      round_change_started: false,
      round_change_votes: %{},

      # Dati del blocco in lavorazione
      pending_block: nil
    }

    Logger.info("BFT-PoA Modificato Avviato. Nodo: #{node_id}. Quorum: #{quorum}/#{total_nodes}")
    send(self(), :initialize_from_python)
    {:ok, state}
  end

  # GESTIONE DEL ROUND E PROPOSER (ROUND-ROBIN)

  defp schedule_round_timeout(state) do
    if state.timer_ref, do: Process.cancel_timer(state.timer_ref)
    token = make_ref()
    timer_ref = Process.send_after(self(), {:round_timeout, token}, @round_timeout)
    %{state | timer_ref: timer_ref, timeout_token: token}
  end

  defp start_round(state) do
    timed_state = schedule_round_timeout(state)

    # il proposer è deterministico: (altezza + round) mod (numero totale di nodi)
    proposer_index = rem(state.current_height + state.current_round, length(state.validators))
    current_proposer = Enum.at(state.validators, proposer_index)

    # pulisce i voti del round precedente
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
        "[Altezza #{state.current_height}] Sono il Proposer (Round #{state.current_round}); attendo il trigger Python."
      )
    else
      Logger.info("[Altezza #{state.current_height}] Proposer atteso: #{current_proposer}")
    end

    new_state
  end

  @impl true
  def handle_info(:initialize_from_python, state) do
    case send_to_python_service(%{"flag" => "chain_state"}, state.python_host, state.python_port) do
      {:ok, %{"next_height" => height}} when is_integer(height) and height > 0 ->
        Logger.info("Altezza iniziale sincronizzata con Python: #{height}")
        {:noreply, start_round(%{state | current_height: height})}

      {:ok, response} ->
        Logger.error("Python ha restituito uno stato blockchain non valido: #{inspect(response)}")
        Process.send_after(self(), :initialize_from_python, 1_000)
        {:noreply, state}

      {:error, reason} ->
        Logger.error("Impossibile leggere lo stato blockchain da Python: #{reason}")
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
          "Trigger proposta ricevuto da Python: #{reason}, #{pending_count} transazioni pendenti."
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

  @impl true
  def handle_info({:round_timeout, token}, %{timeout_token: token} = state) do
    if state.commit_started do
      Logger.warning(
        "COMMIT del blocco #{state.current_height} ancora in corso; attendo il quorum invece di cambiare round."
      )

      {:noreply, schedule_round_timeout(state)}
    else
      target_round = state.current_round + 1

      Logger.warning(
        "Timeout blocco #{state.current_height}. Avvio fase ROUND_CHANGE verso il round #{target_round}"
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
          Logger.error("Impossibile firmare ROUND_CHANGE per timeout: #{inspect(other)}")
      end

      {:noreply, %{state | round_change_started: true}}
    end
  end

  def handle_info({:round_timeout, _stale_token}, state), do: {:noreply, state}

  # ROUND CHANGE

  @impl true
  def handle_cast({:round_change, payload}, state) do
    engine_pid = self()
    verification_payload = Map.put(payload, "flag", "verified_round_change")

    Task.start(fn ->
      case send_to_python_service(verification_payload, state.python_host, state.python_port) do
        {:ok, %{"status" => is_valid}} when is_boolean(is_valid) ->
          send(
            engine_pid,
            {:verified_round_change, payload["height"], payload["target_round"],
             payload["validator_id"], is_valid}
          )

        other ->
          Logger.warning("Verifica ROUND_CHANGE fallita: #{inspect(other)}")
      end
    end)

    {:noreply, state}
  end

  @impl true
  def handle_info({:verified_round_change, height, target_round, validator_id, true}, state) do
    if height == state.current_height and target_round > state.current_round and
         not state.commit_started do
      current_votes = Map.get(state.round_change_votes, target_round, MapSet.new())
      new_votes = MapSet.put(current_votes, validator_id)

      new_round_change_map = Map.put(state.round_change_votes, target_round, new_votes)
      new_state = %{state | round_change_votes: new_round_change_map}

      if MapSet.size(new_votes) >= state.quorum do
        Logger.warning(
          "Quorum raggiunto per il cambio round. Transizione al round #{target_round}"
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

  def handle_info({:verified_round_change, _, _, validator_id, false}, state),
    do: ignore_bad_sig(validator_id, state)

  # FASE 1: PRE-PREPARE (proposta del leader)

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
            Logger.info(
              "Proponendo il blocco #{state.current_height}, round #{state.current_round}"
            )

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

  @impl true
  def handle_cast({:pre_prepare, height, round, proposer_id, block_data, signature}, state) do
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

  @impl true
  def handle_info(
        {:verified_pre_prepare, height, round, proposer_id, block_data, proposer_signature, true},
        state
      ) do
    expected_proposer = proposer_for(state, height, round)

    cond do
      height != state.current_height or round != state.current_round or
          proposer_id != expected_proposer ->
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
        Logger.info("Pre-Prepare valido da #{proposer_id}. Invio PREPARE unicast al proposer.")

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
            Logger.warning("Errore nella componente python per prepare: #{inspect(other)}")
            {:noreply, state}
        end
    end
  end

  def handle_info({:verified_pre_prepare, _, _, proposer_id, _, _, false}, state),
    do: ignore_bad_sig(proposer_id, state)

  # FASE 2: PREPARE (il proposer riceve le firme in unicast dai nodi)

  @impl true
  def handle_cast({:prepare_vote, height, round, block_hash, validator_id, signature}, state) do
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
            Logger.warning("Verifica PREPARE fallita per #{validator_id}: #{inspect(other)}")
        end
      end)
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(
        {:verified_prepare_vote, height, round, block_hash, validator_id, signature, true},
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
          "Quorum PREPARE raggiunto (#{map_size(new_votes)}/#{state.quorum}). " <>
            "Invio la proposta alla votazione COMMIT."
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

  def handle_info({:verified_prepare_vote, _, _, _, validator_id, _, false}, state),
    do: ignore_bad_sig(validator_id, state)

  # FASE 3: COMMIT (votazione separata dopo il certificato PREPARE)

  @impl true
  def handle_cast(
        {:commit_proposal, height, round, proposer_id, block_data, proposer_signature,
         prepare_signatures},
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
            Logger.warning("Verifica certificato PREPARE per COMMIT fallita: #{inspect(other)}")

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

  @impl true
  def handle_info(
        {:verified_commit_proposal, height, round, proposer_id, block_data, proposer_signature,
         prepare_signatures, true},
        state
      ) do
    expected_proposer = proposer_for(state, height, round)

    cond do
      height != state.current_height or round != state.current_round or
          proposer_id != expected_proposer ->
        {:noreply, state}

      state.commit_started ->
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

  def handle_info(
        {:verified_commit_proposal, _, _, proposer_id, _, _, _, false},
        state
      ),
      do: ignore_bad_sig(proposer_id, state)

  @impl true
  def handle_cast(
        {:commit_vote, height, round, proposer_id, block_data, proposer_signature,
         prepare_signatures, block_hash, validator_id, signature},
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
            Logger.warning("Prova PREPARE non valida nel voto COMMIT di #{validator_id}")

          other ->
            Logger.warning("Verifica voto COMMIT fallita per #{validator_id}: #{inspect(other)}")
        end
      end)
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(
        {:verified_commit_vote, height, round, proposer_id, block_data, proposer_signature,
         prepare_signatures, block_hash, validator_id, signature, true},
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

        Logger.warning("Voto COMMIT concorrente ignorato per il blocco #{block_hash}")
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

  def handle_info(
        {:verified_commit_vote, _, _, _, _, _, _, _, validator_id, _, false},
        state
      ),
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
          Logger.error("Firma COMMIT non disponibile: #{inspect(other)}")
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
      "Quorum COMMIT raggiunto (#{map_size(state.commit_votes)}/#{state.quorum}). " <>
        "Scrittura del blocco #{height}."
    )

    write_payload = %{
      "flag" => "write_block",
      "height" => height,
      "block_data" => state.pending_block
    }

    case send_to_python_service(write_payload, state.python_host, state.python_port) do
      {:ok, %{"status" => true}} ->
        Logger.info("Blocco #{height} scritto correttamente sul servizio Python.")

        new_state = %{
          state
          | current_height: state.current_height + 1,
            current_round: 0,
            pending_block: nil,
            temporary_signature: nil,
            prepare_votes: %{},
            commit_votes: %{},
            commit_started: false,
            round_change_votes: %{}
        }

        {:noreply, start_round(new_state)}

      other ->
        Logger.error("Errore nella scrittura del blocco #{height}: #{inspect(other)}")
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
          Logger.warning("Nessuna prova valida di doppia proposta: #{inspect(other)}")
      end
    end)

    :ok
  end

  @impl true
  def handle_info({:broadcast_round_change, payload}, state) do
    broadcast_to_all(state.peers, {:round_change, payload})
    {:noreply, state}
  end

  # Funzioni di supporto

  defp proposer_for(state, height, round)
       when is_integer(height) and height > 0 and is_integer(round) and round >= 0 do
    Enum.at(state.validators, rem(height + round, length(state.validators)))
  end

  defp proposer_for(_state, _height, _round), do: nil

  defp ignore_bad_sig(node_id, state) do
    Logger.error("Firma invalida da #{node_id}. Possibile nodo Bizantino!")
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

  # Invio unicast mirato (es. inviare la firma prepare solo al proposer)
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
          Logger.error("Impossibile trovare host/port per il target unicast #{target_id}")
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

      case Task.start(fn -> send_tcp(peer_id, host, port, data) end) do
        {:ok, _pid} ->
          :ok

        {:error, reason} ->
          Logger.error("Impossibile avviare l'invio al peer #{peer_id}: #{inspect(reason)}")
      end
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
            Logger.warning("Invio al peer #{peer_id} fallito: #{inspect(reason)}")
        end

      {:error, reason} ->
        Logger.warning("Connessione al peer #{peer_id} fallita: #{inspect(reason)}")
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
