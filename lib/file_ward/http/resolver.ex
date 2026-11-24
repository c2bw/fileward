defmodule FileWard.HTTP.Resolver do
  @moduledoc false
  alias FileWard.Error

  def resolve(host, deadline) do
    absolute = String.to_charlist(host <> ".")

    with {:ok, v4} <- lookup(absolute, :a, deadline),
         {:ok, v6} <- lookup(absolute, :aaaa, deadline) do
      {:ok, v4 ++ v6}
    end
  end

  defp lookup(host, type, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      Error.result(:resolve, :timeout)
    else
      case :inet_res.resolve(host, :in, type, [retry: 1], remaining) do
        {:ok, {:dns_rec, _, _, answers, authority, _}} ->
          addresses = for {:dns_rr, _, ^type, :in, _, _, ip, _, _, _} <- answers, do: ip

          if addresses == [] and
               Enum.any?(answers, &(elem(&1, 2) == :cname)) and
               not Enum.any?(authority, &(elem(&1, 2) == :soa)) do
            Error.result(:resolve, :dns_failed)
          else
            {:ok, addresses}
          end

        {:error, :timeout} ->
          Error.result(:resolve, :timeout)

        _ ->
          Error.result(:resolve, :dns_failed)
      end
    end
  end
end
