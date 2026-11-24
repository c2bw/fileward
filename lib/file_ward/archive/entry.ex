defmodule FileWard.Archive.Entry do
  @moduledoc "Metadata for a verified extracted ZIP entry. The path is relative to the archive directory."
  @enforce_keys [:path, :kind, :size_bytes, :compressed_bytes, :crc32]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          path: String.t(),
          kind: :file | :directory,
          size_bytes: non_neg_integer(),
          compressed_bytes: non_neg_integer(),
          crc32: non_neg_integer()
        }
end
