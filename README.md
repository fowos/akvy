# Akvy

Self-hosted FFmpeg conversion service that scales horizontally. Clients upload a file into
a **queue** (an ffmpeg command template), the service converts it, notifies the client
over **Server-Sent Events** and serves the result for download. Files live in S3-compatible
storage (RustFS, MinIO, AWS S3). The admin panel shows statistics and a precise timeline
for every task.

## Architecture

- **Identical instances in an Erlang cluster.** Every instance serves HTTP and runs
  conversions. They share a single Postgres database and the same configuration.
- **Cluster discovery through Postgres.** Nodes announce themselves with `NOTIFY`
  heartbeats (`libcluster` + `libcluster_postgres`) and connect to each other. No DNS,
  Kubernetes API or Redis is required.
- **Work distribution** uses [Oban](https://hexdocs.pm/oban) (Postgres). Each instance runs
  up to `FFMPEG_CONCURRENCY` ffmpeg processes.
  - If an instance dies, `Lifeline` rescues its jobs.
  - Cron jobs (file expiry, log pruning) run only on the leader instance.
- **SSE across instances.** Task events are broadcast with the cluster-wide
  `Phoenix.PubSub`, so a client can follow a task from any instance.
- **Migrations run on boot.** Every instance runs them; a Postgres advisory lock lets
  only one do the work, and the database is created on first start. Set
  `AUTO_MIGRATE=false` to run them manually with `bin/akvy eval "Akvy.Release.migrate()"`.
- **Task storage** uses three tables:
  - `tasks` is the snapshot of the current state. It is indexed and denormalized for
    search and statistics.
  - `task_events` is the append-only history with stage durations. It is the source of
    truth: `Akvy.Tasks.Projector` folds events into the snapshot, and
    `mix akvy.tasks.rebuild ID` can recompute a snapshot from it. An optimistic lock
    on `tasks.version` prevents conflicting writes from different instances.
  - `task_logs` holds ffmpeg and worker output. It is pruned after the queue's
    `log_retention_days`.
- **IDs** are UUIDv7 (`uuidv7` package, `Akvy.Schema`).

### File lifecycle

```
upload ──► inputs/<id> ──► processing ──► outputs/<id>.<ext> ──► downloaded ──► result deleted
                               │   (source deleted on success)      └─ not downloaded within
                               │                                        queue TTL ──► expired, result deleted
                               └─ failed after the last attempt ──► source deleted
```

A failed attempt keeps the source file so that the conversion can be retried.

### Task statuses

`uploaded → processing (→ retrying → processing …) → completed → downloading → downloaded | expired`,
or `failed` / `cancelled`.

## Client API

The interactive documentation (Swagger UI) is served at **`/api/docs`**, and the OpenAPI
spec at `/api/openapi`. All requests use `Authorization: Bearer <api key>`. You create
API keys in the admin panel.

```bash
# 1. pick a queue
curl -H "Authorization: Bearer $KEY" http://localhost:4000/api/v1/queues

# 2. upload a file (limits and accepted content types are configured per queue)
curl -H "Authorization: Bearer $KEY" -F file=@clip.mov \
  http://localhost:4000/api/v1/queues/$QUEUE_ID/tasks

# 3. follow progress (any instance); the stream closes when the task is finished
curl -N -H "Authorization: Bearer $KEY" http://localhost:4001/api/v1/tasks/$TASK_ID/events

# 4. download — the result is deleted after a complete download
curl -OJ -H "Authorization: Bearer $KEY" http://localhost:4000/api/v1/tasks/$TASK_ID/result
```

A browser `EventSource` cannot send headers, so the SSE endpoints also accept
`?api_key=...`. `GET /api/v1/events` streams events for all tasks of the key.

Each SSE message looks like this:

```
event: task
id: 14
data: {"id":"…","status":"completed","event":"completed","seq":14,"attempt":1,…}
```

## Admin panel

The admin panel is at `/admin`. Public registration is disabled. Create an admin with:

```bash
mix akvy.create_admin admin@example.com "a long password"
# in a release:
bin/akvy eval 'Akvy.Release.create_admin("admin@example.com", "a long password")'
```

| Page | What it shows |
| --- | --- |
| Cluster | Nodes online, ffmpeg slots used/total, CPU, memory, load, run queue, uptime and a 5-minute history per node |
| Dashboard | Load, success and failure counts, throughput, average and p50/p95 per stage (client upload, queue wait, S3 download, ffmpeg, S3 upload), per-queue stats, instance activity |
| Queues | ffmpeg template, max upload size, accepted content types, timeout, attempts, result TTL, log retention |
| Tasks | Live list of tasks with filters |
| Task | Time breakdown, per-attempt bars, full event history with durations and instance, ffmpeg logs |
| API keys | Create and revoke keys |
| `/admin/system` | Phoenix LiveDashboard |

## Configuration (environment)

Every instance uses the same values.

| Variable | Default | |
| --- | --- | --- |
| `DATABASE_URL` | — | `ecto://user:pass@host/db` (prod) |
| `SECRET_KEY_BASE` | — | `mix phx.gen.secret` (prod) |
| `PHX_HOST` | `example.com` | public host |
| `PORT` | `4000` | |
| `S3_ENDPOINT` | `http://localhost:9000` | RustFS/MinIO/S3 endpoint, path-style |
| `S3_BUCKET` | `akvy` | created on start if missing |
| `S3_REGION` | `us-east-1` | |
| `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` | `rustfsadmin` | |
| `FFMPEG_PATH` | `ffmpeg` | |
| `FFMPEG_CONCURRENCY` | CPU count | ffmpeg processes per instance |
| `WORK_DIR` | system tmp | local scratch space for conversions |
| `INSTANCE_NAME` | Erlang node name | shown in the admin panel and the task history |
| `RELEASE_COOKIE` | build-time cookie | **must be identical on all nodes** to form the cluster |
| `RELEASE_NODE` | `akvy@<container IP>` | Erlang node name; other nodes must be able to reach this host |
| `DIST_PORT` | `9100` | Erlang distribution port (plus EPMD on 4369) |
| `CLUSTER_ENABLED` | `true` | set `false` to run nodes without clustering |
| `AUTO_MIGRATE` | `true` | run migrations on boot |
| `POOL_SIZE` | `10` | DB connections per instance |

Upload size limits, the ffmpeg command, timeouts, attempts and retention are set **per queue**
in the admin panel.

## Development

```bash
docker compose up -d          # Postgres + RustFS
mix setup
mix akvy.create_admin admin@example.com "a long password"
mix phx.server                # needs ffmpeg in PATH
mix test
```

## Deployment

The `Dockerfile` builds a release image that includes ffmpeg. To run two instances behind
the same database and storage locally:

```bash
docker compose --profile app up -d --build   # two clustered nodes: http://localhost:4000 and :4001
docker compose exec akvy-1 bin/akvy eval 'Akvy.Release.create_admin("admin@example.com", "a long password")'
```

- Put the instances behind any load balancer; no sticky sessions are needed.
- Nodes must reach each other on ports 4369 (EPMD) and `DIST_PORT`, and share
  `RELEASE_COOKIE`. Keep these ports on a private network.
- For SSE, raise the proxy read timeout and disable response buffering. The service
  sends `X-Accel-Buffering: no` and a ping every 15 seconds.
- `GET /health` checks the database and can be used as the readiness probe.
