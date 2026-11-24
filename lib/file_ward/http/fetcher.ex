defmodule FileWard.HTTP.Fetcher do
  @moduledoc false
  alias FileWard.Error
  alias FileWard.HTTP.{AddressPolicy, Resolver, URL}
  alias Mint.HTTP

  def fetch(url, policy, state, write) do
    fetch(url, policy, state, write, &Resolver.resolve/2, &AddressPolicy.public?/1, [])
  end

  # Internal seam used by local TLS tests. Public options never reach it.
  def fetch(url, policy, state, write, resolve, allowed?, trusted_roots) do
    deadline = now() + policy.total_timeout_ms

    with {:ok, target} <- URL.parse(url),
         {:ok, addresses} <- addresses(target, resolve, deadline),
         {:ok, ip} <- select(addresses, allowed?),
         {:ok, conn} <-
           connect(ip, target, trusted_roots, min(deadline - now(), policy.idle_timeout_ms)) do
      try do
        request(conn, target, state, write, policy, deadline)
      after
        HTTP.close(conn)
      end
    end
  end

  defp addresses(%{ip: nil, host: host}, resolve, deadline), do: resolve.(host, deadline)
  defp addresses(%{ip: ip}, _, _), do: {:ok, [ip]}

  defp select([], _), do: Error.result(:resolve, :dns_failed)

  defp select([ip | _] = addresses, allowed?) do
    if Enum.all?(addresses, allowed?),
      do: {:ok, ip},
      else: Error.result(:resolve, :unsafe_address)
  end

  defp connect(_, _, _, timeout) when timeout <= 0, do: Error.result(:connect, :timeout)

  defp connect(ip, target, trusted_roots, timeout) do
    tls = [
      verify: :verify_peer,
      log_level: :none,
      timeout: timeout,
      send_timeout: timeout,
      max_handshake_size: 65_536,
      versions: [:"tlsv1.3", :"tlsv1.2"]
    ]

    tls = if trusted_roots == [], do: tls, else: Keyword.put(tls, :cacerts, trusted_roots)

    tls =
      if target.ip,
        do: tls ++ [server_name_indication: :disable, verify_fun: {&verify_ip/3, ip}],
        else: tls

    case HTTP.connect(:https, ip, target.port,
           hostname: target.host,
           protocols: [:http1],
           mode: :passive,
           max_header_list_size: 16_384,
           transport_opts: tls
         ) do
      {:ok, conn} ->
        {:ok, conn}

      {:error, %Mint.TransportError{reason: :timeout}} ->
        Error.result(:connect, :timeout)

      {:error, %Mint.TransportError{reason: {:tls_alert, _}}} ->
        Error.result(:connect, :tls_failed)

      {:error, _} ->
        Error.result(:connect, :network_error)
    end
  end

  defp verify_ip(_, {:bad_cert, reason}, _), do: {:fail, reason}
  defp verify_ip(_, {:extension, _}, ip), do: {:unknown, ip}
  defp verify_ip(_, :valid, ip), do: {:valid, ip}

  defp verify_ip(cert, :valid_peer, ip) do
    if :public_key.pkix_verify_hostname(cert, ip: ip),
      do: {:valid, ip},
      else: {:fail, :hostname_check_failed}
  end

  defp request(conn, target, state, write, policy, deadline) do
    headers = [
      {"host", target.authority},
      {"accept-encoding", "identity"},
      {"connection", "close"}
    ]

    case HTTP.request(conn, "GET", target.target, headers, nil) do
      {:ok, conn, ref} ->
        receive_body(
          conn,
          %{ref: ref, phase: :status, writer: state, declared: nil},
          write,
          policy,
          deadline
        )

      {:error, _, _} ->
        Error.result(:connect, :network_error)
    end
  end

  defp receive_body(conn, state, write, policy, deadline) do
    timeout = min(policy.idle_timeout_ms, deadline - now())
    stage = if state.phase in [:status, :headers], do: :headers, else: :body

    if timeout <= 0 do
      Error.result(stage, :timeout)
    else
      case HTTP.recv(conn, 0, timeout) do
        {:ok, conn, events} ->
          case consume(events, state, write, policy, deadline) do
            {:ok, %{phase: :done} = complete} ->
              {:ok, complete.writer, [content_type: complete.declared]}

            {:ok, next} ->
              receive_body(conn, next, write, policy, deadline)

            error ->
              error
          end

        {:error, _, %Mint.TransportError{reason: :timeout}, _} ->
          Error.result(stage, :timeout)

        {:error, _, %Mint.TransportError{}, _} ->
          Error.result(stage, :network_error)

        {:error, _, _, _} ->
          Error.result(stage, :invalid_response)
      end
    end
  end

  defp consume([], state, _, _, _), do: {:ok, state}

  defp consume([event | rest], state, write, policy, deadline) do
    if now() >= deadline do
      Error.result(:body, :timeout)
    else
      with {:ok, next} <- event(event, state, write, policy) do
        consume(rest, next, write, policy, deadline)
      end
    end
  end

  defp event({:status, ref, status}, %{ref: ref, phase: :status} = state, _, _) do
    cond do
      status in 300..399 -> Error.result(:headers, :redirect_forbidden)
      status == 200 -> {:ok, %{state | phase: :headers}}
      true -> Error.result(:headers, :unexpected_status)
    end
  end

  defp event({:headers, ref, headers}, %{ref: ref, phase: :headers} = state, _, policy) do
    length_values = values(headers, "content-length")
    transfer = values(headers, "transfer-encoding")
    encoding = values(headers, "content-encoding")
    declared = values(headers, "content-type")

    with true <-
           length(headers) <= 100 and length(declared) <= 1 and encoding in [[], ["identity"]],
         {:ok, expected} <- framing(length_values, transfer, policy.max_bytes) do
      {:ok, Map.merge(state, %{phase: :body, declared: List.first(declared), expected: expected})}
    else
      false -> Error.result(:headers, :invalid_response)
      error -> error
    end
  end

  defp event({:data, ref, chunk}, %{ref: ref, phase: :body} = state, write, _) do
    with {:ok, writer} <- write.(chunk, state.writer), do: {:ok, %{state | writer: writer}}
  end

  defp event({:done, ref}, %{ref: ref, phase: :body, expected: expected} = state, _, _) do
    if expected == :chunked or expected == state.writer.size,
      do: {:ok, %{state | phase: :done}},
      else: Error.result(:body, :invalid_response)
  end

  defp event(_, _, _, _), do: Error.result(:headers, :invalid_response)

  defp framing([], ["chunked"], _), do: {:ok, :chunked}

  defp framing([value], [], max) when byte_size(value) <= 20 do
    if Regex.match?(~r/\A[0-9]+\z/, value) do
      size = String.to_integer(value)
      if size <= max, do: {:ok, size}, else: Error.result(:headers, :too_large)
    else
      Error.result(:headers, :invalid_response)
    end
  end

  defp framing(_, _, _), do: Error.result(:headers, :invalid_response)

  defp values(headers, name), do: for({^name, value} <- headers, do: value)
  defp now, do: System.monotonic_time(:millisecond)
end
