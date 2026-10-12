# Akvy

Self-hosted FFmpeg conversion service that scales horizontally. Clients upload a file into
a **queue** (an ffmpeg command template), the service converts it, notifies the client
over **Server-Sent Events** and serves the result for download. Files live in S3-compatible
storage (RustFS, MinIO, AWS S3). The admin panel shows statistics and a precise timeline
for every task.

![Admin panel dashboard](docs/screenshots/dashboard.png)

## Architecture

- **Identical instances in an Erlang cluster.** Every instance serves HTTP and runs
  conversions. They share a single Postgres database and the same configuration.
- **Cluster discovery through Postgres.** Nodes announce themselves with `NOTIFY`
  heartbeats (`libcluster` + `libcluster_postgres`) and connect to each other. No DNS,
  Kubernetes API or Redis is required.
- **Work distribution** uses [Oban](https://hexdocs.pm/oban) (Postgres). Each instance runs
  up to `FFMPEG_CONCURRENCY` ffmpeg processes.
  - Every instance writes a heartbeat to `instance_heartbeats` every 10 s. An instance
    is dead after 60 s without a heartbeat; within one to two minutes after it dies,
    `RescueOrphans` (every minute) retries its conversions
    (or fails them on the last attempt) and releases its in-flight downloads. Live long
    jobs are never restarted.
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

Other endpoints: `GET /api/v1/tasks` (tasks of the key, paginated with `next_cursor`),
`GET /api/v1/tasks/{id}` and `DELETE /api/v1/tasks/{id}` (cancel).

### Server-Sent Events

A browser `EventSource` cannot send headers, so the SSE endpoints also accept
`?api_key=...`.

- `GET /api/v1/tasks/{id}/events` starts with a snapshot of the current state
  (`"event":"snapshot"`), then sends every task event. It closes once the task is
  `completed`, `failed`, `cancelled`, `expired` or `downloaded`.
- `GET /api/v1/events` streams events of all tasks of the key (optionally
  `?queue_id=...`) and never closes on its own. It sends no snapshot.

Each SSE message looks like this:

```
event: task
id: 14
data: {"id":"…","queue_id":"…","status":"completed","event":"completed","seq":14,"attempt":1,"occurred_at":"…","duration_ms":null,"error":null,"output_size":1048576,"expires_at":"…"}
```

`id` and `seq` are the per-task event number. `status` is the task status after the event;
`event` is the event type (`uploaded`, `attempt_started`, `ffmpeg_finished`,
`retry_scheduled`, `completed`, …, see `TaskEvent` in `/api/docs`). A `: ping` comment is
sent every 15 s. Missed events are not replayed on reconnect (`Last-Event-ID` is ignored):
a per-task stream starts again from a fresh snapshot, and for `/api/v1/events` use
`GET /api/v1/tasks` to catch up. When an instance shuts down it closes its streams, and
`EventSource` reconnects to another instance.

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
| `CLUSTER_CHANNEL` | `akvy_cluster` | Postgres `NOTIFY` channel used for node discovery |
| `AUTO_MIGRATE` | `true` | run migrations on boot |
| `POOL_SIZE` | `10` | DB connections per instance |
| `ECTO_IPV6` | `false` | connect to Postgres over IPv6 |
| `SHUTDOWN_DRAIN_SECONDS` | `5` | time `/health` returns 503 before HTTP stops |
| `SHUTDOWN_JOBS_SECONDS` | `30` | time running conversions get to finish on shutdown |

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
- `GET /health` checks the database and can be used as the readiness probe. It returns
  503 while the instance is shutting down.

### Installing with external PostgreSQL and S3

This guide runs Akvy from a prebuilt image on servers where PostgreSQL and S3-compatible
storage already run separately. Docker is the only thing needed on the Akvy servers:
the image contains ffmpeg.

**1. Build the image and copy it to the server.** On a machine with the source code:

```bash
docker build -t akvy:1.0.0 .     # on Apple Silicon add --platform linux/amd64 for x86 servers
docker save akvy:1.0.0 -o akvy.tar
scp akvy.tar user@server:/opt/akvy/
```

On the server:

```bash
docker load -i /opt/akvy/akvy.tar
```

**2. Prepare PostgreSQL.** Create a user and a database, and allow connections from the
Akvy servers in `pg_hba.conf`:

```sql
CREATE USER akvy WITH PASSWORD 'change-me';
CREATE DATABASE akvy OWNER akvy;
```

Migrations run automatically when an instance starts. Akvy needs a direct connection
because Oban and cluster discovery use `LISTEN/NOTIFY`, so do not put PgBouncer in
transaction mode in between. Each instance uses `POOL_SIZE` connections plus a few
for notifications; check `max_connections`.

**3. Prepare S3.** Create an access key with read/write access to the bucket. The bucket
is created on start if the key is allowed to create it; otherwise create it beforehand.
Akvy uses path-style URLs (`https://s3.example.com/<bucket>/<key>`). For AWS S3 use the
regional endpoint, for example `S3_ENDPOINT=https://s3.eu-central-1.amazonaws.com` with
`S3_REGION=eu-central-1`.

**4. Create `/opt/akvy/.env`** (the same file on every server):

```bash
DATABASE_URL=ecto://akvy:change-me@db.internal:5432/akvy
SECRET_KEY_BASE=...       # openssl rand -base64 48
RELEASE_COOKIE=...        # openssl rand -hex 32, identical on all servers
PHX_HOST=akvy.example.com # public domain, the admin panel only works on this host

S3_ENDPOINT=https://s3.example.com
S3_BUCKET=akvy
S3_REGION=us-east-1
AWS_ACCESS_KEY_ID=...
AWS_SECRET_ACCESS_KEY=...

FFMPEG_CONCURRENCY=4
```

**5. Create `/opt/akvy/compose.yml`:**

```yaml
services:
  akvy:
    image: akvy:1.0.0
    restart: unless-stopped
    env_file: .env
    environment:
      INSTANCE_NAME: akvy-1          # unique per server, shown in the admin panel
      # Only with several servers: this server's private IP, reachable from the others.
      RELEASE_NODE: akvy@10.0.0.11
    ports:
      - "4000:4000"                  # HTTP, for the reverse proxy / load balancer
      # Erlang distribution between servers. Open on the private network only.
      - "10.0.0.11:4369:4369"
      - "10.0.0.11:9100:9100"
    # Graceful shutdown budget: SHUTDOWN_DRAIN_SECONDS + 15 + SHUTDOWN_JOBS_SECONDS + 2.
    stop_grace_period: 60s
```

With a single server, remove `RELEASE_NODE` and the `4369`/`9100` ports.

**6. Start and create an admin:**

```bash
cd /opt/akvy
docker compose up -d
docker compose logs -f akvy
docker compose exec akvy bin/akvy eval 'Akvy.Release.create_admin("admin@example.com", "a long password")'
```

Repeat steps 1, 4–6 on every server with its own `INSTANCE_NAME` and `RELEASE_NODE`
(the admin only once). The servers find each other through the database; the Cluster
page in the admin panel shows all nodes.

**7. Put a reverse proxy with TLS in front.** The production build redirects plain HTTP
to HTTPS, except for requests with `Host: localhost`, so the proxy must terminate TLS and
send `X-Forwarded-Proto: https`. For a load balancer health check that calls the
instances over HTTP, send `Host: localhost`, for example
`curl -H 'Host: localhost' http://10.0.0.11:4000/health`. An nginx example:

```nginx
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      '';
}

server {
    listen 443 ssl;
    server_name akvy.example.com;
    # ssl_certificate ...;

    client_max_body_size 10g;        # at least the largest queue upload limit

    location / {
        proxy_pass http://akvy_upstream;   # upstream with all instances on :4000
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        # LiveView websockets
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        # uploads and SSE
        proxy_request_buffering off;
        proxy_buffering off;
        proxy_read_timeout 1h;
    }
}
```

**Updating.** Load the new image, change the tag in `compose.yml` and run
`docker compose up -d`. Update servers one at a time: running conversions finish or move
to other instances, and the first instance with the new version runs the migrations.

### Graceful shutdown

On SIGTERM (`docker stop`) an instance:

1. returns 503 from `/health` and stops taking conversions for `SHUTDOWN_DRAIN_SECONDS`,
   so the load balancer removes it (the health check interval must be shorter);
2. closes SSE streams, so clients reconnect to another instance, and stops HTTP
   (in-flight requests get up to 15 s);
3. waits up to `SHUTDOWN_JOBS_SECONDS` for running conversions, then hands the rest to
   other instances without spending an attempt and releases its downloads.

The container stop timeout must cover the whole sequence:
`SHUTDOWN_DRAIN_SECONDS + 15 + SHUTDOWN_JOBS_SECONDS + 2` seconds (`stop_grace_period: 60s`
in `compose.yaml`; Docker's default is 10 s). Long conversions are not waited for:
they restart on another instance.
