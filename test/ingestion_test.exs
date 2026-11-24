defmodule FileWard.IngestionTest do
  use ExUnit.Case, async: false
  use ExUnitProperties
  import Bitwise
  import FileWard.TestSupport
  alias FileWard.{Error, Policy}

  @moduletag :tmp_dir
  setup :setup_root

  test "rejects unsafe and mistyped policies", %{root: root} do
    for options <- [
          [max_bytes: 0],
          [staging_dir: "relative"],
          [max_prefix_bytes: 0],
          [media_types: []],
          [total_timeout_ms: :infinity],
          [http: [redirects: :follow]],
          [http: [address_scope: :private]],
          [http: [verify: :verify_none]]
        ] do
      assert_raise ArgumentError, fn -> policy(root, options) end
    end

    assert_raise ArgumentError, fn -> Policy.new!(max_bytes: 1, max_bytes: 2) end

    assert {:error, %Error{code: :invalid_policy}} =
             FileWard.with_file(source("%PDF-x"), %{policy(root) | max_bytes: 0}, fn _ ->
               flunk()
             end)
  end

  property "binary partitioning preserves the digest and signature, oversize never invokes callback",
           %{root: root} do
    check all(chunks <- list_of(binary(max_length: 32), max_length: 20), max_runs: 35) do
      bytes = IO.iodata_to_binary(["%PDF-" | chunks])
      input = {:stream, ["%", "PD", "F-" | chunks], []}

      assert {:ok, :consumed} =
               FileWard.with_file(input, policy(root), fn artifact ->
                 assert artifact.size_bytes == byte_size(bytes)

                 assert artifact.sha256 ==
                          Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

                 assert artifact.detected_media_type == "application/pdf"
                 assert File.read!(artifact.path) == bytes
                 assert (File.stat!(artifact.path).mode &&& 0o777) == 0o400
                 :consumed
               end)

      assert {:error, %Error{code: :too_large}} =
               FileWard.with_file(input, policy(root, max_bytes: byte_size(bytes) - 1), fn _ ->
                 flunk()
               end)

      assert File.ls!(root) == []
    end
  end

  test "cleans up after callback raises, exits, and throws", %{root: root} do
    p = policy(root)

    assert_raise RuntimeError, "application error", fn ->
      FileWard.with_file(source("%PDF-x"), p, fn _ -> raise "application error" end)
    end

    assert catch_exit(
             FileWard.with_file(source("%PDF-x"), p, fn _ -> exit(:application_exit) end)
           ) == :application_exit

    assert catch_throw(
             FileWard.with_file(source("%PDF-x"), p, fn _ -> throw(:application_throw) end)
           ) == :application_throw

    assert File.ls!(root) == []
  end

  test "rejects oversize chunks, empty content, lying metadata and broken enumerables", %{
    root: root
  } do
    p = policy(root, max_bytes: 8, strict_media_type: true)

    broken =
      Stream.map(["%PDF-", :raise], fn
        :raise -> raise "secret"
        data -> data
      end)

    for {input, code} <- [
          {source("%PDF-xxxx"), :too_large},
          {source(""), :unsupported_type},
          {{:stream, ["%PDF-"], [content_type: "text/plain"]}, :invalid_content},
          {{:stream, broken, []}, :invalid_content},
          {{:stream, ["%PDF-", 1], []}, :invalid_content}
        ] do
      assert {:error, %Error{code: ^code}} = FileWard.with_file(input, p, fn _ -> flunk() end)
      assert File.ls!(root) == []
    end
  end

  test "timeout releases the slot and kills a blocked worker", %{root: root} do
    caller = self()

    stuck =
      Stream.repeatedly(fn ->
        send(caller, {:worker, self()})
        Process.sleep(:infinity)
      end)

    p = policy(root, total_timeout_ms: 100, max_inflight: 1)

    assert {:error, %Error{code: :timeout}} =
             FileWard.with_file({:stream, stuck, []}, p, fn _ -> flunk() end)

    assert_receive {:worker, worker}
    refute Process.alive?(worker)
    assert File.ls!(root) == []
    assert {:ok, :ok} = FileWard.with_file(source("%PDF-x"), p, fn _ -> :ok end)
  end

  test "holds an admission slot through callback and reclaims after caller kill", %{root: root} do
    parent = self()
    p = policy(root, max_inflight: 1)

    caller =
      spawn(fn ->
        FileWard.with_file(source("%PDF-x"), p, fn artifact ->
          send(parent, {:in_callback, artifact.path})
          Process.sleep(:infinity)
        end)
      end)

    assert_receive {:in_callback, path}, 1000

    assert {:error, %Error{code: :busy, retryable?: true}} =
             FileWard.with_file(source("%PDF-x"), p, fn _ -> flunk() end)

    Process.exit(caller, :kill)
    eventually(fn -> not File.exists?(path) end)
    assert {:ok, :ok} = FileWard.with_file(source("%PDF-x"), p, fn _ -> :ok end)
  end

  test "rejects a loose or symlink staging root and sweeps only stale directories", %{
    root: root,
    tmp_dir: tmp
  } do
    File.mkdir!(root)
    File.chmod!(root, 0o755)

    assert {:error, %Error{code: :storage_error}} =
             FileWard.with_file(source("%PDF-x"), policy(root), fn _ -> flunk() end)

    link = Path.join(tmp, "link")
    File.ln_s!(root, link)

    assert {:error, %Error{code: :storage_error}} =
             FileWard.with_file(source("%PDF-x"), policy(link), fn _ -> flunk() end)

    File.chmod!(root, 0o700)
    stale = "fw-9999999999-" <> String.duplicate("A", 32)
    live = "fw-#{System.pid()}-" <> String.duplicate("A", 32)
    File.mkdir!(Path.join(root, stale))
    File.mkdir!(Path.join(root, live))
    assert {:ok, :ok} = FileWard.with_file(source("%PDF-x"), policy(root), fn _ -> :ok end)
    if :os.type() == {:unix, :linux}, do: assert(File.ls!(root) == [live])
  end

  test "Plug copies staged bytes and treats the filename as display metadata", %{
    root: root,
    tmp_dir: tmp
  } do
    path = Path.join(tmp, "upload")
    File.write!(path, "%PDF-file")
    name = "../private/\nфайл.pdf"
    upload = %Plug.Upload{path: path, filename: name, content_type: "application/pdf"}

    assert {:ok, :ok} =
             FileWard.with_file({:upload, upload}, policy(root), fn artifact ->
               assert artifact.original_filename == name
               assert Path.basename(artifact.path) == "file"
               assert artifact.source_kind == :upload
               :ok
             end)

    assert {:error, %Error{code: :too_large}} =
             FileWard.with_file({:upload, upload}, policy(root, max_bytes: 8), fn _ -> flunk() end)

    assert File.read!(path) == "%PDF-file"
  end

  test "Plug multipart and FileWard enforce independent body limits", %{root: root} do
    multipart = fn bytes, cap ->
      body =
        "--boundary\r\ncontent-disposition: form-data; name=\"file\"; filename=\"test.pdf\"\r\n" <>
          "content-type: application/pdf\r\n\r\n" <> bytes <> "\r\n--boundary--\r\n"

      conn =
        Plug.Test.conn(:post, "/", body)
        |> Plug.Conn.put_req_header("content-type", "multipart/form-data; boundary=boundary")

      opts = Plug.Parsers.init(parsers: [{:multipart, length: cap, read_length: 1024}])
      Plug.Parsers.call(conn, opts)
    end

    assert_raise Plug.Parsers.RequestTooLargeError, fn ->
      multipart.("%PDF-" <> String.duplicate("x", 512), 128)
    end

    conn = multipart.("%PDF-hello", 256)
    assert %Plug.Upload{} = upload = conn.body_params["file"]

    assert {:error, %Error{code: :too_large}} =
             FileWard.with_file({:upload, upload}, policy(root, max_bytes: 8), fn _ -> flunk() end)

    assert {:ok, 10} =
             FileWard.with_file({:upload, upload}, policy(root), & &1.size_bytes)
  end

  test "admission reserves input and extraction budgets", %{root: root} do
    a =
      FileWard.ArchivePolicy.new!(allowed_extensions: [".txt"], max_total_uncompressed_bytes: 100)

    assert {:error, %Error{code: :capacity_exceeded}} =
             FileWard.with_archive(
               source(zip([])),
               policy(root, max_bytes: 100, disk_budget_bytes: 199),
               a,
               fn _ -> flunk() end
             )

    refute File.exists?(root)
  end

  test "telemetry dispatch keeps URL parameters and filesystem details out of events", %{
    root: root
  } do
    event = [:file_ward, :policy, :rejected]
    id = make_ref()
    assert :ok = :telemetry.attach(id, event, &__MODULE__.capture_event/4, self())
    on_exit(fn -> :telemetry.detach(id) end)

    assert {:error, error} =
             FileWard.with_file({:url, "https://127.0.0.1/?key=secret"}, policy(root), fn _ ->
               flunk()
             end)

    assert Exception.message(error) == "FileWard resolve failed (unsafe_address)"

    assert_receive {^event, %{duration: duration},
                    %{source_kind: :url, error_code: :unsafe_address} = metadata}

    assert map_size(metadata) == 2
    assert duration >= 0
  end

  def capture_event(name, measurements, metadata, receiver),
    do: send(receiver, {name, measurements, metadata})

  @tag :resource
  test "repeated staged failures release descriptors, workers and disk", %{root: root} do
    p = policy(root, max_inflight: 1, max_bytes: 32)
    baseline = :erlang.system_info(:process_count)
    before_fds = descriptors()

    for _ <- 1..512 do
      assert {:error, %Error{code: :too_large}} =
               FileWard.with_file(
                 {:stream, ["%PDF-hello", :binary.copy(<<0>>, 32)], []},
                 p,
                 fn _ -> flunk() end
               )

      assert File.ls!(root) == []
    end

    assert :erlang.system_info(:process_count) <= baseline + 10
    if before_fds != nil, do: assert(descriptors() <= before_fds + 4)
  end

  defp descriptors do
    case File.ls("/proc/self/fd") do
      {:ok, names} -> length(names)
      _ -> nil
    end
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(fun, 0), do: assert(fun.())

  defp eventually(fun, n) do
    unless fun.() do
      Process.sleep(5)
      eventually(fun, n - 1)
    end
  end
end
