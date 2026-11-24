defmodule FileWard.Error do
  @moduledoc "A structured ingestion failure with a redacted message."
  defexception [:stage, :code, retryable?: false]
  @type t :: %__MODULE__{stage: atom(), code: atom(), retryable?: boolean()}

  @impl true
  def message(error), do: "FileWard #{error.stage} failed (#{error.code})"

  @doc false
  def result(stage, code) do
    {:error,
     %__MODULE__{stage: stage, code: code, retryable?: code in [:timeout, :busy, :network_error]}}
  end
end
