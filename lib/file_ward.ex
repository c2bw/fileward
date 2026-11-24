defmodule FileWard do
  @moduledoc "Bounded file acquisition and ZIP extraction with callback-scoped staging."

  alias FileWard.{Archive, ArchivePolicy, Artifact, Error, Limiter, Policy, Source, Writer}

  @type source :: {:stream, Enumerable.t(), keyword()} | {:upload, struct()} | {:url, binary()}

  @doc "Stages and validates a file before calling the supplied function synchronously."
  @spec with_file(source(), Policy.t(), (Artifact.t() -> result)) ::
          {:ok, result} | {:error, Error.t()}
        when result: var
  def with_file(source, policy, callback) when is_function(callback, 1) do
    intake(source, policy, 0, fn artifact, _ -> {:ok, artifact} end, callback)
  end

  @doc "Validates and extracts a ZIP before calling the supplied function synchronously."
  @spec with_archive(source(), Policy.t(), ArchivePolicy.t(), (Archive.t() -> result)) ::
          {:ok, result} | {:error, Error.t()}
        when result: var
  def with_archive(source, policy, archive_policy, callback) when is_function(callback, 1) do
    if ArchivePolicy.valid?(archive_policy) do
      intake(
        source,
        policy,
        archive_policy.max_total_uncompressed_bytes,
        &Archive.extract(&1, &2, archive_policy),
        callback
      )
    else
      Error.result(:extract, :invalid_policy)
    end
  end

  defp intake(source, policy, extra, prepare, callback) do
    with true <- Policy.valid?(policy) || Error.result(:stage, :invalid_policy),
         {:ok, kind, producer} <- Source.build(source, policy) do
      started = System.monotonic_time()
      FileWard.Telemetry.emit(:ingest, :start, %{}, %{source_kind: kind})

      case Limiter.run(policy, policy.max_bytes + extra, fn directory ->
             with {:ok, artifact} <- Writer.run(directory, policy, kind, producer),
                  {:ok, result} <- prepare.(artifact, directory) do
               {:ok, result, artifact}
             end
           end) do
        {:ok, ticket, manager} ->
          scoped(manager, ticket, kind, started, callback)

        {:error, error} = failure ->
          report_error(kind, started, error)
          failure
      end
    end
  end

  defp scoped(manager, ticket, kind, started, callback) do
    monitor = Process.monitor(manager)

    result =
      try do
        receive do
          {:file_ward, ^ticket, {:ok, result, artifact}} ->
            measurements =
              elapsed(started)
              |> Map.merge(%{
                bytes_received: artifact.size_bytes,
                bytes_staged: artifact.size_bytes
              })

            meta = %{source_kind: kind, detected_media_type: artifact.detected_media_type}

            if match?(%Archive{}, result) do
              FileWard.Telemetry.emit(
                :archive,
                :stop,
                Map.merge(measurements, %{
                  zip_entries: length(result.entries),
                  zip_output_bytes: result.size_bytes
                }),
                meta
              )
            end

            FileWard.Telemetry.emit(:ingest, :stop, measurements, meta)
            {:ok, callback.(result)}

          {:file_ward, ^ticket, {:error, error} = failure} ->
            report_error(kind, started, error)
            failure

          {:DOWN, ^monitor, :process, ^manager, _} ->
            Error.result(:stage, :internal_error)
        end
      catch
        type, value ->
          stack = __STACKTRACE__
          Limiter.release(manager, ticket)
          FileWard.Telemetry.emit(:ingest, :exception, elapsed(started), %{source_kind: kind})
          :erlang.raise(type, value, stack)
      after
        Process.demonitor(monitor, [:flush])
      end

    case Limiter.release(manager, ticket) do
      :ok -> result
      error -> error
    end
  end

  defp elapsed(started), do: %{duration: System.monotonic_time() - started}

  defp report_error(kind, started, error) do
    meta = %{source_kind: kind, error_code: error.code}
    FileWard.Telemetry.emit(:ingest, :stop, elapsed(started), meta)
    FileWard.Telemetry.emit(:policy, :rejected, elapsed(started), meta)
  end
end
