defmodule FileWard.Artifact do
  @moduledoc "Temporary file metadata. The path is valid only during the callback."
  @enforce_keys [:path, :size_bytes, :sha256, :detected_media_type, :source_kind]
  defstruct @enforce_keys ++ [:declared_media_type, :original_filename]

  @type t :: %__MODULE__{
          path: Path.t(),
          size_bytes: non_neg_integer(),
          sha256: String.t(),
          detected_media_type: String.t(),
          declared_media_type: binary() | nil,
          original_filename: binary() | nil,
          source_kind: :stream | :upload | :url
        }
end
