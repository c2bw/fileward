defmodule FileWard.Archive do
  @moduledoc "A verified ZIP extraction with a directory scoped to the callback."
  alias FileWard.Error
  alias FileWard.Archive.{Entry, Extractor, ZipReader}

  @enforce_keys [:directory, :entries, :size_bytes]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          directory: Path.t(),
          entries: [Entry.t()],
          size_bytes: non_neg_integer()
        }

  @doc false
  def extract(%{detected_media_type: "application/zip"} = artifact, directory, policy) do
    case File.open(artifact.path, [:read, :raw, :binary]) do
      {:ok, file} ->
        try do
          root = Path.join(directory, "entries")

          with {:ok, records} <- ZipReader.read(file, artifact.size_bytes, policy),
               :ok <- private_directory(root),
               {:ok, total} <- Extractor.extract(file, records, root, policy) do
            {:ok,
             %__MODULE__{
               directory: root,
               entries: Enum.map(records, & &1.entry),
               size_bytes: total
             }}
          else
            :error -> Error.result(:extract, :archive_rejected)
            error -> error
          end
        after
          :file.close(file)
        end

      _ ->
        Error.result(:extract, :storage_error)
    end
  end

  def extract(_, _, _), do: Error.result(:extract, :archive_rejected)

  defp private_directory(path) do
    with :ok <- File.mkdir(path), :ok <- File.chmod(path, 0o700) do
      :ok
    else
      _ -> Error.result(:extract, :storage_error)
    end
  end
end
