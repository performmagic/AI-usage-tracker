# Security and network boundary

AI Usage Tracker reads local Codex and Claude Code session metadata and serves a dashboard containing usage history, chat names, project names, branches and related local activity context. Treat the dashboard as private operational data.

## Default network posture

New setups should copy `.env.example`, which binds `HOST=127.0.0.1` by default. This keeps standalone and collector dashboards reachable only from the local machine.

If `TRACKER_ROLE=server` must accept collectors, set `HOST` explicitly to a private interface such as a Tailscale address. Do not expose the dashboard directly to the public Internet.

The sync API uses `SYNC_SECRET` bearer authentication. Dashboard endpoints are not authenticated. Network isolation is therefore part of the security boundary.

## Existing installations

Existing `.env` files are not rewritten by repository updates. Check the deployed `HOST` value before assuming an installation is loopback-only. An unset/blank `HOST` may cause the runtime to listen more broadly depending on Node/Express behavior and the host network stack.

## Sensitive data

Do not commit `.env`, SQLite data, transcripts, OAuth tokens, sync secrets or provider credentials. Keep `data/` and machine credentials outside Git. If a credential is ever committed, rotate it rather than attempting to hide it only with a later commit.

## Upstream / fork note

This repository is a fork of `Danielw412/AI-usage-tracker` with local changes. GitHub currently reports no license metadata for the upstream repository. Do not assume a license grant beyond what the upstream repository actually provides.
