# Security

Deploy with a dedicated staging root on a local POSIX filesystem. The service account should own it, use mode `0700`, and control its parent path. Run the service with a restrictive umask. The staging root and filenames must never be reachable from a web server's static file routes. Use a root dedicated to the service within one Linux PID namespace if you enable stale staging recovery. With a shared root across hosts or namespaces, PIDs cannot identify live owners reliably.

FileWard assumes a trusted CA store, DNS resolver, ingress configuration, policy and callback. The HTTPS client pins the selected IP while retaining the original hostname for SNI and validation. Use network egress rules to cover deployment-specific routes and services. Report suspected vulnerabilities privately to the repository maintainer.

The API formats errors with the stage and a stable code. It does not include raw URLs, query parameters, headers, paths or source data. Applications may choose separately how to handle display metadata. Signature checks and CRCs do not sanitize content or establish authenticity.

Normal return, exceptions and throws trigger cleanup. Caller termination is monitored, and workers that exceed their deadline are killed. A VM crash or power loss can leave staging on disk. The Linux janitor removes recognized FileWard directories only when their owner PID is absent. PID reuse can delay reclamation. Other systems need an offline cleanup mechanism for leftovers. Storage errors can also prevent immediate removal.

## Error codes

| Stage | Codes |
| --- | --- |
| URL validation | `invalid_url` |
| DNS resolution | `unsafe_address`, `dns_failed`, `timeout` |
| Connect | `tls_failed`, `network_error`, `timeout` |
| Headers | `redirect_forbidden`, `unexpected_status`, `invalid_response`, `too_large`, `network_error`, `timeout` |
| Body | `invalid_source`, `invalid_content`, `invalid_response`, `too_large`, `network_error`, `timeout`, `internal_error` |
| Detection | `unsupported_type`, `invalid_content` |
| Staging | `invalid_policy`, `storage_error`, `busy`, `capacity_exceeded`, `internal_error` |
| Extraction | `invalid_policy`, `archive_rejected`, `storage_error` |
| Cleanup | `storage_error` |

Mint 1.11.0 is the minimum dependency baseline and incorporates the HTTP/1 bounded-parser fixes. Recheck dependencies for advisories on version changes and before release. [Mint advisories](https://github.com/elixir-mint/mint/security/advisories)
