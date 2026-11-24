# Changelog

## 0.1.0

- Add private, policy-bounded stream and optional Plug intake with media signatures, SHA-256, admission, deadlines and cleanup.
- Add public HTTPS intake with numeric address pinning, hostname-verified TLS, passive HTTP/1 reads and identity encoding.
- Add callback-scoped ZIP extraction with path collision checks, bounded stored and DEFLATE decoding, length and CRC validation, and full rollback. See the ZIP subset in [Limits](docs/LIMITS.md).
