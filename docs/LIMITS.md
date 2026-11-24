# Limits

## Ingestion

| Setting | Default |
| --- | --- |
| Input bytes | 20 MiB |
| Signature prefix | 4 KiB |
| Active operations per FileWard node | 16 |
| Reserved staging bytes per FileWard node | 512 MiB |
| Total acquisition and extraction deadline | 30 seconds |
| HTTPS socket idle timeout | 5 seconds |

Admission reserves the configured input cap plus the ZIP output cap where applicable. Active policies share a node-wide budget and the most restrictive active limits apply to new admissions. The budget counts logical staged bytes and excludes filesystem metadata and content written by application callbacks. The reservation remains held until the callback and cleanup finish. Acquisition time limits end before the callback. Apply service-level request concurrency limits, filesystem quotas, and callback timeouts independently.

Signature checks recognize JPEG, PNG, GIF87a/GIF89a, PDF and ZIP. Media signatures only identify a small prefix. A matching file can contain malformed structures, polyglot content or executable payloads.

## HTTPS

The client sends one direct HTTP/1 GET to an approved numeric address. It accepts status 200 with exactly one valid Content-Length or a single chunked Transfer-Encoding, and accepts identity content encoding. It rejects redirects, close-delimited bodies, unsolicited trailers, credentials, URL fragments and non-ASCII DNS names. URLs are limited to 8 KiB. Mint's pre-parse limit for response lines, headers and trailers is 16 KiB per section. The completed header list has a 100-header limit. TLS 1.2 and 1.3 use OTP trust roots. Literal IP URLs require a matching IP SAN.

A and AAAA DNS answers are both checked. FileWard conservatively rejects special-purpose ranges, including some registry entries marked globally reachable. Public-address classification cannot identify every deployment's private routes or future special-use allocations. Keep outbound network controls in place.

## ZIP

FileWard accepts classic single-disk ZIP with stored and raw DEFLATE entries, contiguous local records and matching local and central metadata. It checks the expanded count, CRC-32 and independent per-entry and aggregate caps. It rejects encrypted, ZIP64, split, data-descriptor, and self-extracting ZIPs. It permits only extended timestamps, NTFS metadata and Unix UID/GID extra fields, whose contents it ignores. Other extra fields, non-file and non-directory modes, link metadata, conflicting file/directory names and normalized case collisions reject the archive.

Names must be valid UTF-8, use slash-separated relative segments, and avoid ambiguous Windows names. The stored name limit is 1024 bytes with a 255-byte limit per segment. Allowed extensions apply to files, whose contents remain application data. Nested archive rejection recognizes common ZIP, gzip, bzip2, xz, 7z, RAR and ustar signatures near the start of the file. This heuristic does not recognize every possible archive encoding. FileWard performs no recursive extraction.

The library uses OTP zlib's bounded `safeInflate/2` output and checks each output block before writing it. The central and local record verifier is intentionally limited to this ZIP subset. Zstream's streaming decoder stops at the central directory and does not verify both record sets against each other. OTP's general ZIP extraction does not expose a per-output policy hook. [Zstream source](https://github.com/ananthakumaran/zstream/blob/master/lib/zstream/unzip.ex), [OTP zlib](https://www.erlang.org/doc/apps/erts/zlib.html)

## Local performance baseline

On Linux tmpfs with Elixir 1.20.2, OTP 29.0.4 and four BEAM schedulers, seven warm single-operation runs had median times of 37 ms for staging and hashing an 8 MiB PDF from 64 KiB chunks and 50 ms for staging and extracting an 8 MiB stored ZIP entry. These measurements include synchronous file writes and cleanup and represent local tmpfs performance.
