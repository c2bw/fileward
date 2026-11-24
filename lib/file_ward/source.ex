defmodule FileWard.Source do
  @moduledoc false
  alias FileWard.Error

  def build({:stream, enumerable, metadata}, _policy) do
    if Keyword.keyword?(metadata) and
         Enum.all?(metadata, fn {key, value} ->
           key in [:filename, :content_type] and (is_nil(value) or is_binary(value))
         end) do
      {:ok, :stream, fn state, write -> stream(enumerable, metadata, state, write) end}
    else
      Error.result(:body, :invalid_source)
    end
  end

  def build({:upload, upload}, _policy) do
    if Code.ensure_loaded?(FileWard.Plug) do
      apply(FileWard.Plug, :build, [upload])
    else
      Error.result(:body, :invalid_source)
    end
  end

  def build({:url, url}, policy) do
    {:ok, :url, fn state, write -> FileWard.HTTP.Fetcher.fetch(url, policy, state, write) end}
  end

  def build(_, _), do: Error.result(:body, :invalid_source)

  def stream(enumerable, metadata, state, write) do
    enumerable
    |> Enum.reduce_while({:ok, state}, fn chunk, {:ok, acc} ->
      case write.(chunk, acc) do
        {:ok, next} -> {:cont, {:ok, next}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, result} -> {:ok, result, metadata}
      error -> error
    end
  rescue
    _ -> Error.result(:body, :invalid_content)
  catch
    _, _ -> Error.result(:body, :invalid_content)
  end
end
