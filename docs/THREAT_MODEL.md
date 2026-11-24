# Threat model

An attacker may control URL text, DNS responses, HTTPS timing and wire data, an uploaded body and its metadata, and every byte of a ZIP. A caller can make many simultaneous attempts or disconnect mid-operation.

| Threat | Enforcement |
| --- | --- |
| DNS rebinding and internal address access | Strict URL grammar, conservative IPv4/IPv6 classification, all-answer validation, direct numeric connection, verified hostname and no redirects |
| Excess buffering and slow reads | Passive HTTP reads, Mint line/header bounds, immutable acquisition deadline and socket idle timeout |
| Disguised content | Independent signature allowlist, optional declared-type agreement |
| Staging leaks and partial publication | Private per-operation directories, monitored admission and callback-scoped lifecycle |
| ZIP traversal or overwrite | Validated path segments, Unicode and case collision checks, exclusive output files and a fresh extraction directory |
| ZIP bombs and corruption | Preflight entry and size budgets, runtime output checks, bounded DEFLATE blocks, exact byte counts and CRC verification |

The service account, staging parents, TLS trust store, deployment network configuration and application code are trusted. FileWard reserves logical disk space within its own node. It cannot enforce quotas on other services, guarantee local disk availability, protect staging from another process with write access, or prevent dangerous application-specific interpretation of accepted content. Callbacks own publication and any secondary parser exposure.
