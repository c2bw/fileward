defmodule FileWard.HTTP.URL do
  @moduledoc false
  alias FileWard.Error

  @url ~r{\Ahttps://([^/?]+)(/[^?]*)?(\?.*)?\z}i
  @authority ~r/\A(\[[0-9a-f:.]+\]|[a-z0-9.-]+)(?::([0-9]{1,5}))?\z/i
  @label ~r/\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\z/
  @numeric ~r/\A(?:[0-9]+|0x[0-9a-f]*)\z/
  @target ~r/\A(?:[A-Za-z0-9_~.!$&'()*+,;=:@\/?-]|%[0-9A-Fa-f]{2})*\z/

  def parse(url) when is_binary(url) and byte_size(url) <= 8192 do
    with [_, authority, path, query] <- Regex.run(@url, url, capture: :all) |> captures(4),
         [_, name, port] <- Regex.run(@authority, authority) |> captures(3),
         {:ok, host, ip} <- host(String.downcase(name)),
         port = if(port == "", do: 443, else: String.to_integer(port)),
         true <- port in 1..65_535,
         target = if(path == "", do: "/", else: path) <> query,
         true <- Regex.match?(@target, target) do
      {:ok,
       %{
         host: host,
         ip: ip,
         port: port,
         target: target,
         authority: name <> if(port == 443, do: "", else: ":#{port}")
       }}
    else
      _ -> Error.result(:validate_url, :invalid_url)
    end
  end

  def parse(_), do: Error.result(:validate_url, :invalid_url)

  defp captures(nil, _), do: nil
  defp captures(values, size), do: values ++ List.duplicate("", size - length(values))

  defp host("[" <> rest) do
    name = binary_part(rest, 0, byte_size(rest) - 1)

    case :inet.parse_ipv6strict_address(String.to_charlist(name)) do
      {:ok, ip} -> {:ok, name, ip}
      _ -> :error
    end
  end

  defp host(name) do
    labels = String.split(name, ".")

    case :inet.parse_ipv4strict_address(String.to_charlist(name)) do
      {:ok, ip} ->
        if to_string(:inet.ntoa(ip)) == name, do: {:ok, name, ip}, else: :error

      _ ->
        if byte_size(name) <= 253 and length(labels) >= 2 and
             Enum.all?(labels, &Regex.match?(@label, &1)) and
             not Regex.match?(@numeric, List.last(labels)),
           do: {:ok, name, nil},
           else: :error
    end
  end
end
