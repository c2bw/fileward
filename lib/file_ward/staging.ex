defmodule FileWard.Staging do
  @moduledoc false
  import Bitwise

  # A fresh inode provides the effective filesystem UID without shelling out.
  def create(root) do
    root = Path.expand(root)

    with :ok <- private_root(root),
         {:ok, %{uid: owner}} <- File.lstat(root),
         name =
           "fw-#{System.pid()}-" <>
             Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false),
         path = Path.join(root, name),
         :ok <- File.mkdir(path) do
      case File.chmod(path, 0o700) do
        :ok ->
          case File.lstat(path) do
            {:ok, %{type: :directory, uid: ^owner}} -> {:ok, path}
            _ -> discard(path)
          end

        _ ->
          discard(path)
      end
    end
  end

  defp private_root(root) do
    case File.lstat(root) do
      {:ok, %{type: :directory, mode: mode}} when (mode &&& 0o7777) == 0o700 ->
        :ok

      {:error, :enoent} ->
        case File.mkdir(root) do
          :ok -> File.chmod(root, 0o700)
          {:error, :eexist} -> private_root(root)
          error -> error
        end

      _ ->
        {:error, :unsafe_root}
    end
  end

  defp discard(path) do
    File.rmdir(path)
    {:error, :unsafe_root}
  end

  # Linux only. A reused PID keeps stale data until a later sweep. Dedicated
  # roots must be local to a single PID namespace.
  def sweep(root) do
    if :os.type() == {:unix, :linux} and File.dir?("/proc") do
      with :ok <- private_root(root),
           {:ok, names} <- File.ls(root) do
        Enum.each(names, fn name ->
          case Regex.run(~r/\Afw-([1-9][0-9]{0,9})-[A-Za-z0-9_-]{32}\z/, name) do
            [_, pid] ->
              if File.lstat("/proc/" <> pid) == {:error, :enoent} do
                File.rm_rf(Path.join(root, name))
              end

            _ ->
              :ok
          end
        end)
      end
    end

    :ok
  end
end
