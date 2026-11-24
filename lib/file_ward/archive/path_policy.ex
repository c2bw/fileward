defmodule FileWard.Archive.PathPolicy do
  @moduledoc false

  @forbidden ~r/[\p{C}\\:<>|?*"\x{2028}\x{2029}]/u
  @device ~r/\A(?:con|prn|aux|nul|com[1-9¹²³]|lpt[1-9¹²³])\z/u

  def add(name, kind, policy, paths) do
    relative = if kind == :directory, do: binary_part(name, 0, byte_size(name) - 1), else: name

    with true <- String.valid?(relative) and not Regex.match?(@forbidden, relative),
         segments = String.split(relative, "/"),
         true <- length(segments) <= policy.max_path_depth and Enum.all?(segments, &segment?/1),
         true <-
           kind == :directory or
             String.downcase(Path.extname(relative)) in policy.allowed_extensions,
         {:ok, paths} <- insert(segments, kind, paths, :root) do
      {:ok, relative, paths}
    else
      _ -> :error
    end
  end

  defp segment?(segment) do
    name =
      segment
      |> String.split(".", parts: 2)
      |> hd()
      |> String.trim_trailing()
      |> String.downcase()

    byte_size(segment) in 1..255 and segment not in [".", ".."] and
      not String.ends_with?(segment, [".", " "]) and not Regex.match?(@device, name)
  end

  defp insert([segment | rest], kind, paths, parent) do
    folded = segment |> String.normalize(:nfd) |> :string.casefold() |> String.normalize(:nfd)
    key = {parent, folded}

    case {rest, Map.get(paths, key)} do
      {[], nil} ->
        {:ok, Map.put(paths, key, {segment, kind, true, make_ref()})}

      {[], {^segment, :directory, false, id}} when kind == :directory ->
        {:ok, Map.put(paths, key, {segment, :directory, true, id})}

      {[_ | _], nil} ->
        id = make_ref()
        insert(rest, kind, Map.put(paths, key, {segment, :directory, false, id}), id)

      {[_ | _], {^segment, :directory, _, id}} ->
        insert(rest, kind, paths, id)

      _ ->
        :error
    end
  end
end
