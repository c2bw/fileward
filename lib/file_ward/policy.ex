defmodule FileWard.Policy do
  @moduledoc "Validated limits for file acquisition and private staging."

  import Bitwise
  @types ~w(image/png image/jpeg image/gif application/pdf application/zip)
  @defaults [
    max_bytes: 20 * 1024 * 1024,
    max_prefix_bytes: 4096,
    max_inflight: 16,
    disk_budget_bytes: 512 * 1024 * 1024,
    total_timeout_ms: 30_000,
    idle_timeout_ms: 5_000,
    strict_media_type: false,
    http: [schemes: [:https], redirects: :deny, address_scope: :public],
    media_types: [],
    staging_dir: nil
  ]
  defstruct @defaults
  @type t :: %__MODULE__{}

  @spec new!(keyword()) :: t()
  def new!(options) do
    policy = struct!(__MODULE__, validate_keys!(options, @defaults))
    if valid?(policy), do: policy, else: raise(ArgumentError, "invalid FileWard policy")
  end

  @doc false
  def validate_keys!(options, defaults) do
    unless Keyword.keyword?(options) and
             length(options) == length(Keyword.keys(options) |> Enum.uniq()) and
             Enum.all?(Keyword.keys(options), &Keyword.has_key?(defaults, &1)) do
      raise ArgumentError, "invalid or duplicate FileWard options"
    end

    options
  end

  @doc false
  def valid?(%__MODULE__{} = p) do
    positive?(p.max_bytes, 1 <<< 40) and
      positive?(p.max_prefix_bytes, 4096) and p.max_prefix_bytes >= 8 and
      positive?(p.max_inflight, 10_000) and
      positive?(p.disk_budget_bytes, 1 <<< 50) and p.disk_budget_bytes >= p.max_bytes and
      positive?(p.total_timeout_ms, 86_400_000) and positive?(p.idle_timeout_ms, 86_400_000) and
      is_boolean(p.strict_media_type) and valid_http?(p.http) and
      is_list(p.media_types) and p.media_types != [] and Enum.all?(p.media_types, &(&1 in @types)) and
      is_binary(p.staging_dir) and String.valid?(p.staging_dir) and
      not String.contains?(p.staging_dir, <<0>>) and Path.type(p.staging_dir) == :absolute and
      Path.expand(p.staging_dir) != "/"
  end

  def valid?(_), do: false

  @doc false
  def positive?(n, max), do: is_integer(n) and n > 0 and n <= max

  defp valid_http?(http) do
    defaults = @defaults[:http]

    Keyword.keyword?(http) and length(http) == length(Enum.uniq(Keyword.keys(http))) and
      Enum.all?(http, fn {key, value} -> Keyword.fetch(defaults, key) == {:ok, value} end)
  end
end
