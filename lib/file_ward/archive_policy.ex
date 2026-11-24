defmodule FileWard.ArchivePolicy do
  @moduledoc "Validated limits for ordinary ZIP extraction."
  alias FileWard.Policy

  @defaults [
    max_entries: 500,
    max_total_uncompressed_bytes: 100 * 1024 * 1024,
    max_entry_bytes: 20 * 1024 * 1024,
    max_path_depth: 12,
    max_expansion_ratio: 100,
    allowed_extensions: [],
    reject_links: true,
    reject_nested_archives: true
  ]
  defstruct @defaults
  @type t :: %__MODULE__{}

  @spec new!(keyword()) :: t()
  def new!(options) do
    policy = struct!(__MODULE__, Policy.validate_keys!(options, @defaults))
    if valid?(policy), do: policy, else: raise(ArgumentError, "invalid FileWard archive policy")
  end

  @doc false
  def valid?(%__MODULE__{} = p) do
    Policy.positive?(p.max_entries, 65_534) and
      Policy.positive?(p.max_total_uncompressed_bytes, 1_099_511_627_776) and
      Policy.positive?(p.max_entry_bytes, 4_294_967_294) and
      Policy.positive?(p.max_path_depth, 64) and
      Policy.positive?(p.max_expansion_ratio, 1_000_000) and
      p.reject_links == true and is_boolean(p.reject_nested_archives) and
      is_list(p.allowed_extensions) and p.allowed_extensions != [] and
      Enum.all?(p.allowed_extensions, fn ext ->
        is_binary(ext) and Regex.match?(~r/\A\.[a-z0-9]{1,16}\z/, ext)
      end)
  end

  def valid?(_), do: false
end
