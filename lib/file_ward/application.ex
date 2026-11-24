defmodule FileWard.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    Supervisor.start_link([FileWard.Limiter, FileWard.Telemetry], strategy: :one_for_one)
  end
end
