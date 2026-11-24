defmodule FileWard.Limiter do
  @moduledoc false
  use GenServer
  alias FileWard.{Error, Staging}

  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  def run(policy, reserve, acquire),
    do: GenServer.call(__MODULE__, {:run, policy, reserve, acquire}, :infinity)

  def release(manager, ticket) do
    GenServer.call(manager, {:release, ticket}, :infinity)
  catch
    :exit, _ -> Error.result(:cleanup, :storage_error)
  end

  @impl true
  def init(_) do
    Process.flag(:trap_exit, true)
    Process.send_after(self(), :sweep, 60_000)
    {:ok, %{jobs: %{}, roots: MapSet.new()}, {:continue, :startup_sweep}}
  end

  @impl true
  def handle_continue(:startup_sweep, state) do
    roots =
      for root <- Application.get_env(:file_ward, :staging_roots, []),
          is_binary(root) and Path.type(root) == :absolute and Path.expand(root) != "/",
          {:ok, probe} <- [Staging.create(root)],
          into: MapSet.new() do
        Staging.sweep(Path.expand(root))
        File.rmdir(probe)
        Path.expand(root)
      end

    {:noreply, %{state | roots: roots}}
  end

  @impl true
  def handle_call({:run, policy, reserve, acquire}, {caller, _}, state) do
    count_limit =
      Enum.reduce(state.jobs, policy.max_inflight, fn {_, j}, limit ->
        min(limit, j.count_limit)
      end)

    disk_limit =
      Enum.reduce(state.jobs, policy.disk_budget_bytes, fn {_, j}, limit ->
        min(limit, j.disk_limit)
      end)

    reserved = Enum.reduce(state.jobs, reserve, fn {_, j}, total -> total + j.reserve end)

    cond do
      map_size(state.jobs) >= count_limit -> {:reply, Error.result(:stage, :busy), state}
      reserved > disk_limit -> {:reply, Error.result(:stage, :capacity_exceeded), state}
      true -> admit(state, caller, policy, reserve, acquire)
    end
  end

  def handle_call({:release, ticket}, _, state) do
    {job, jobs} = Map.pop(state.jobs, ticket)
    reply = if job, do: cleanup(job, ticket), else: :ok
    {:reply, reply, %{state | jobs: jobs}}
  end

  defp admit(state, caller, policy, reserve, acquire) do
    deadline = System.monotonic_time(:millisecond) + policy.total_timeout_ms
    root = Path.expand(policy.staging_dir)

    case Staging.create(root) do
      {:ok, path} ->
        unless MapSet.member?(state.roots, root), do: Staging.sweep(root)
        ticket = Process.monitor(caller)
        manager = self()

        {worker, monitor} =
          :erlang.spawn_opt(
            fn ->
              result =
                try do
                  acquire.(path)
                rescue
                  _ -> Error.result(:body, :internal_error)
                catch
                  _, _ -> Error.result(:body, :internal_error)
                end

              send(manager, {:result, ticket, self(), result})
            end,
            [:link, :monitor]
          )

        timer = Process.send_after(self(), {:timeout, ticket}, deadline, abs: true)

        job = %{
          caller: caller,
          worker: worker,
          monitor: monitor,
          timer: timer,
          deadline: deadline,
          path: path,
          reserve: reserve,
          disk_limit: policy.disk_budget_bytes,
          count_limit: policy.max_inflight
        }

        {:reply, {:ok, ticket, self()},
         %{state | jobs: Map.put(state.jobs, ticket, job), roots: MapSet.put(state.roots, root)}}

      _ ->
        {:reply, Error.result(:stage, :storage_error), state}
    end
  end

  @impl true
  def handle_info({:result, ticket, worker, result}, state) do
    case state.jobs do
      %{^ticket => %{worker: ^worker} = job} ->
        {:noreply, put_in(state.jobs[ticket], Map.put(job, :result, result))}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:timeout, ticket}, state) do
    case state.jobs do
      %{^ticket => %{worker: worker} = job} when is_pid(worker) ->
        Process.exit(worker, :kill)
        {:noreply, put_in(state.jobs[ticket], Map.put(job, :timed_out, true))}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _, _}, state) do
    case state.jobs do
      %{^ref => %{worker: worker} = job} when is_pid(worker) ->
        Process.exit(worker, :kill)
        {:noreply, put_in(state.jobs[ref], %{job | caller: nil})}

      %{^ref => job} ->
        cleanup(job, ref)
        {:noreply, update_in(state.jobs, &Map.delete(&1, ref))}

      _ ->
        case Enum.find(state.jobs, fn {_, job} -> job.monitor == ref end) do
          {ticket, job} ->
            result =
              cond do
                Map.get(job, :timed_out) -> Error.result(:body, :timeout)
                Map.has_key?(job, :result) -> job.result
                true -> Error.result(:body, :internal_error)
              end

            {:noreply, finish(state, ticket, job, result)}

          nil ->
            {:noreply, state}
        end
    end
  end

  def handle_info({:EXIT, _, _}, state), do: {:noreply, state}

  def handle_info(:sweep, state) do
    Enum.each(state.roots, &Staging.sweep/1)
    Process.send_after(self(), :sweep, 60_000)
    {:noreply, state}
  end

  defp finish(state, ticket, job, result) do
    Process.cancel_timer(job.timer)
    Process.demonitor(job.monitor, [:flush])

    if job.caller do
      result =
        if match?({:ok, _, _}, result) and System.monotonic_time(:millisecond) >= job.deadline,
          do: Error.result(:body, :timeout),
          else: result

      send(job.caller, {:file_ward, ticket, result})
      put_in(state.jobs[ticket], %{job | worker: nil, monitor: nil})
    else
      cleanup(job, ticket)
      update_in(state.jobs, &Map.delete(&1, ticket))
    end
  end

  defp cleanup(job, ticket) do
    Process.demonitor(ticket, [:flush])

    case File.rm_rf(job.path) do
      {:ok, _} -> :ok
      _ -> Error.result(:cleanup, :storage_error)
    end
  end
end
