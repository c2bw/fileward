ExUnit.start()

defmodule FileWard.TestSupport do
  def setup_root(context) do
    root = Path.join(context.tmp_dir, "staging")
    [root: root]
  end

  def policy(root, options \\ []) do
    FileWard.Policy.new!(
      Keyword.merge(
        [staging_dir: root, media_types: ["application/pdf"], max_bytes: 65_536],
        options
      )
    )
  end

  def source(bytes), do: {:stream, [bytes], []}

  def zip(entries) do
    {locals, central, offset} =
      Enum.reduce(entries, {[], [], 0}, fn {name, data, opts}, {locals, central, offset} ->
        {local, record} = zip_entry(name, data, opts, offset)
        {[locals, local], [central, record], offset + IO.iodata_length(local)}
      end)

    count = length(entries)
    bytes = IO.iodata_length(central)

    IO.iodata_to_binary([
      locals,
      central,
      <<"PK", 5, 6, 0::32, count::16-little, count::16-little, bytes::32-little,
        offset::32-little, 0::16>>
    ])
  end

  defp zip_entry(name, data, opts, offset) do
    method = Keyword.get(opts, :method, 0)
    raw = Keyword.get_lazy(opts, :raw, fn -> if method == 8, do: deflate(data), else: data end)
    flags = Keyword.get(opts, :flags, 0)
    crc = Keyword.get(opts, :crc, :erlang.crc32(data))
    expanded = Keyword.get(opts, :size, byte_size(data))
    needed = Keyword.get(opts, :needed, 20)
    attributes = Keyword.get(opts, :attributes, 0)
    compressed = byte_size(raw)
    local_name = Keyword.get(opts, :local_name, name)
    extra = Keyword.get(opts, :extra, <<>>)

    c =
      <<needed::16-little, flags::16-little, method::16-little, 0::32, crc::32-little,
        compressed::32-little, expanded::32-little>>

    local = [<<"PK", 3, 4, c::binary, byte_size(local_name)::16-little, 0::16>>, local_name, raw]

    central = [
      <<"PK", 1, 2, 20, 3, c::binary, byte_size(name)::16-little, byte_size(extra)::16-little,
        0::48, attributes::32-little, offset::32-little>>,
      name,
      extra
    ]

    {local, central}
  end

  defp deflate(data) do
    z = :zlib.open()

    try do
      :ok = :zlib.deflateInit(z, :default, :deflated, -15, 8, :default)
      IO.iodata_to_binary(:zlib.deflate(z, data, :finish))
    after
      :zlib.close(z)
    end
  end
end
