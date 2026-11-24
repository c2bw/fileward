# Usage

## Stream and URL intake

Provide a private staging directory and a nonempty media allowlist. The staging directory must have mode `0700` and be owned by the service account. FileWard can create it under an existing trusted parent.

```elixir
policy = FileWard.Policy.new!(
  staging_dir: "/var/lib/myapp/fileward",
  media_types: ["application/pdf"],
  max_bytes: 8 * 1024 * 1024,
  total_timeout_ms: 15_000
)

stream = File.stream!(trusted_path, 64 * 1024)
FileWard.with_file({:stream, stream, [filename: "invoice.pdf"]}, policy, fn file ->
  MyApp.Invoices.import(file.path)
end)

FileWard.with_file({:url, user_url}, policy, &MyApp.Invoices.import(&1.path))
```

Each enumerable element must be a binary. Enumeration runs in an acquisition worker. Callers should yield small chunks and open resources from inside enumeration when practical. An already allocated large input chunk counts toward the memory of the calling application. A timeout forcibly ends the worker, so cleanup of application-owned resources must tolerate process termination.

The supplied filename and declared type are untrusted metadata. Enable `strict_media_type: true` to reject a present declaration that disagrees with the detected type. Any publication or durable copy belongs inside the callback. The callback can return the value of that operation without keeping the staging path.

## Plug uploads

Pass a parsed `%Plug.Upload{}` to `FileWard.with_file/3` as `{:upload, upload}`. FileWard applies the same file policy as stream and URL intake.

Set upload limits independently in the HTTP server and multipart parser. Plug's multipart limit applies while it receives and stages parts. FileWard's `max_bytes` applies to the staged file afterward. Keep both temporary directories outside web roots.

## ZIP extraction

```elixir
intake = FileWard.Policy.new!(
  staging_dir: "/var/lib/myapp/fileward",
  media_types: ["application/zip"],
  max_bytes: 20 * 1024 * 1024
)

zip = FileWard.ArchivePolicy.new!(
  max_entries: 500,
  max_total_uncompressed_bytes: 100 * 1024 * 1024,
  max_entry_bytes: 20 * 1024 * 1024,
  max_path_depth: 12,
  max_expansion_ratio: 100,
  allowed_extensions: [".txt", ".csv", ".png"]
)

FileWard.with_archive({:url, user_url}, intake, zip, fn archive ->
  MyApp.Importer.process(archive.directory, archive.entries)
end)
```

The ZIP media type must be in the intake allowlist. The callback runs after all entries have been checked and extracted, with relative paths in `archive.entries` and the total expanded size in `archive.size_bytes`.

## Operations

Configure boot-time stale staging cleanup with `config :file_ward, staging_roots: ["/var/lib/myapp/fileward"]`. A root supplied only through a policy is swept at first successful admission and periodically thereafter on Linux.

If Telemetry is installed, FileWard emits `[:file_ward, :ingest, :start | :stop | :exception]`, `[:file_ward, :policy, :rejected]` and `[:file_ward, :archive, :stop]`. A successful ingestion stop measures elapsed monotonic time and file bytes. The archive event also reports entry count and expanded bytes. Handlers run on a separate dispatcher with at most one pending delivery per event type. Events can be dropped while that type is pending.
