defmodule FileWard.Archive.Extractor do
  @moduledoc false
  alias FileWard.{Error, Signatures}
  alias FileWard.Archive.ZipReader

  def extract(file, records, root, policy) do
    Enum.reduce_while(records, {:ok, 0}, fn record, {:ok, total} ->
      entry = record.entry
      destination = Path.join(root, entry.path)

      result =
        if entry.kind == :directory do
          with :ok <- directories(root, entry.path), do: {:ok, total}
        else
          with :ok <- directories(root, Path.dirname(entry.path)),
               {:ok, writer} <- open_output(destination) do
            try do
              write_entry(file, writer, record, total, policy)
            after
              :file.close(writer)
            end
          end
        end

      case result do
        {:ok, total} -> {:cont, {:ok, total}}
        error -> {:halt, error}
      end
    end)
  end

  defp directories(_root, "."), do: :ok

  defp directories(root, relative) do
    Enum.reduce_while(String.split(relative, "/"), root, fn segment, parent ->
      directory = Path.join(parent, segment)

      case File.mkdir(directory) do
        :ok ->
          case storage(File.chmod(directory, 0o700)) do
            :ok -> {:cont, directory}
            error -> {:halt, error}
          end

        {:error, :eexist} ->
          case File.lstat(directory) do
            {:ok, %{type: :directory}} -> {:cont, directory}
            _ -> {:halt, Error.result(:extract, :storage_error)}
          end

        _ ->
          {:halt, Error.result(:extract, :storage_error)}
      end
    end)
    |> case do
      path when is_binary(path) -> :ok
      error -> error
    end
  end

  defp open_output(path) do
    case File.open(path, [:write, :exclusive, :binary, :raw]) do
      {:ok, writer} ->
        case storage(File.chmod(path, 0o600)) do
          :ok ->
            {:ok, writer}

          error ->
            :file.close(writer)
            error
        end

      _ ->
        Error.result(:extract, :storage_error)
    end
  end

  defp write_entry(file, writer, record, total, policy) do
    entry = record.entry

    cap =
      Enum.min([
        entry.size_bytes,
        policy.max_entry_bytes,
        policy.max_total_uncompressed_bytes - total,
        entry.compressed_bytes * policy.max_expansion_ratio
      ])

    accumulator = %{size: 0, crc: 0, prefix: <<>>}
    write = &write_chunk(writer, &1, &2, cap)

    with {:ok, result} <- decode(file, record, write, accumulator),
         true <- result.size == entry.size_bytes and result.crc == entry.crc32,
         true <- not policy.reject_nested_archives or not archive_signature?(result.prefix),
         :ok <- storage(:file.sync(writer)) do
      {:ok, total + result.size}
    else
      false -> Error.result(:extract, :archive_rejected)
      error -> error
    end
  end

  defp decode(file, record, write, state) do
    count = record.entry.compressed_bytes
    offset = record.data_offset

    case record.method do
      0 ->
        read_chunks(file, offset, count, write, state)

      8 ->
        zlib = :zlib.open()

        try do
          :ok = :zlib.inflateInit(zlib, -15, :error)

          with {:ok, result} <-
                 read_chunks(file, offset, count, &inflate(zlib, &1, &2, write), state),
               :ok <- :zlib.inflateEnd(zlib) do
            {:ok, result}
          end
        rescue
          ErlangError -> Error.result(:extract, :archive_rejected)
        after
          :zlib.close(zlib)
        end
    end
  end

  defp read_chunks(_, _, 0, _, state), do: {:ok, state}

  defp read_chunks(file, offset, remaining, consume, state) do
    count = min(remaining, 16_384)

    case ZipReader.read_at(file, offset, count) do
      {:ok, chunk} ->
        with {:ok, next} <- consume.(chunk, state) do
          read_chunks(file, offset + count, remaining - count, consume, next)
        end

      :error ->
        Error.result(:extract, :archive_rejected)
    end
  end

  defp inflate(zlib, input, state, write) do
    case :zlib.safeInflate(zlib, input) do
      {:finished, output} ->
        write.(output, state)

      {:continue, output} ->
        with {:ok, next} <- write.(output, state), do: inflate(zlib, <<>>, next, write)

      _ ->
        Error.result(:extract, :archive_rejected)
    end
  end

  defp write_chunk(writer, chunk, state, cap) do
    size = state.size + IO.iodata_length(chunk)

    if size > cap do
      Error.result(:extract, :archive_rejected)
    else
      with :ok <- storage(:file.write(writer, chunk)) do
        count = min(size - state.size, 512 - byte_size(state.prefix))

        prefix =
          if count == 0 do
            state.prefix
          else
            state.prefix <> binary_part(IO.iodata_to_binary(chunk), 0, count)
          end

        {:ok, %{size: size, crc: :erlang.crc32(state.crc, chunk), prefix: prefix}}
      end
    end
  end

  defp archive_signature?(<<31, 139, _::binary>>), do: true
  defp archive_signature?(<<"BZh", _::binary>>), do: true
  defp archive_signature?(<<253, "7zXZ", 0, _::binary>>), do: true
  defp archive_signature?(<<"7z", 188, 175, 39, 28, _::binary>>), do: true
  defp archive_signature?(<<"Rar!", 26, 7, _::binary>>), do: true
  defp archive_signature?(<<_::binary-size(257), "ustar", _::binary>>), do: true
  defp archive_signature?(prefix), do: Signatures.detect(prefix) == "application/zip"

  defp storage(:ok), do: :ok
  defp storage(_), do: Error.result(:extract, :storage_error)
end
