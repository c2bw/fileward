# FileWard

[![Hex Version](https://img.shields.io/hexpm/v/file_ward.svg)](https://hex.pm/packages/file_ward)
[![Hex Docs](https://img.shields.io/badge/docs-HexDocs-blue.svg)](https://hexdocs.pm/file_ward/)

FileWard is an Elixir library for bounded intake of binary streams, Plug uploads and HTTPS downloads. It stages data privately, checks its signature and computes a SHA-256 digest before calling your code. It can also verify and extract a restricted subset of ZIP archives.

```elixir
policy = FileWard.Policy.new!(
  staging_dir: "/var/lib/myapp/fileward",
  max_bytes: 8 * 1024 * 1024,
  media_types: ["image/png", "application/pdf"]
)

FileWard.with_file({:url, user_url}, policy, fn file ->
  MyApp.BlobStore.put(file.path, file.sha256)
end)
```

The callback runs synchronously in the caller. The path is temporary and usable only during that callback. FileWard removes staging afterward. A successful call returns `{:ok, callback_result}`. Acquisition failures return `{:error, %FileWard.Error{}}`, and callback exceptions propagate.

## Installation

Add FileWard to your Mix dependencies.

```elixir
{:file_ward, "~> 0.1.0"}
```

Run `mix deps.get`. FileWard targets Elixir 1.18+ on OTP 27+ with a local POSIX filesystem.

## Documentation

- [Usage and multipart configuration](docs/USAGE.md)
- [Supported formats and runtime limits](docs/LIMITS.md)
- [Security and deployment contract](docs/SECURITY.md)
- [Threat model](docs/THREAT_MODEL.md)
- [Release notes](CHANGELOG.md)

Run `mix deps.get` and `mix test`. The local TLS fixtures use the `openssl` test executable. The library uses OTP TLS at runtime.

## Opaque attachments

For uninterpreted attachment storage, set `content_mode: :opaque_attachment` on
the intake policy and omit `media_types` and `strict_media_type`. The artifact
reports a recognized signature when present and `nil` for an unknown signature.
Set `allow_empty: true` to admit empty attachments. Byte limits, staging,
timeouts, SHA-256 calculation and HTTPS policy still apply. Archive extraction
requires the default `:restricted_types` content mode.
