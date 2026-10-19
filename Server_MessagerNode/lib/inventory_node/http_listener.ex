defmodule InventoryNode.HTTPListener do
  @moduledoc """
  Minimal, dependency-free HTTP/1.1 listener so the Python backend (using
  `httpx`) can POST JSON payloads to this Elixir node.

  This is separate from the `ClusterListener`, which keeps speaking the
  Erlang-term wire protocol (`binary_to_term`) for intra-cluster gossip.
  The Python service is reachable at `http://<hostname>:<port>/api/v1/<endpoint>`
  where `<endpoint>` selects the operation by the `\"flag\"` field of the JSON body.

  The listener reads a single HTTP request, dispatches it, writes a minimal
  HTTP/1.1 response with `Content-Length` and `Connection: close`. It does not
  implement keep-alive or HTTP/2.
  """

  @default_port 4001

  @doc """
  Start the HTTP listener on the port given by the `ELIXIR_HTTP_PORT` env var
  (default `4001`).
  """
  def start_link do
    port =
      System.get_env("ELIXIR_HTTP_PORT")
      |> String.to_integer()
      |> then(fn p -> p end)
      |> Kernel.||(@default_port)

    {:ok, pid} =
      Task.start_link(fn ->
        {:ok, socket} =
          :gen_tcp.listen(port, [:binary, packet: :raw, active: false, reuseaddr: true, exit_on_close: true])

        Logger.info("HTTP Listener (Elixir) in ascolto su http://0.0.0.0:#{port} (per il backend Python)")
        loop_acceptor(socket)
      end)

    {:ok, pid}
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
        response = dispatch(path, headers, body)
        :gen_tcp.send(client, response)

      {:ok, _} ->
        send_reply(client, 405, "Method Not Allowed", ~s({"error":"method not allowed"}))

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        Logger.warning("HTTP request read error: #{inspect(reason)}")
        :ok
    end

    :gen_tcp.close(client)
  end

  # ---- HTTP plumbing ----

  defp read_request(socket) do
    case :gen_tcp.recv(socket, 0, 5000) do
      {:ok, request_line} ->
        case String.split(request_line, " ") do
          [method, path, version] ->
            {headers, body} = read_headers_and_body(socket, version)
            {:ok, %{method: method, path: path, version: version, headers: headers, body: body}}

          _ ->
            {:error, :bad_request}
        end

      {:error, :closed} ->
        {:error, :closed}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp read_headers_and_body(socket, version) do
    headers = read_headers(socket)

    case Dict.get(headers, "content-length") do
      nil ->
        {headers, ""}

      "0" ->
        {headers, ""}

      cl ->
        len = cl |> String.to_integer()

        case :gen_tcp.recv(socket, 0, 5000) do
          {:ok, body} ->
            {headers, body}

          {:error, reason} ->
            Logger.warning("HTTP body read error: #{inspect(reason)}")
            {headers, ""}
        end
    end
  end

  defp read_headers(socket) do
    headers = Dict.new()

    read_loop(headers, socket)
  end

  defp read_loop(headers, socket) do
    case :gen_tcp.recv(socket, 0, 1000) do
      {:ok, "\r\n"} ->
        headers

      {:ok, line} ->
        if String.length(line) > 0 do
          [key, value] =
            line
            |> String.split(":", parts: 2)
            |> Enum.map(&String.trim/1)

          read_loop(Dict.put(headers, key, value), socket)
        else
          headers
        end

      {:error, reason} ->
        Logger.warning("HTTP header read error: #{inspect(reason)}")
        headers
    end
  end

  defp dispatch("/api/v1/python_call", _headers, body) do
    case Jason.decode(body) do
      {:ok, payload} ->
        # Minimal Python↔Elixir echo used to validate the HTTP/JSON transport.
        # Real endpoints transparently mirror the Elixir→Python operation set and
        # are backed by the `distributed_service` module.
        json_response(200, "OK", %{"received" => true, "flag" => payload["flag"] || "nil"})

      {:error, _} ->
        json_response(400, "Bad Request", %{"error" => "invalid JSON"})
    end
  end

  defp dispatch(path, _headers, body) do
    json_response(404, "Not Found", %{"error" => "unknown endpoint", "path" => path, "body" => body})
  end

  defp send_reply(socket, status, reason, body) do
    body_bytes = body |> to_string |> String.to_binary()
    response =
      "HTTP/1.1 #{status} #{reason}\r\n" <>
        "Content-Type: application/json\r\n" <>
        "Content-Length: #{byte_size(body_bytes)}\r\n" <>
        "Connection: close\r\n" <>
        "\r\n" <>
        body_bytes

    :gen_tcp.send(socket, response)
  end

  defp json_response(status, reason, body) do
    send_reply(0, status, reason, Jason.encode!(body))
  end
end
