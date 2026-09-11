# Security policy

## Supported versions

Security fixes are applied to the latest released version. Earlier versions
receive no backports.

| Version | Supported |
|---|---|
| 1.1.x | yes |
| < 1.1 | no |

## Reporting a vulnerability

Report suspected vulnerabilities through GitHub's private vulnerability
reporting (the "Report a vulnerability" button under the repository's
Security tab), not through a public issue. A report receives an
acknowledgement within a week and a decision on the fix with it.

## Scope

The package is a simulation framework: it reads TOML configurations and CSV,
HDF5, and log files, writes run directories, and spawns terminal processes on
request. Relevant reports concern the handling of untrusted input — a
configuration file, an external strain series, or a run directory produced
elsewhere — and the process and filesystem operations of the dashboard entry
point. The package opens no network connections and requires no credentials.
