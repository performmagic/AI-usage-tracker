# Housekeeping status

Date: 2026-10-06

## Repository relationship

This repository is a GitHub fork of `Danielw412/AI-usage-tracker` with local Windows-oriented work maintained by `performmagic`.

GitHub currently reports no repository license for the upstream project. Do not infer or add a license on behalf of upstream without a verified source.

## Security boundary to verify

Current server startup derives the listen host from `HOST`; when `HOST` is blank the Node server is started without an explicit host. The dashboard itself is unauthenticated, while collector sync endpoints use the configured sync secret.

Operational requirement until this is resolved in code/configuration:

- set `HOST` explicitly to the intended interface (`127.0.0.1` for local-only use, or a private/Tailscale address for the central server);
- do not expose the dashboard port to an untrusted network;
- keep `.env` and usage/session data out of Git;
- treat any future change to the default bind behavior as a security change that needs synthetic regression tests.

This file records the housekeeping finding only. It does not claim that a deployed instance is currently externally reachable.

## Versioning baseline

The repository currently carries application version `0.1.0` but has no GitHub tag or Release. Do not fabricate earlier Releases. Establish the next verified delivery baseline with a tag/release only when the candidate source SHA and validation evidence are known.
