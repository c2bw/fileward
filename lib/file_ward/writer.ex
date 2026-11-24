defmodule FileWard.Writer do
  @moduledoc false
  alias FileWard.{Artifact, Error, Signatures}

  def run(directory, policy, kind, producer) do
    path = Path.join(directory, "file")

    case File.open(path, [:write, :binary, :exclusive, :raw]) do
      {:ok, file} ->
        try do
          state = %{size: 0, prefix: <<>>, hash: :crypto.hash_init(:sha256)}

          with :ok <- storage(File.chmod(path, 0o600)),
               {:ok, state, metadata} <- producer.(state, &write(file, policy, &1, &2)),
               {:ok, detected} <- detect(state, metadata, policy),
               :ok <- storage(:file.sync(file)),
               :ok <- storage(File.chmod(path, 0o400)) do
            {:ok,
             %Artifact{
               path: path,
               size_bytes: state.size,
               sha256: Base.encode16(:crypto.hash_final(state.hash), case: :lower),
               detected_media_type: detected,
               declared_media_type: metadata[:content_type],
               original_filename: metadata[:filename],
               source_kind: kind
             }}
          end
        after
          :file.close(file)
        end

      _ ->
        Error.result(:stage, :storage_error)
    end
  end

  defp write(file, policy, chunk, state) when is_binary(chunk) do
    size = state.size + byte_size(chunk)

    if size > policy.max_bytes do
      Error.result(:body, :too_large)
    else
      with :ok <- storage(:file.write(file, chunk)) do
        count = min(byte_size(chunk), policy.max_prefix_bytes - byte_size(state.prefix))

        prefix =
          if count == 0,
            do: state.prefix,
            else: :binary.copy(state.prefix <> binary_part(chunk, 0, count))

        {:ok, %{size: size, prefix: prefix, hash: :crypto.hash_update(state.hash, chunk)}}
      end
    end
  end

  defp write(_, _, _, _), do: Error.result(:body, :invalid_content)

  defp detect(state, metadata, policy) do
    detected = Signatures.detect(state.prefix)
    declared = metadata[:content_type]

    cond do
      detected not in policy.media_types ->
        Error.result(:detect, :unsupported_type)

      policy.strict_media_type and declared != nil and normalized(declared) != detected ->
        Error.result(:detect, :invalid_content)

      true ->
        {:ok, detected}
    end
  end

  defp normalized(value) do
    if String.valid?(value) do
      value |> String.split(";", parts: 2) |> hd() |> String.trim() |> String.downcase()
    end
  end

  defp storage(:ok), do: :ok
  defp storage(_), do: Error.result(:stage, :storage_error)
end
