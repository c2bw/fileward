defmodule FileWard.OpaqueAttachmentTest do
  use ExUnit.Case, async: false

  import FileWard.TestSupport
  alias FileWard.{ArchivePolicy, Error, Policy}

  @moduletag :tmp_dir
  setup :setup_root

  test "unknown bytes are hashed, staged for the callback and then removed", %{root: root} do
    bytes = <<0, 255, 123, 0, 9>>
    digest = Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
    source = {:stream, [<<0, 255>>, <<123, 0, 9>>], [filename: "blob.bin"]}

    assert {:ok, {:error, :callback_result, path}} =
             FileWard.with_file(source, opaque_policy(root), fn artifact ->
               assert artifact.original_filename == "blob.bin"
               assert artifact.detected_media_type == nil
               assert artifact.size_bytes == byte_size(bytes)
               assert artifact.sha256 == digest
               assert File.read!(artifact.path) == bytes
               {:error, :callback_result, artifact.path}
             end)

    refute File.exists?(path)
    assert File.ls!(root) == []

    assert {:error, %Error{code: :unsupported_type}} =
             FileWard.with_file(source, policy(root), fn _ -> flunk("unexpected callback") end)
  end

  test "empty opaque files require explicit opt-in", %{root: root} do
    source = {:stream, [], []}

    assert {:error, %Error{code: :invalid_content}} =
             FileWard.with_file(source, opaque_policy(root), fn _ ->
               flunk("unexpected callback")
             end)

    assert {:ok, artifact} =
             FileWard.with_file(source, opaque_policy(root, allow_empty: true), & &1)

    assert artifact.sha256 == Base.encode16(:crypto.hash(:sha256, ""), case: :lower)
    assert artifact.size_bytes == 0
    assert artifact.detected_media_type == nil
    refute File.exists?(artifact.path)

    assert_raise ArgumentError, fn ->
      Policy.new!(staging_dir: root, media_types: ["application/pdf"], allow_empty: true)
    end
  end

  test "opaque policy keeps bounds and rejects contradictory settings and archive extraction", %{
    root: root
  } do
    for options <- [[strict_media_type: true], [media_types: ["application/pdf"]]] do
      assert_raise ArgumentError, fn -> opaque_policy(root, options) end
    end

    source = {:stream, [<<0, 1>>], []}

    assert {:error, %Error{code: :too_large}} =
             FileWard.with_file(source, opaque_policy(root, max_bytes: 1), fn _ ->
               flunk("unexpected callback")
             end)

    assert {:error, %Error{code: :invalid_policy}} =
             FileWard.with_archive(
               {:stream, ["PK" <> <<3, 4>>], []},
               opaque_policy(root),
               ArchivePolicy.new!(allowed_extensions: [".txt"]),
               fn _ -> flunk("unexpected callback") end
             )

    assert File.ls!(root) == []
  end

  defp opaque_policy(root, overrides \\ []) do
    Policy.new!(Keyword.merge([staging_dir: root, content_mode: :opaque_attachment], overrides))
  end
end
