defmodule InventoryNode.Mempool do
  use GenServer
  require Logger

  # --- API Pubblica ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, opts ++ [name: __MODULE__])
  end

  @doc """
  Aggiunge una nuova transazione (inbound/outbound) alla mempool.
  Il tx_id dovrebbe essere un hash univoco della transazione.
  """
  def add_transaction(tx_id, tx_data) do
    GenServer.cast(__MODULE__, {:add_transaction, tx_id, tx_data})
  end

  @doc """
  Recupera tutte le transazioni in attesa (usata dal Leader per creare un nuovo blocco).
  """
  def get_pending_transactions() do
    GenServer.call(__MODULE__, :get_pending)
  end

  @doc """
  Invocata quando il cluster accetta un nuovo blocco.
  Rimuove le transazioni confermate e ritrasmette quelle scartate.
  """
  def reconcile_block(confirmed_tx_ids, current_leader_id) do
    GenServer.cast(__MODULE__, {:reconcile_block, confirmed_tx_ids, current_leader_id})
  end

  # --- Callback del GenServer ---

  @impl true
  def init(:ok) do
    # Lo stato è una mappa vuota: %{tx_id => tx_data}
    # Usare una mappa permette rimozioni e ricerche super veloci (O(1))
    Logger.info("Mempool avviata.")
    {:ok, %{}}
  end

  @impl true
  def handle_cast({:add_transaction, tx_id, tx_data}, state) do
    # Se la transazione è già presente, Map.put la sovrascrive (evita duplicati)
    new_state = Map.put(state, tx_id, tx_data)
    Logger.debug("Aggiunta transazione alla mempool: #{tx_id}")
    {:noreply, new_state}
  end

  @impl true
  def handle_call(:get_pending, _from, state) do
    # Restituisce la lista di tutte le transazioni in attesa
    {:reply, Map.values(state), state}
  end

  @impl true
  def handle_cast({:reconcile_block, confirmed_tx_ids, current_leader_id}, state) do
    # 1. Rimuoviamo dalla Mempool tutte le transazioni incluse nel blocco appena salvato
    # Map.drop elimina dalla mappa tutte le chiavi presenti in `confirmed_tx_ids`
    unconfirmed_state = Map.drop(state, confirmed_tx_ids)

    # 2. Otteniamo il nostro ID nodo per capire se siamo noi il leader
    my_node_id = System.get_env("NODE_ID")

    # 3. Se ci sono transazioni rimaste fuori dal blocco E NON siamo noi il leader,
    # le ritrasmettiamo al leader in carica.
    if map_size(unconfirmed_state) > 0 and my_node_id != current_leader_id do
      Logger.info("Trovate #{map_size(unconfirmed_state)} transazioni non confermate nel nuovo blocco. Ritrasmissione in corso...")

      Enum.each(unconfirmed_state, fn {tx_id, tx_data} ->
        Logger.debug("Ritrasmissione della transazione #{tx_id} al leader #{current_leader_id}")

        # Qui invochi la funzione che manda il dato al leader via TCP
        # Esempio: InventoryNode.Network.send_to_leader(current_leader_id, {:add_transaction, tx_id, tx_data})
      end)
    end

    # Lo stato si aggiorna mantenendo solo le transazioni che non sono ancora in un blocco
    {:noreply, unconfirmed_state}
  end


end
