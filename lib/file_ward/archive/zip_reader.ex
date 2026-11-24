defmodule FileWard.Archive.ZipReader do
  @moduledoc false
  import Bitwise
  alias FileWard.Archive.{Entry, PathPolicy}

  # Classic, single-disk ZIP records only. Verify both directories and require
  # contiguous, nonoverlapping local records before passing data to OTP zlib.
  def read(file, size, policy) do
    with {:ok, count, start, stop} <- end_record(file, size),
         true <- count <= policy.max_entries,
         {:ok, records} <- central(file, count, start, stop, policy, {%{}, [], 0}),
         {:ok, records} <- local(file, Enum.sort_by(records, & &1.offset), 0, start, []) do
      {:ok, records}
    else
      _ -> :error
    end
  end

  defp end_record(file, size) when size in 22..0xFFFFFFFF do
    length = min(size, 22 + 65_535)
    start = size - length

    with {:ok, tail} <- read_at(file, start, length) do
      candidates =
        for {offset, 4} <- :binary.matches(tail, <<"PK", 5, 6>>),
            length - offset >= 22,
            <<"PK", 5, 6, 0::32, disk_count::16-little, count::16-little, bytes::32-little,
              central::32-little, comment_bytes::16-little, comment::binary>> <-
              [binary_part(tail, offset, length - offset)],
            disk_count == count and count < 0xFFFF and bytes < 0xFFFFFFFF and
              central < 0xFFFFFFFF and central + bytes == start + offset and
              byte_size(comment) == comment_bytes,
            do: {count, central, central + bytes}

      case candidates do
        [{count, first, last}] -> {:ok, count, first, last}
        _ -> :error
      end
    end
  end

  defp end_record(_, _), do: :error

  defp central(_, 0, stop, stop, _, {_, entries, _}), do: {:ok, entries}

  defp central(file, count, position, stop, policy, {paths, entries, total})
       when count > 0 and position + 46 <= stop do
    with {:ok,
          <<"PK", 1, 2, _version, system, common::binary-size(22), name_size::16-little,
            extra_size::16-little, comment_size::16-little, 0::16, _internal::16,
            attributes::32-little, offset::32-little>>} <- read_at(file, position, 46),
         <<version::16-little, flags::16-little, method::16-little, _time::32, crc::32-little,
           compressed::32-little, expanded::32-little>> = common,
         true <-
           version in [10, 11, 20] and method in [0, 8] and
             (flags &&& bnot(if(method == 8, do: 0x806, else: 0x800))) == 0 and
             compressed < 0xFFFFFFFF and expanded < 0xFFFFFFFF and
             offset < 0xFFFFFFFF and (method != 0 or compressed == expanded),
         true <- name_size in 1..1024 and extra_size <= 4096,
         next = position + 46 + name_size + extra_size + comment_size,
         true <- next <= stop,
         {:ok, <<name::binary-size(^name_size), extra::binary>>} <-
           read_at(file, position + 46, name_size + extra_size),
         true <- extras?(extra, MapSet.new()),
         kind = if(String.ends_with?(name, "/"), do: :directory, else: :file),
         true <-
           attributes?(system, attributes, kind) and
             (kind != :directory or (method == 0 and expanded == 0 and crc == 0)),
         true <-
           expanded <= policy.max_entry_bytes and
             total + expanded <= policy.max_total_uncompressed_bytes and
             expanded <= compressed * policy.max_expansion_ratio,
         {:ok, path, paths} <- PathPolicy.add(name, kind, policy, paths) do
      entry = %Entry{
        path: path,
        kind: kind,
        size_bytes: expanded,
        compressed_bytes: compressed,
        crc32: crc
      }

      record = %{entry: entry, offset: offset, method: method, common: common, name: name}
      central(file, count - 1, next, stop, policy, {paths, [record | entries], total + expanded})
    else
      _ -> :error
    end
  end

  defp central(_, _, _, _, _, _), do: :error

  defp local(_, [], stop, stop, verified), do: {:ok, Enum.reverse(verified)}

  defp local(
         file,
         [%{offset: offset, common: common, name: name} = record | rest],
         offset,
         stop,
         verified
       )
       when offset + 30 <= stop do
    name_size = byte_size(name)

    with {:ok,
          <<"PK", 3, 4, ^common::binary-size(22), ^name_size::16-little, extra_size::16-little>>} <-
           read_at(file, offset, 30),
         true <- extra_size <= 4096,
         data = offset + 30 + name_size + extra_size,
         next = data + record.entry.compressed_bytes,
         true <- next <= stop,
         {:ok, <<^name::binary-size(^name_size), extra::binary>>} <-
           read_at(file, offset + 30, name_size + extra_size),
         true <- extras?(extra, MapSet.new()) do
      local(file, rest, next, stop, [Map.put(record, :data_offset, data) | verified])
    else
      _ -> :error
    end
  end

  defp local(_, _, _, _, _), do: :error

  # Timestamp and Unix UID/GID metadata are inert. Reject unknown fields,
  # including alternate path names, link metadata and ZIP64 records.
  defp extras?(<<>>, _), do: true

  defp extras?(
         <<id::16-little, length::16-little, _data::binary-size(length), rest::binary>>,
         seen
       )
       when id in [0x5455, 0x7875, 0x000A] do
    not MapSet.member?(seen, id) and extras?(rest, MapSet.put(seen, id))
  end

  defp extras?(_, _), do: false

  defp attributes?(system, attributes, kind) when system in [0, 3, 10, 19] do
    mode = attributes >>> 16 &&& 0xF000
    dos_flags = attributes &&& 0xFFFF
    expected_mode = if kind == :directory, do: 0x4000, else: 0x8000

    mode in [0, expected_mode] and (dos_flags &&& bnot(0x37)) == 0 and
      (kind == :directory or (dos_flags &&& 0x10) == 0)
  end

  defp attributes?(_, _, _), do: false

  def read_at(_, _, 0), do: {:ok, <<>>}

  def read_at(file, offset, length) do
    case :file.pread(file, offset, length) do
      {:ok, bytes} when byte_size(bytes) == length -> {:ok, bytes}
      _ -> :error
    end
  end
end
