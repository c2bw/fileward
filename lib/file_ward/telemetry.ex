defmodule FileWard.Telemetry do
  @moduledoc false
  use GenServer

  def start_link(_) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @impl true
  def init(_) do
    :ets.new(__MODULE__, [:named_table, :public, :set])
    {:ok, nil}
  end

  def emit(group, event, measurements, metadata) do
    if Code.ensure_loaded?(:telemetry) and Process.whereis(__MODULE__) do
      # At most one pending delivery of each event type, even with slow handlers.
      key = {group, event}

      if :ets.insert_new(__MODULE__, {key}) do
        send(__MODULE__, {key, measurements, metadata})
      end
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  @impl true
  def handle_info({{group, event} = key, measurements, metadata}, state) do
    try do
      apply(:telemetry, :execute, [[:file_ward, group, event], measurements, metadata])
    after
      :ets.delete(__MODULE__, key)
    end

    {:noreply, state}
  end
end
