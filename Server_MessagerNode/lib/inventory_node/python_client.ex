defmodule InventoryNode.PythonClient do
  @moduledoc """
  Minimal HTTP client for talking to the Python backend over stdlib-only HTTP.

  Elixir has no project dependencies, so we use Erlang's built-in `:httpc`
  (part of the OTP `inets` application) instead of adding a new Hex dep.
  Requests are synchronous POSTs of a JSON body; the response is parsed back
  into a map.

  The Python backend is a FastAPI service sharing the single container port
  8000 for both clients and this engine (routed by URL path):
    http://<PYTHON_HOST>:<PYTHON_PORT>/api/v1/<endpoint>

  Each endpoint accepts a flat JSON object with a `"flag"` field that selects
  the operation. This module sends the whole payload and returns the parsed
  JSON object that the Python service responds with.
  """

  @default_timeout 5000

  @doc """
  POST `payload` (a map) to `python_host`:`python_port` and return the parsed
  JSON response map.

  Returns `{:ok, map}` on success, `{:error, reason}` otherwise.
  """
  def call(payload, python_host, python_port) do
    # httpc richiede l'URL come charlist e, per i POST, content-type e body
    # inseriti nella tupla di richiesta (il Body come 4° argomento è ignorato
    # e produce :invalid_request su OTP recenti).
    url = (python_url(python_host, python_port) <> "/python_call") |> to_charlist()

    case :httpc.request(
           :post,
           {url, [], ~c"application/json", JSON.encode!(payload)},
           [timeout: @default_timeout],
           []
         ) do
      {:ok, {{_http_version, 200, _status}, _headers, body}} ->
        case JSON.decode(body) do
          {:ok, decoded} -> {:ok, decoded}
          {:error, reason} -> {:error, "malformed JSON response: #{inspect(reason)}"}
        end

      {:ok, {{_http_version, status, _status_line}, _headers, body}} ->
        {:error, "python responded with HTTP #{status}: #{body}"}

      {:error, reason} ->
        {:error, "httpc request failed: #{inspect(reason)}"}
    end
  end

  defp python_url(python_host, python_port) do
    "http://#{python_host}:#{python_port}/api/v1"
  end
end