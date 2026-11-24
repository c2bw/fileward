defmodule FileWard.HTTPTest do
  use ExUnit.Case, async: false
  use ExUnitProperties
  import FileWard.TestSupport
  alias FileWard.{Archive, ArchivePolicy, Error, Writer}
  alias FileWard.HTTP.{AddressPolicy, Fetcher, URL}

  @moduletag :tmp_dir
  setup :setup_root

  setup_all do
    root =
      Path.join(System.tmp_dir!(), "fw-tls-" <> Base.url_encode64(:crypto.strong_rand_bytes(16)))

    File.mkdir!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    openssl!(
      root,
      ~w(req -x509 -newkey rsa:2048 -nodes -keyout ca.key -out ca.pem -days 2 -subj /CN=FileWard-Test-CA)
    )

    openssl!(
      root,
      ~w(req -new -newkey rsa:2048 -nodes -keyout server.key -out server.csr -subj /CN=files.example)
    )

    File.write!(
      Path.join(root, "extensions"),
      "subjectAltName=DNS:files.example,IP:127.0.0.1\nextendedKeyUsage=serverAuth\n"
    )

    openssl!(
      root,
      ~w(x509 -req -in server.csr -CA ca.pem -CAkey ca.key -CAcreateserial -out server.pem -days 2 -extfile extensions)
    )

    [{:Certificate, ca, :not_encrypted}] =
      root |> Path.join("ca.pem") |> File.read!() |> :public_key.pem_decode()

    [
      tls: [
        certfile: String.to_charlist(Path.join(root, "server.pem")),
        keyfile: String.to_charlist(Path.join(root, "server.key"))
      ],
      ca: ca
    ]
  end

  test "strict URL parsing and normalized routing" do
    for bad <- [
          "file:///etc/hosts",
          "ftp://example.com",
          "gopher://example.com",
          "http://example.com",
          "https://user:secret@example.com",
          "https://example.com#fragment",
          "https://x.example:65536",
          "https://x.example:",
          "https://[::1",
          "https://[fe80::1%25eth0]",
          "https://x.example\r\n",
          "https://exam%70le.com",
          "https://1.2.127",
          "https://127.000.0.1",
          "https://2130706433",
          "https://0x7f.0.0.0x1",
          "https://example.com/a%zz",
          "https://example.com\\test",
          "https://é.test",
          "https://example.com./",
          <<"https://example.com/", 255>>
        ] do
      assert {:error, %Error{code: :invalid_url}} = URL.parse(bad)
    end

    assert {:ok, %{host: "example.com", port: 8443, target: "/?key=%2F"}} =
             URL.parse("https://Example.COM:8443?key=%2F")

    assert {:ok, %{host: "2606:4700::1111", ip: {0x2606, 0x4700, 0, 0, 0, 0, 0, 0x1111}}} =
             URL.parse("https://[2606:4700::1111]/")
  end

  test "rejects private and special purpose address classes on the public entry point", %{
    root: root
  } do
    for literal <- [
          "0.0.0.0",
          "10.5.6.7",
          "100.64.0.1",
          "127.0.0.1",
          "169.254.169.254",
          "172.31.0.0",
          "192.0.2.1",
          "192.168.0.1",
          "198.18.0.1",
          "198.51.100.1",
          "203.0.113.1",
          "224.0.0.1",
          "240.0.0.1",
          "[::]",
          "[::1]",
          "[::ffff:8.8.8.8]",
          "[64:ff9b::7f00:1]",
          "[100::1]",
          "[2001::1]",
          "[2001:db8::1]",
          "[2002:7f00:1::]",
          "[3fff::1]",
          "[fc00::1]",
          "[fe80::1]",
          "[ff00::1]"
        ] do
      assert {:error, %Error{code: :unsafe_address}} =
               FileWard.with_file({:url, "https://" <> literal}, policy(root), fn _ -> flunk() end)
    end

    assert AddressPolicy.public?({8, 8, 8, 8})
    assert AddressPolicy.public?({0x2606, 0x4700, 0, 0, 0, 0, 0, 0x1111})
  end

  property "private prefix classification holds across host bits" do
    check all(a <- integer(0..255), b <- integer(0..255), c <- integer(0..255)) do
      refute AddressPolicy.public?({10, a, b, c})
      refute AddressPolicy.public?({192, 168, b, c})
      refute AddressPolicy.public?({0, 0, 0, 0, 0, 0xFFFF, a * 256 + b, c})
    end
  end

  test "pins the socket, resolves once, and sends original Host and TLS SNI", context do
    {port, server} = serve(context, [response("%PDF-file")])
    parent = self()

    resolver = fn host, _ ->
      assert host == "files.example"
      count = Process.get(:queries, 0)
      Process.put(:queries, count + 1)
      send(parent, :dns_query)
      {:ok, [if(count == 0, do: {127, 0, 0, 1}, else: {127, 0, 0, 2})]}
    end

    assert {:ok, artifact} = fetch(context, port, resolver: resolver)
    assert File.read!(artifact.path) == "%PDF-file"
    assert_receive :dns_query
    refute_received :dns_query
    assert_receive {:request, request, ~c"files.example"}
    assert request =~ "host: files.example:#{port}\r\n"
    assert request =~ "accept-encoding: identity\r\n"
    assert request =~ "GET /file?q=value HTTP/1.1"
    await(server)
  end

  test "rejects a mixed DNS result before connect", context do
    resolver = fn _, _ -> {:ok, [{8, 8, 8, 8}, {127, 0, 0, 1}]} end

    assert {:error, %Error{code: :unsafe_address}} =
             fetch(context, 443, resolver: resolver, allowed: &AddressPolicy.public?/1)
  end

  test "rejects wrong TLS hostname and untrusted CA and verifies literal SAN", context do
    {port, server} = serve(context, [response("%PDF-file")])
    assert {:error, %Error{code: :tls_failed}} = fetch(context, port, host: "other.example")
    await(server)
    {port, server} = serve(context, [response("%PDF-file")])
    assert {:error, %Error{code: :tls_failed}} = fetch(context, port, roots: [])
    await(server)

    {port, server} = serve(context, [response("%PDF-file")])
    assert {:ok, _} = fetch(context, port, host: "127.0.0.1")
    assert_receive {:request, request, nil}
    assert request =~ "host: 127.0.0.1:#{port}\r\n"
    await(server)
  end

  test "denies redirects and malformed or unsupported response metadata", context do
    for {wire, code} <- [
          {"HTTP/1.1 302 Found\r\nLocation: https://169.254.169.254/\r\nContent-Length: 0\r\n\r\n",
           :redirect_forbidden},
          {"HTTP/1.1 302 Found\r\nLocation: file:///etc/hosts\r\nContent-Length: 0\r\n\r\n",
           :redirect_forbidden},
          {"HTTP/1.1 404 Nope\r\nContent-Length: 0\r\n\r\n", :unexpected_status},
          {"HTTP/1.1 200 OK\r\n\r\n%PDF-foo", :invalid_response},
          {"HTTP/1.1 200 OK\r\nContent-Length: -1\r\n\r\n", :invalid_response},
          {"HTTP/1.1 200 OK\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\n",
           :invalid_response},
          {"HTTP/1.1 200 OK\r\nContent-Length: 99999\r\n\r\n", :too_large},
          {response("%PDF-file", "Content-Encoding: gzip\r\n"), :invalid_response},
          {response("%PDF-file", "Transfer-Encoding: chunked\r\n"), :invalid_response},
          {"HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\n%PDF-", :network_error}
        ] do
      {port, server} = serve(context, [wire])
      assert {:error, %Error{code: ^code}} = fetch(context, port)
      await(server)
    end
  end

  test "bounds headers, status, chunk declarations, idle time and body bytes", context do
    chunked = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n"

    for fragments <- [
          ["HTTP/1.1 200 " <> String.duplicate("x", 17_000) <> "\r\n"],
          [
            "HTTP/1.1 200 OK\r\nX-Large: ",
            String.duplicate("a", 8500),
            String.duplicate("b", 8500)
          ],
          [chunked, String.duplicate("F", 20_000)],
          [chunked, "1;" <> String.duplicate("x", 17_000)]
        ] do
      {port, server} = serve(context, fragments)
      assert {:error, %Error{code: :invalid_response}} = fetch(context, port)
      await(server)
    end

    {port, server} = serve(context, [chunked, "7FFFFFFF\r\n%PDF-body", {:sleep, 200}])
    assert {:error, %Error{code: :too_large}} = fetch(context, port, max_bytes: 8)
    await(server)

    for fragments <- [[{:sleep, 200}], [chunked, {:sleep, 200}]] do
      {port, server} = serve(context, fragments)
      assert {:error, %Error{code: :timeout}} = fetch(context, port, idle_timeout_ms: 75)
      await(server)
    end
  end

  test "accepts chunked ZIP over pinned TLS and extracts the verified archive", context do
    bytes = zip([{"report.txt", "result", [method: 8]}])

    wire = [
      "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n",
      Integer.to_string(byte_size(bytes), 16),
      "\r\n",
      bytes,
      "\r\n0\r\n\r\n"
    ]

    {port, server} = serve(context, wire)
    assert {:ok, staged} = fetch(context, port, media_types: ["application/zip"])
    archive_policy = ArchivePolicy.new!(allowed_extensions: [".txt"])
    assert {:ok, archive} = Archive.extract(staged, context.root, archive_policy)
    assert File.read!(Path.join(archive.directory, "report.txt")) == "result"
    await(server)
  end

  @tag :resource
  test "fragmented oversized parser input leaves stable process and binary memory", context do
    wire = ["HTTP/1.1 200 OK\r\nX-Fill: " | List.duplicate(:binary.copy("x", 2048), 12)]
    {port, server} = serve(context, wire)
    assert {:error, %Error{code: :invalid_response}} = fetch(context, port)
    await(server)
    :erlang.garbage_collect()
    processes = :erlang.system_info(:process_count)
    binary_memory = :erlang.memory(:binary)

    for _ <- 1..16 do
      {port, server} = serve(context, wire)
      assert {:error, %Error{code: :invalid_response}} = fetch(context, port)
      await(server)
    end

    :erlang.garbage_collect()
    assert :erlang.system_info(:process_count) < processes + 12
    assert :erlang.memory(:binary) < binary_memory + 8 * 1024 * 1024
  end

  defp fetch(context, port, options \\ []) do
    File.mkdir_p!(context.root)
    File.rm(Path.join(context.root, "file"))
    p = policy(context.root, Keyword.take(options, [:max_bytes, :media_types, :idle_timeout_ms]))
    host = Keyword.get(options, :host, "files.example")
    resolve = Keyword.get(options, :resolver, fn _, _ -> {:ok, [{127, 0, 0, 1}]} end)
    allowed = Keyword.get(options, :allowed, &(&1 == {127, 0, 0, 1}))
    roots = Keyword.get(options, :roots, [context.ca])

    Writer.run(context.root, p, :url, fn state, write ->
      Fetcher.fetch(
        "https://#{host}:#{port}/file?q=value",
        p,
        state,
        write,
        resolve,
        allowed,
        roots
      )
    end)
  end

  defp serve(context, fragments) do
    parent = self()
    ref = make_ref()

    pid =
      spawn(fn ->
        {:ok, listener} =
          :ssl.listen(
            0,
            context.tls ++ [log_level: :none, ip: {127, 0, 0, 1}, active: false, mode: :binary]
          )

        {:ok, {_, port}} = :ssl.sockname(listener)
        send(parent, {ref, port})

        with {:ok, socket} <- :ssl.transport_accept(listener, 2000),
             {:ok, socket} <- :ssl.handshake(socket, 2000),
             {:ok, request} <- read_request(socket, <<>>),
             {:ok, info} <- :ssl.connection_information(socket, [:sni_hostname]) do
          send(parent, {:request, request, info[:sni_hostname]})

          Enum.each(fragments, fn
            {:sleep, ms} -> Process.sleep(ms)
            data -> :ssl.send(socket, data)
          end)

          :ssl.close(socket)
        end

        :ssl.close(listener)
      end)

    monitor = Process.monitor(pid)
    assert_receive {^ref, port}, 2000
    {port, monitor}
  end

  defp read_request(socket, acc) do
    if String.contains?(acc, "\r\n\r\n") do
      {:ok, acc}
    else
      with {:ok, chunk} <- :ssl.recv(socket, 0, 2000), do: read_request(socket, acc <> chunk)
    end
  end

  defp await(monitor) do
    assert_receive {:DOWN, ^monitor, :process, _, :normal}, 3000
  end

  defp response(body, extra \\ "") do
    "HTTP/1.1 200 OK\r\nContent-Length: #{byte_size(body)}\r\n#{extra}\r\n#{body}"
  end

  defp openssl!(directory, args) do
    assert {_output, 0} = System.cmd("openssl", args, cd: directory, stderr_to_stdout: true)
  end
end
