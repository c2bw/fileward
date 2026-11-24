defmodule FileWard.ArchiveTest do
  use ExUnit.Case, async: false
  use ExUnitProperties
  import FileWard.TestSupport
  alias FileWard.{ArchivePolicy, Error}

  @moduletag :tmp_dir
  setup :setup_root

  test "extracts stored, deflated, empty and directory entries with scoped cleanup", %{root: root} do
    bytes =
      zip([{"folder/", "", []}, {"folder/data.txt", "hello", [method: 8]}, {"empty.txt", "", []}])

    assert {:ok, directory} =
             intake(bytes, root, [], fn archive ->
               assert archive.size_bytes == 5

               assert Enum.map(archive.entries, &{&1.path, &1.kind}) ==
                        [{"folder", :directory}, {"folder/data.txt", :file}, {"empty.txt", :file}]

               assert File.read!(Path.join(archive.directory, "folder/data.txt")) == "hello"
               assert File.read!(Path.join(archive.directory, "empty.txt")) == ""
               archive.directory
             end)

    refute File.exists?(directory)
    assert File.ls!(root) == []

    {:ok, {_, ordinary}} =
      :zip.create(~c"ordinary.zip", [{~c"normal.txt", :crypto.strong_rand_bytes(8192)}], [:memory])

    assert {:ok, 1} = intake(ordinary, root, [], &length(&1.entries))
  end

  test "rejects unsafe paths, aliases, file-directory collisions and special entries", %{
    root: root,
    tmp_dir: tmp
  } do
    outside = Path.join(tmp, "outside.txt")
    File.write!(outside, "original")

    for entries <- [
          [{"../../outside.txt", "bad", []}],
          [{"/absolute.txt", "", []}],
          [{"C:/drive.txt", "", []}],
          [{"\\\\host\\share.txt", "", []}],
          [{"dir//empty.txt", "", []}],
          [{"dir/./dot.txt", "", []}],
          [{"bad\0.txt", "", []}],
          [{"bad" <> <<255>> <> ".txt", "", []}],
          [{"CON.txt", "", []}],
          [{"trailing./x.txt", "", []}],
          [{"first.txt", "", []}, {"first.txt", "", []}],
          [{"Case.txt", "", []}, {"case.txt", "", []}],
          [{"CAFÉ.txt", "", []}, {"cafe\u0301.txt", "", []}],
          [{"parent.txt/child.txt", "", []}, {"parent.txt", "", []}],
          [{"link.txt", outside, [attributes: 0xA0000000]}],
          [{"device.txt", "", [attributes: 0x20000000]}],
          [{"hardlink.txt", "", [extra: <<0x756E::16-little, 0::16>>]}]
        ] do
      assert :archive_rejected = rejection(zip(entries), root)
    end

    assert File.read!(outside) == "original"
  end

  test "rejects inconsistent, truncated, unsupported and spoofed ZIP records", %{root: root} do
    valid = zip([{"one.txt", "hello", []}])

    for bytes <- [
          binary_part(valid, 0, byte_size(valid) - 1),
          zip([{"one.txt", "hello", [local_name: "two.txt"]}]),
          zip([{"one.txt", "hello", [flags: 1]}]),
          zip([{"one.txt", "hello", [flags: 8]}]),
          zip([{"one.txt", "hello", [needed: 45]}]),
          zip([{"one.txt", "hello", [method: 99, raw: "hello"]}]),
          zip([{"one.txt", "hello", [crc: 0]}]),
          zip([{"one.txt", "", [method: 8, raw: <<3>>]}]),
          zip([{"one.txt", "", [method: 8, raw: <<3, 0, 0>>]}]),
          zip([{"one.txt", String.duplicate("A", 30_000), [method: 8, size: 1]}])
        ] do
      assert :archive_rejected = rejection(bytes, root)
    end
  end

  test "enforces entry, aggregate, path and expansion limits and rejects nested signatures", %{
    root: root
  } do
    normal = zip([{"dir/one.txt", "1234", []}, {"two.txt", "5678", []}])

    for options <- [
          [max_entries: 1],
          [max_total_uncompressed_bytes: 7],
          [max_entry_bytes: 3],
          [max_path_depth: 1]
        ] do
      assert :archive_rejected = rejection(normal, root, options)
    end

    assert :archive_rejected =
             rejection(zip([{"one.txt", String.duplicate("A", 1000), [method: 8]}]), root,
               max_expansion_ratio: 2
             )

    nested = zip([{"one.txt", zip([]), []}])
    assert :archive_rejected = rejection(nested, root)
    assert {:ok, 1} = intake(nested, root, [reject_nested_archives: false], &length(&1.entries))
  end

  property "arbitrary ZIP-prefixed bytes reject with rollback", %{root: root} do
    check all(bytes <- binary(max_length: 4096), max_runs: 35) do
      assert :archive_rejected = rejection(<<"PK", 3, 4, bytes::binary>>, root)
    end
  end

  defp intake(bytes, root, options, callback) do
    p = policy(root, media_types: ["application/zip"])
    a = ArchivePolicy.new!(Keyword.merge([allowed_extensions: [".txt"]], options))
    FileWard.with_archive(source(bytes), p, a, callback)
  end

  defp rejection(bytes, root, options \\ []) do
    assert {:error, %Error{code: code}} = intake(bytes, root, options, fn _ -> flunk() end)
    assert File.ls!(root) == []
    code
  end
end
