defmodule InventoryNode.SimBehaviour do
  @moduledoc """
  Stato di comportamento simulato del nodo (per test). Modalità:

    * `:healthy`    -> comportamento normale (default)
    * `:noclients`  -> il nodo parla con gli altri nodi ma non risponde ai
                       client (gate lato Python)
    * `:noresponse` -> il nodo non comunica con nessuno: il ClusterListener
                       accetta e scarta le connessioni, il Router ignora i
                       payload e i broadcast vengono soppressi (il backend
                       Python risponde solo agli endpoint simbehaviour)
    * `:bizantine`  -> il nodo si comporta in modo bizantino: non inoltra le
                       transazioni ricevute dai client e il backend produce
                       firme/proposte/blocchi fasulli

  Lo stato è condiviso tra motore Elixir e backend Python: l'endpoint Python
  `POST /api/v1/simbehaviour/{mode}` inoltra la richiesta a questo nodo via
  l'HTTP listener (`POST /api/v1/simbehaviour`). Il valore è volatile e torna
  a `healthy` al riavvio del nodo.
  """

  @key {__MODULE__, :mode}

  def modes, do: ["healthy", "noclients", "noresponse", "bizantine"]

  def get do
    :persistent_term.get(@key, :healthy)
  end

  def set("healthy"), do: put(:healthy)
  def set("noclients"), do: put(:noclients)
  def set("noresponse"), do: put(:noresponse)
  def set("bizantine"), do: put(:bizantine)
  def set(_), do: {:error, :unknown_mode}

  defp put(mode) do
    :persistent_term.put(@key, mode)
    {:ok, mode}
  end
end
