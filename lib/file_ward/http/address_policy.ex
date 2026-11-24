defmodule FileWard.HTTP.AddressPolicy do
  @moduledoc false
  import Bitwise

  @ipv4 ~w(0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16
    172.16.0.0/12 192.0.0.0/24 192.0.2.0/24 192.31.196.0/24 192.52.193.0/24
    192.88.99.0/24 192.168.0.0/16 192.175.48.0/24 198.18.0.0/15
    198.51.100.0/24 203.0.113.0/24 224.0.0.0/4 240.0.0.0/4)
  @ipv6 ~w(2001::/23 2001:db8::/32 2002::/16 2620:4f:8000::/48 3fff::/20)

  for {family, cidrs, width, size} <- [{:inet, @ipv4, 8, 4}, {:inet6, @ipv6, 16, 8}] do
    ranges =
      Enum.map(cidrs, fn cidr ->
        [address, prefix] = String.split(cidr, "/")
        {:ok, tuple} = :inet.parse_strict_address(String.to_charlist(address))
        shift = size * width - String.to_integer(prefix)
        encoded = Enum.reduce(Tuple.to_list(tuple), 0, fn part, acc -> acc <<< width ||| part end)
        {encoded >>> shift, shift}
      end)

    defp ranges(unquote(family)), do: unquote(ranges)
  end

  def public?(ip) when is_tuple(ip) and tuple_size(ip) == 4, do: allowed?(ip, :inet, 8)

  def public?(ip) when is_tuple(ip) and tuple_size(ip) == 8 and elem(ip, 0) in 0x2000..0x3FFF,
    do: allowed?(ip, :inet6, 16)

  def public?(_), do: false

  defp allowed?(ip, family, width) do
    parts = Tuple.to_list(ip)

    if Enum.all?(parts, &(is_integer(&1) and &1 >= 0 and &1 < 1 <<< width)) do
      value = Enum.reduce(parts, 0, fn part, acc -> acc <<< width ||| part end)
      Enum.all?(ranges(family), fn {prefix, shift} -> value >>> shift != prefix end)
    else
      false
    end
  end
end
