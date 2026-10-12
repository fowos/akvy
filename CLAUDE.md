# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Akvy is a self-hosted, horizontally scaled FFmpeg conversion service (Phoenix 1.8 + LiveView, Oban, Postgres, S3-compatible storage). `README.md` documents the client API, env configuration, deployment and graceful shutdown in detail; `AGENTS.md` holds the Phoenix/Elixir/HEEx coding rules and **must be followed** (it is the authoritative style guide for this repo).

## Commands

```bash
docker compose up -d                 # Postgres + RustFS (S3) for local dev
mix setup                            # deps, DB create/migrate/seed, assets
mix akvy.create_admin admin@example.com "a long password"   # no public registration
mix phx.server                       # needs ffmpeg in PATH
mix test                             # alias: creates + migrates the test DB first (needs Postgres)
mix test test/akvy/tasks_test.exs    # single file
mix test test/akvy/tasks_test.exs:42 # single test
mix test --failed
mix precommit                        # compile --warnings-as-errors, deps.unlock --unused, format, test — run before finishing
mix akvy.tasks.rebuild ID            # recompute a task snapshot from its event history
docker compose --profile app up -d --build   # two clustered release nodes on :4000 and :4001
```

## Architecture

All instances are identical: each serves HTTP and runs conversions, sharing one Postgres DB and one bucket. Nodes form an Erlang cluster discovered via Postgres `NOTIFY` (`libcluster_postgres`), so `Phoenix.PubSub` broadcasts reach every node.

**Task state is event-sourced** — the key concept spanning `lib/akvy/tasks*`:
- `task_events` (append-only, source of truth) → folded by `Akvy.Tasks.Projector` (pure; validates allowed status transitions) into the `tasks` snapshot.
- All state changes go through `Akvy.Tasks.record/3` (or `record_fresh/3`, which reloads and retries once on `:stale`). It inserts the event and updates the snapshot in one transaction guarded by an optimistic lock on `tasks.version` (= last event `seq`), then broadcasts a notification payload on PubSub topics (`task:<id>`, `api_key:<id>`, `tasks`). Never update `tasks` rows directly — add/extend an event type and its projection instead, so live writes and `rebuild_snapshot` stay consistent.
- Consecutive transitions with no I/O between them (end of one stage + start of the next) go through `Tasks.record_all/2` as one transaction.
- `tasks.status`, `task_events.type`, `task_logs.source/level` are `smallint` via `Ecto.Enum, values: [name: code]`. Codes are persisted: never renumber or reuse them, only append; a migration converting existing rows must hardcode the mapping.
- `task_logs` holds ffmpeg/worker output, batched via `Akvy.Tasks.LogBuffer`, pruned per queue `log_retention_days`.
- Statuses: `uploaded → processing (→ retrying → processing …) → completed → downloading → downloaded | expired`, or `failed` / `cancelled`.

**Conversion pipeline** — `Akvy.Workers.Convert` (Oban queue `convert`): S3 download → ffmpeg → S3 upload, each stage recorded as `*_started`/`*_finished` events with `duration_ms` (feeds dashboard stage stats). Source file is kept between failed attempts, deleted on success or final failure. Per-job timeout comes from `job.meta["timeout_ms"]` (set from the queue). A "queue" (`Akvy.Queues.Queue`) is an admin-defined ffmpeg command template with `{input}`/`{output}` placeholders plus limits; `Akvy.FFmpeg` splits it into argv (never a shell) and kills the OS process on timeout or caller death.

**Instance liveness & recovery** — `Akvy.Instance` gives each node an id (also used as Oban `node`). `Akvy.Heartbeat` writes `instance_heartbeats`; the `RescueOrphans` cron (replaces Oban Lifeline) retries/fails jobs and releases downloads only of dead instances, via `Akvy.Recovery`. Cron jobs (`ExpireFiles`, `RescueOrphans`, `PruneLogs`) are configured in `config/config.exs` and run on the Oban leader only.

**Graceful shutdown** relies on supervision-tree child order in `Akvy.Application` (children stop in reverse): `Shutdown.HttpDrain` (last) → `Endpoint` → `Shutdown.JobDrain` (right after Oban) → Oban. Keep this ordering when adding children. See `Akvy.Shutdown` moduledoc.

**Storage** — `Akvy.Storage` is a behaviour facade; adapter `Akvy.Storage.S3` (ExAws, path-style) in dev/prod, `Akvy.Storage.Local` in tests. Keys: `inputs/<id>`, `outputs/<id>.<ext>`.

**Web layer** (`lib/akvy_web/router.ex`):
- Client API `/api/v1/*` in `AkvyWeb.Api`, authenticated by `AkvyWeb.Plugs.ApiKeyAuth` (Bearer key; SSE routes also accept `?api_key=`). Three pipelines: `:api` (JSON), `:api_raw` (binary result download), `:api_sse` (event streams). OpenAPI spec via `open_api_spex` (`AkvyWeb.ApiSpec`, schemas in `api/schemas/`), served at `/api/openapi` and Swagger UI at `/api/docs`; `api_spec_test.exs` checks it — update schemas when changing API responses.
- Uploads use a custom `AkvyWeb.MultipartParser` (per-queue size limits).
- Admin LiveViews under `/admin` in `live_session :require_authenticated_user` (`AkvyWeb.Admin.*`); LiveDashboard at `/admin/system`. User settings use a separate `live_session :require_authenticated_user_settings`.
- `/health` (no pipeline) checks DB and returns 503 while draining.

IDs everywhere are UUIDv7 (`use Akvy.Schema`).

## Testing notes

`config/test.exs` swaps in test doubles: `Oban testing: :manual` (enqueue then drain/perform explicitly), `Akvy.FFmpeg` runner = `Akvy.FakeFFmpeg` (choose behaviour per test with `FakeFFmpeg.set_mode(:ok | :fail | :timeout | :no_output)`), Local storage under the system tmp dir, Heartbeat and Shutdown children disabled. Fixtures live in `test/support/fixtures/` (`conversion_fixtures.ex` for queues/tasks/api keys).
