defmodule InventoryNode.SimBehaviour do
  @moduledoc """
  Simulated node behavior state (for testing). Modes:

    * `:healthy`    -> normal behavior (default)
    * `:noclients`  -> the node communicates with peers but does not respond to
                       clients (gated by Python)
    * `:noresponse` -> the node does not communicate with peers: ClusterListener
                       accepts and discards connections, Router ignores
                       payloads, and broadcasts are suppressed (the Python
                       backend responds only to simbehaviour endpoints)
    * `:bizantine`  -> valid transactions are still stored and forwarded;
                       consensus uses the fault-injection scenario configured
                       in `BIZANTINE_SCENARIO`

  The state is shared by the Elixir engine and Python backend: the Python
  endpoint `POST /api/v1/simbehaviour/{mode}` forwards the request to this node
  through the HTTP listener (`POST /api/v1/simbehaviour`). The value is
  volatile and resets to `healthy` when the node restarts.
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
