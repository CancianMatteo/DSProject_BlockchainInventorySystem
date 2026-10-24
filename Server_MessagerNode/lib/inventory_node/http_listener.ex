defmodule InventoryNode.HTTPListener do
  @moduledoc """
  Minimal, dependency-free HTTP/1.1 listener so the Python backend (using
  `httpx`) can POST JSON payloads to this Elixir node.

  This is separate from the `ClusterListener`, which keeps speaking the
  Erlang-term wire protocol (`binary_to_term`) for intra-cluster gossip on
  port 4000. This listener binds the per-node simbehaviour port (default 4001;
  deployed as 6001..6004 via ELIXIR_HTTP_PORT) and handles
  `POST /api/v1/simbehaviour` (mode forwarding from Python) and
  `POST /api/v1/python_call` (JSON payloads routed through
  `InventoryNode.Router`).

  Port map per node: Python owns 8000 in its own container (clients AND
  Elixir share that one socket, routed by URL path), Elixir owns 4000
  (cluster) + 600x (this listener, per node). No split of 8000 is needed.

  The listener reads a single HTTP request, dispatches it, writes a minimal
  HTTP/1.1 response with `Content-Length` and `Connection: close`. It does not
  implement keep-alive or HTTP/2.
  """
  require Logger

  @default_port 4001

  @doc """
  Child specification so the listener can be started as a supervisor child
  via `{InventoryNode.HTTPListener, []}`.
  """
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 5_000
    }
  end

  @doc """
  Start the HTTP listener on the port given by the `ELIXIR_HTTP_PORT` env var
  (default `4001`). Accepts an (ignored) argument so the listener can be
  started as a supervisor child via `{InventoryNode.HTTPListener, []}`.
  """
  def start_link(_opts \\ []) do
    port = http_port()

    {:ok, pid} =
      Task.start_link(fn ->
        {:ok, socket} =
          :gen_tcp.listen(port, [:binary, packet: :raw, active: false, reuseaddr: true])

        Logger.info("HTTP Listener (Elixir) in ascolto su http://0.0.0.0:#{port} (per il backend Python)")
        loop_acceptor(socket)
      end)

    {:ok, pid}
  end

  defp http_port do
    case System.get_env("ELIXIR_HTTP_PORT") do
      nil -> @default_port
      "" -> @default_port
      value -> String.to_integer(value)
    end
  end

  defp loop_acceptor(socket) do
    case :gen_tcp.accept(socket) do
      {:ok, client} ->
        Task.start(fn -> serve(client) end)
        loop_acceptor(socket)

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        Logger.error("HTTP listener accept error: #{inspect(reason)}")
        loop_acceptor(socket)
    end
  end

  defp serve(client) do
    case read_request(client) do
      {:ok, %{method: "POST", path: path, headers: headers, body: body}} ->
        :gen_tcp.send(client, build_response(dispatch(path, headers, body)))

      {:ok, _} ->
        :gen_tcp.send(client, build_response({405, "Method Not Allowed", %{"error" => "method not allowed"}}))

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        Logger.warning("HTTP request read error: #{inspect(reason)}")
        :ok
    end

    :gen_tcp.close(client)
  end

  # ---- HTTP plumbing ----
  #
  # Un client può inviare riga di richiesta, intestazioni e corpo in un unico
  # segmento TCP: il buffer viene accumulato fino al marcatore "\r\n\r\n" e
  # poi splittato, anziché assumere che il primo recv restituisca solo la
  # riga di richiesta (il che produceva :bad_request su ogni richiesta).

  @head_terminator "\r\n\r\n"

  defp read_request(socket) do
    case recv_until(socket, "", @head_terminator) do
      {:ok, buffer} ->
        {head, leftover} = split_head(buffer)

        case String.split(head, "\r\n") do
          [request_line | header_lines] ->
            case String.split(request_line, " ") do
              [method, path, version] ->
                headers = parse_headers(header_lines)
                body = read_body(socket, headers, leftover)
                {:ok, %{method: method, path: path, version: version, headers: headers, body: body}}

              _ ->
                {:error, :bad_request}
            end

          [] ->
            {:error, :bad_request}
        end

      {:error, :closed} ->
        {:error, :closed}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp recv_until(socket, acc, terminator) do
    if String.contains?(acc, terminator) do
      {:ok, acc}
    else
      case :gen_tcp.recv(socket, 0, 5000) do
        {:ok, data} -> recv_until(socket, acc <> data, terminator)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp split_head(buffer) do
    case :binary.match(buffer, @head_terminator) do
      {position, length_} ->
        {
          binary_part(buffer, 0, position),
          binary_part(buffer, position + length_, byte_size(buffer) - position - length_)
        }

      :nomatch ->
        {buffer, ""}
    end
  end

  defp parse_headers(lines) do
    Enum.reduce(lines, %{}, fn line, headers ->
      case String.split(line, ":", parts: 2) do
        # I nomi delle intestazioni HTTP non distinguono le maiuscole.
        [key, value] -> Map.put(headers, String.downcase(String.trim(key)), String.trim(value))
        _ -> headers
      end
    end)
  end

  defp read_body(socket, headers, leftover) do
    case Map.get(headers, "content-length") do
      nil ->
        leftover

      cl ->
        case Integer.parse(cl) do
          {len, _} when len >= 0 ->
            if byte_size(leftover) >= len do
              binary_part(leftover, 0, len)
            else
              leftover <> recv_exact(socket, len - byte_size(leftover))
            end

          _ ->
            leftover
        end
    end
  end

  defp recv_exact(_socket, 0), do: ""

  defp recv_exact(socket, remaining) do
    case :gen_tcp.recv(socket, min(remaining, 65536), 5000) do
      {:ok, ""} ->
        ""

      {:ok, data} ->
        data <> recv_exact(socket, remaining - byte_size(data))

      {:error, reason} ->
        Logger.warning("HTTP body read error: #{inspect(reason)}")
        ""
    end
  end

  # dispatch/3 returns {status, reason, json_body}; serve/1 serialises it.

  # Imposta lo stato di comportamento simulato del nodo (vedi InventoryNode.SimBehaviour).
  defp dispatch("/api/v1/simbehaviour", _headers, body) do
    case JSON.decode(body) do
      {:ok, %{"mode" => mode}} when is_binary(mode) ->
        case InventoryNode.SimBehaviour.set(mode) do
          {:ok, set_mode} ->
            {200, "OK", %{"ok" => true, "mode" => to_string(set_mode)}}

          {:error, _} ->
            {400, "Bad Request", %{"error" => "unknown mode", "allowed" => InventoryNode.SimBehaviour.modes()}}
        end

      _ ->
        {400, "Bad Request", %{"error" => "expected a JSON body like {\"mode\": \"healthy\"}"}}
    end
  end

  defp dispatch("/api/v1/python_call", _headers, body) do
    case JSON.decode(body) do
      {:ok, payload} when is_map(payload) ->
        InventoryNode.Router.handle_payload(payload)
        {200, "OK", %{"ok" => true, "routed" => true}}

      {:ok, _payload} ->
        {400, "Bad Request", %{"error" => "expected a JSON object"}}

      {:error, _} ->
        {400, "Bad Request", %{"error" => "invalid JSON"}}
    end
  end

  defp dispatch(path, _headers, body) do
    {404, "Not Found", %{"error" => "unknown endpoint", "path" => path, "body" => body}}
  end

  defp build_response({status, reason, body}) do
    body_bytes = JSON.encode!(body)

    "HTTP/1.1 #{status} #{reason}\r\n" <>
      "Content-Type: application/json\r\n" <>
      "Content-Length: #{byte_size(body_bytes)}\r\n" <>
      "Connection: close\r\n" <>
      "\r\n" <>
      body_bytes
  end
end
