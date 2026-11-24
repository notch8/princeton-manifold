# Upgrading Princeton Manifold from upstream v8.1.1 to 9.2.11: discovery notes

Tracking issue: [notch8/notch8-ops#835](https://github.com/notch8/notch8-ops/issues/835).

Research only, no repo files changed. Upstream was read with `git show <ref>:<path>` and `git diff v8.1.1..9.2.11` after adding the `upstream` remote and fetching tags. GitHub API reads (`gh api`) were used for the CAS fork and for release lists.

Evidence labels used throughout:

- **[V]** verified from code or git history at the named ref
- **[I]** inferred (reasoning, or knowledge outside the repo)
- **[?]** unknown / needs a test

Tag naming: `v8.1.0`…`v8.1.2-beta.4` and `v9.0` have a `v` prefix; `9.0.1`…`9.2.11` do not.
`10.0.0-beta`/`rc.1` tags also exist (Oct–Nov 2026); `9.2.11` (2026-11-19) is GitHub's "Latest".

---

## Summary

### Recommended hop list

**Direct: v8.1.1 → 9.2.11. No intermediate release needs to be deployed.**

- [V] There are no stable tags between `v8.1.1` (2024-03-28) and `v9.0` (2026-04-21). The only intermediates are `v8.1.2-beta.1-4` (2024-06/09), and they contain no migrations: the first new migration after v8.1.1 is `20241001182627`.
- [V] All 47 new migrations (`git diff --diff-filter=A v8.1.1..9.2.11 -- api/db/migrate`) and the single new system upgrade (`Manifold090000`) ship together in 9.2.11 and run in timestamp order.
- [V] `rails db:migrate` + `rake manifold:upgrade` is the whole data upgrade. Upstream documents no other step.
- [?] Nobody has verified an end-to-end 8.1.1→9.x data upgrade on a real database. Several migrations call current model code. **Rehearse on a copy of the production DB first.**
- [I] A hop through an interim tag (e.g. 9.0) gains nothing, because the redis, searchkick and sidekiq removals and the Rails 7 upgrade are all before `v9.0`. It would only add a second deploy.

### Required chart and deploy changes

1. **Image build.**
   - Ruby 3.4.13 on Debian bookworm.
   - Node 22 in the api image (for mammoth) and `node:22.17.1` + corepack/yarn 4 for the client.
   - New apt packages: `libvips42`, `libsndfile1`, `mediainfo`, `pandoc`, `imagemagick`, `libpoppler-glib8`, `librsvg2-bin`, `libjemalloc2`, `libicu72`, `postgresql-client-13`.
2. **Remove** the `elasticsearch` and `redis` subchart dependencies and values, plus `RAILS_REDIS_URL`, `REDIS_URL` and `ELASTICSEARCH_URL` from `configmap-env.yaml`. Remove the `redis.url` helpers.
3. **Remove** the `api-cable` and `api-clockwork` deployments, the `service-api-cable` service, and the `API_CABLE_*` / `CLIENT_BROWSER_API_CABLE_URL` env. There is no Action Cable in 9.2.11.
4. **Replace `api-sidekiq`** with a good_job worker deployment: `bin/good_job start --probe-port 7001`. Probes on port 7001 are `/status/started` and `/status/connected`. Same image and env as the API.
5. **Add env:**
   - `SECRET_KEY_BASE` — the same value as the existing `RAILS_SECRET_KEY` [I].
   - The cache DB vars: `RAILS_CACHE_DB_HOST`, `_PORT`, `_USER`, `_PASS`, `_NAME`.
   - Optionally `PROXY_CLIENT_IP_HEADER` and `CLIENT_SERVER_IP` (rate limiting), `LOCKBOX_MASTER_KEY`, and `ENFORCE_CANONICAL_DOMAIN` for the client.
6. **Create the cache database** (`RAILS_CACHE_DB_NAME`) before the first migrate, or point it at the same database [I]. See §3.
7. **Add a migration step.** The current chart runs nothing: `start-and-run` is only used by local docker-compose, and no hook, init container or Job in the chart or deploy workflow runs `db:migrate`.
   - Add a Helm pre-upgrade Job running `bin/rails db:migrate` then `bin/rails manifold:upgrade`.
   - `db:migrate` also migrates the cache DB.
8. **Cutover sequence.** Drain Sidekiq (§2) before removing Redis. The `clockwork`, `cable` and `sidekiq` deployments and the subchart statefulsets disappear in the same `helm upgrade`, so decide whether to do the drain as a separate prior step.
9. **Client:**
   - Keep `yarn run start` only if `browser.config.js` is baked at build time. Upstream's image runs `npm-run-all _build:browser-config _serve:ssr` at start so the env is applied at runtime.
   - Nginx: drop the `/cable` and `/api/sidekiq/*` locations. Keep `/system` and the X-Accel mapping (still used for file storage).
10. **Postgres:**
    - 13 is the minimum (§8). The chart's Bitnami 14.5 is fine.
    - All contrib extensions are the same set already in the v8.1.1 schema.
11. **Storage:** no change. `file` is the default and public/system and data paths are unchanged (§5).
12. **App-code changes** (not chart): re-apply the CAS patch (§7), the `ALLOW_SIGNUP` client patch (the LoginForm was rewritten), and Sentry. Drop the ES search patches. Local-patch list at the end.

---

## 1. Upgrade path

### Direct hop: yes [V]

- `api/lib/tasks/upgrade.rake` at 9.2.11 is byte-identical to v8.1.1 apart from a magic comment.
  - It runs `SystemUpgrades::Perform.run force:, stdout: true`.
- `Perform` runs every `SystemUpgrades::Upgrades::ManifoldNNNNNN` class not recorded in the `upgrade_results` table, in version order.
  - `api/app/services/system_upgrades/perform.rb`.
- **After any upgrade is applied** (`applied && reindex`, `reindex` defaults to true), it runs `search.rebuild_all` (see §4).
  - Commits `5a73e5f72`, `d5795437b`.

Check the target DB before upgrading:

```sql
SELECT version FROM upgrade_results ORDER BY version;
```

If the Princeton DB never ran `manifold:upgrade` for some older versions, `Perform` will run those older upgrades too (they are idempotent data fixes). `Manifold030000` no longer needs Elasticsearch: its ES index-removal step was deleted (see the diff of `manifold030000.rb`).

### System upgrades [V]

All in `api/app/services/system_upgrades/upgrades/`.

| Version | What it does | Cost |
|---|---|---|
| `000400` | Creates Twitter Query records from `tweet_fetch_config`. | Trivial. |
| `010000` | Destroys annotations with no creator. | **Destructive**, small. |
| `030000` | Reprocesses text cover styles (`Text.find_each`), scaffolds project content blocks. | Can touch files. |
| `040100` | Deletes collaborators with null makers, updates resource sort titles and project counters, caches formatted attributes. | Full table walks. |
| `050200` | Shrine v2→v3 attachment JSON rewrite for all Shrine models (`attacher.write/persist`). | Full table walk. |
| `060000` | Moves `ingestion.source` attachments; fills formatted-attribute caches for 12 models. | Full table walk. |
| `080200` | `TextSection.extrapolate_all_nodes!` | Already in v8.1.1, so should already be in `upgrade_results`. |
| **`090000`** (new, only one after `080200`) | `TextSection.where.not(text_id: nil).where.not(text_id: Text.select(:id)).destroy_all`. Deletes **orphaned text sections** (commit `dd29c62ae`). | **Destructive.** Pre-check count: `SELECT count(*) FROM text_sections WHERE text_id IS NOT NULL AND text_id NOT IN (SELECT id FROM texts);` |

After any upgrade applies, `rebuild_all` runs `PgSearch::Multisearch.rebuild` synchronously for Project, Text, TextSection, Resource, Journal and Annotation, then enqueues `TextSectionNodes::BackportSearchIndexJob` (§4).

### New migrations (47, 2024-10-01 … 2026-05-07) [V]

Long-running, destructive or notable ones (all in `api/db/migrate/`):

- `20241212183245_add_flag_resolution` (179 lines): 3× `DELETE FROM`, 3× `UPDATE`, `change_column`. Data rewrite of flags.
- `20250115214357` / `20250128220613` / `20250507234914`: `UPDATE`s of collaborator roles, project roles and contributor default role. Small data rewrites.
- `20250312204629_create_pg_search_documents`: adds `manifold_lang` enum, `lang2dictionary()` function and `pg_search_documents` table. Searchkick leftovers are not dropped.
- `20250410180020_enhance_multisearch`: functions, generated tsvector columns, GIN indices, **`UPDATE text_sections SET body_text = extract_text_section_content(body_json)` over every text section**, and caching of user full names. Long on a big library.
- `20250410201712_enhance_text_section_nodes` and `20250603192547_optimize_text_section_node_searching`: a large GIN index (`gin_trgm_ops` + tsvector) and `CREATE STATISTICS`. Builds an index over `text_section_nodes`; non-concurrent, so it takes a write lock.
- `20250513002532_add_fa_cache_to_text_sections`: Ruby loop `TextSection…find_each { refresh_formatted_attributes_cache! }`. Calls current model code from a migration.
- `20250527180248_add_search_indexed_to_text_section_nodes`: adds `search_indexed` (default false for **all existing rows**) and tries to enqueue `BackportSearchIndexJob` 10 min later. It only enqueues if the `good_jobs` table already exists. That table is created by the later migration `20250603170620_create_good_jobs`, so on a v8.1.1 DB it normally does **not** enqueue (comment in the migration: "If this is our first migration, good_jobs won't exist yet"). The backfill is picked up by `manifold:upgrade` instead.
- `20250603170620_create_good_jobs`: good_job tables in the primary DB.
- `20250609191642_add_position_to_reading_group_composite_entries`, `20251020225421_add_severity_to_ingestion_messages`, `20251203231940_add_journal_issue_to_multisearch_documents`: small data backfills.
- `20251017174417`, `20251017211501`, `20251103175949`, `20251103180007`, `20260507182648`: `CREATE INDEX CONCURRENTLY` (`disable_ddl_transaction!`).
  - `20251103180007` also enqueues `TextSections::MaintainAllCurrentNodesJob` after 1 minute, so a worker must be running.
- `20251105165521_set_contained_content_fillfactor`: **`REINDEX`** of the contained-content index (blocks writes).
- `20251117204731_create_user_groups`, `20251120233556_create_external_identifiers`: new tables (entitlements, SAML/OAuth relay).
- `20251203230443_correct_journal_foreign_keys`: **destructive.** Deletes `journal_volumes` / `journal_issues` whose journal is missing, nulls dangling `journal_volume_id`, orphans projects pointing at missing issues (`orphaned_journal_issue`), then adds `ON DELETE RESTRICT` foreign keys.
- Cache DB (separate path `api/db/cache_migrate/`): 4 solid_cache migrations from commit `2ec21c17f`.
- `20260209183815_create_statistics_records`: new table replacing Redis-held reader statistics.

### Background work after upgrading [V]

- `BackportSearchIndexJob` (queue `low_priority`) iterates every `TextSectionNode` where `search_indexed = false` (all pre-existing nodes) and calls `index_contained_content!`.
  - `api/app/jobs/text_section_nodes/backport_search_index_job.rb`. Job-iteration based, so resumable.
  - Duration depends on node count. [?] Not measured; time it on the staging copy.
- Search will be incomplete for old texts until these jobs finish.

### Gaps

- [?] Whether `db:migrate` completes cleanly from an 8.1.1 schema. It is not exercised by upstream CI (CI builds `db:setup` from `structure.sql`).
- [?] Duration of the above on production-size data.
- No upstream 9.0 release notes: `gh release view` finds no `v9.0` release, and `CHANGELOG.md` starts at 9.0.1. Evidence here is code and git history only.

---

## 2. Background jobs: Sidekiq + zhong → good_job

### What changed [V]

- Commit `9d9a09081` "[F] Replace sidekiq and zhong with good_job" and `34708f2b1` "[F] Convert cron scheduler from zhong to good_job" (2025-06-03). `config.active_job.queue_adapter` went from `:sidekiq` (`v8.1.1:api/config/application.rb:110`) to `:good_job` (`9.2.11:api/config/application.rb:111`).
- `api/Gemfile` at 9.2.11: `good_job ~> 3.99`, `job-iteration`; no sidekiq, zhong, redis or clockwork.
- Jobs are stored in the primary Postgres DB (`good_jobs` tables, migration `20250603170620`).
- Worker command (docker-compose `worker` service): `bin/good_job start --probe-port 7001`.
  - Healthcheck `GET :7001/status/started`.
  - `api/bin/good_job` is a binstub.
- `api/config/initializers/good_job.rb`:
  - `execution_mode = :external`: web pods only enqueue; **the worker process is required**.
  - `max_threads = 5`, `poll_interval = 30`, `shutdown_timeout = 25`, `preserve_job_records = true`, cleanup of finished jobs after 12 h.
  - Queues: `"+default,mailers,deletions,low_priority,ahoy,annotations:4;+ingestions,processing:1"`. That is one pool of 4 threads for the general queues and a dedicated single thread for `ingestions` and `processing` (commit `a3ad9c060`). v8.1.1's sidekiq.yml queues were `default, mailers, low_priority, searchkick, ahoy`.
  - `enable_cron = true`. Cron is run **inside the worker**; no separate clockwork/zhong process. Entries (same jobs and cadence as `v8.1.1:api/zhong.rb`):

| Key | Cron | Job |
|---|---|---|
| `caches.refresh_project_collections` | `*/15 * * * *` | `ProjectCollectionJobs::QueueCacheCollectionProjectsJob` |
| `caches.refresh_all_flag_status_data` | `*/10 * * * *` | `Flags::RefreshAllStatusDataJob` (new) |
| `entitlements.audit` | `*/15 * * * *` | `Entitlements::AuditJob` |
| `entitlements.check_expiration` | `0 * * * *` | `Entitlements::CheckExpirationJob` |
| `uploads.expire_shrine_cache` | `0 22 * * *` | `ExpireShrineCacheJob` |
| `uploads.expire_tus_uploads` | `0 23 * * *` | `ExpireTusUploadsJob` |
| `notifications.enqueue_user_daily_digests` | `0 6 * * *` | `Notifications::EnqueueDigestsJob` |
| `notifications.enqueue_user_weekly_digests` | `0 6 * * 0` | `Notifications::EnqueueDigestsJob` |
| `packaging.automate_text_exports` | `*/5 * * * *` | `Texts::AutomateExportsJob` |
| `packaging.prune_text_exports` | `0 1 * * *` | `TextExports::PruneJob` |
| `packaging.prune_project_exports` | `5 1 * * *` | `ProjectExports::PruneJob` |
| `packaging.prune_bag_it_temporary_directory` | `0 */4 * * *` | `Packaging::BagItSpec::PruneTemporaryDirectoryJob` |

  - Cron fires in the app time zone (UTC; `config.time_zone` is not set), whereas zhong ran the upload-expiry jobs at 22:00/23:00 `America/Los_Angeles`. Cosmetic.
  - Note the digest jobs: zhong passed `"daily"`/`"weekly"` args; the good_job entries pass none [V from the two files]. [?] Check whether `EnqueueDigestsJob` derives the frequency itself. This is an upstream concern.
- Dashboard: `/api/good_job`, mounted in `config/routes.rb`, for admins only (or dev).
- Multiple worker replicas are safe by design (good_job uses Postgres advisory locks and de-duplicates cron). [I]

### Jobs still queued in Redis at cutover [V + I]

- Nothing migrates them [V]: no shim or Sidekiq reader exists in 9.2.11 (`git grep -i sidekiq 9.2.11 -- api` finds one comment), and `purge_legacy_caches_job.rb` was deleted.
- Pending, scheduled and retry Sidekiq jobs are **lost** unless drained first.
- The old queue contents are low-value except in-flight ingestions, exports and mail. `searchkick` jobs are pointless post-upgrade.
- Recommended: stop user traffic or scale the API to 0, wait for the Sidekiq queues to empty (`default, mailers, low_priority, searchkick, ahoy` plus the retry and scheduled sets; check the `/api/sidekiq` UI or `Sidekiq::Stats`), then scale sidekiq to 0, then run the migration Job.
- Remove the redis subchart only after that.

---

## 3. Redis

### Not required in 9.2.11 [V]

- Commit `2ec21c17f` "[F] Remove Redis dependency" (2026-02-09).
- `git grep -w -i redis 9.2.11` across `api/config`, `api/Gemfile`, `api/Gemfile.lock`, `api/lib`, `api/app`, `docker-compose.yml`, `docker/`, `client/` and READMEs returns **no matches**. No `redis`, `sidekiq`, `redis-objects`, `redis-namespace` or `zhong` gem. `api/config/initializers/10_redis.rb` and `40_traffic_control.rb` were deleted. `ManifoldEnv::RedisConfig` is gone.
- Replacements:
  - **Cache store**: `config.cache_store = :solid_cache_store` (`api/config/application.rb:115`, `environments/production.rb:49`). Backed by a **second database**: `api/config/database.yml` defines a `cache` connection, `api/config/solid_cache.yml` has `database: cache`, max_age 1 week, max_size 256 MB, namespace from `RAILS_CACHE_NAMESPACE` (default `manifold`). Migrations live in `api/db/cache_migrate/`, schema in `api/db/cache_structure.sql`.
  - **Rate limiting** (`rack-attack`, `api/config/initializers/rack_attack.rb`): uses `Rails.cache` (so solid_cache/Postgres).
  - **Statistics** (readers this week / last week): `StatisticsRecord` table + advisory lock (migration `20260209183815`).
  - **OAuth app IDs/secrets**: plain in-memory attributes loaded from Settings (`ManifoldEnv::OauthProvider`, previously `Redis::Objects`).
  - **OAuth auth code handoff**: `Rails.cache` (`ManagesOauthCookie`).
  - **Job queue and cron**: Postgres (§2).
  - **Action Cable**: removed entirely (see §6).
- **Cache DB env** [V from `database.yml`]: `RAILS_CACHE_DB_HOST` (default localhost), `RAILS_CACHE_DB_PORT` (5432), `RAILS_CACHE_DB_USER`, `RAILS_CACHE_DB_PASS`, `RAILS_CACHE_DB_NAME` (default `manifold_cache_development`; there is no production default, set it). Unlike the primary DB, user and password have **no fallback to `RAILS_DB_*`**, so they must be set.
- [I] The cache DB can probably be the same Postgres database as the primary (set `RAILS_CACHE_DB_NAME` = `RAILS_DB_NAME`): the tables are distinct (`solid_cache_entries`) and versions in the shared `schema_migrations` do not collide. Not verified; the dev setup uses two DBs. Choosing a separate DB means `CREATE DATABASE` on the Bitnami instance (not done by the chart; `db:migrate` does not create DBs, `db:prepare`/`db:create` does).
- Lost data on cutover: Redis-held `statistics` values (self-heals, recomputed by a job [I]), cached fragments and cron locks. Acceptable.

---

## 4. Search

### Elasticsearch/searchkick → Postgres full-text [V]

- Commits `5e416c2cd` "[E] Remove elasticsearch and searchkick" (2025-05-21), `511aafbc5` "[F] Add PostGres multisearch integration", `8f4273da5` "[F] Tie up PG Search Feature with Text Section Nodes".
- 9.2.11 Gemfile: `pg_search`; no `searchkick` / `elasticsearch`.
- Config: `ManifoldSearchConfig` (`api/config/configs/manifold_search_config.rb`), `strategy: "pg"` default (`MANIFOLD_SEARCH_STRATEGY`).
- Index data lives in `pg_search_documents` (multisearch, with generated weighted tsvector columns, unaccent + trigram) and `text_section_nodes` (`contained_content`, `tsv_contained_content`).
- `ELASTICSEARCH_URL` is no longer read anywhere.

### Reindex/backfill required: yes [V]

1. **Automatic**: `rake manifold:upgrade` → `Manifold090000` applies → `Perform#rebuild_pg_search_documents` → `search.rebuild_all` (synchronous `PgSearch::Multisearch.rebuild` for the six multisearchable classes, `api/app/operations/search/rebuild_all.rb`) and enqueues `BackportSearchIndexJob`.
2. **Manual / re-run**: `bin/rails manifold:search:reindex` (`api/lib/tasks/search.rake`) does the same rebuild.
3. **Needs a running good_job worker** for the node backfill (`BackportSearchIndexJob`, `MaintainAllCurrentNodesJob`, `IndexNodesJob`); see §1.
4. If `manifold:upgrade` was previously run so `Manifold090000` shows as applied, a re-run does nothing. Use `manifold:search:reindex` or `rake manifold:upgrade[true]` (force) [V from `perform.rb`: `force` makes all upgrades pending, which re-runs the destructive ones too: prefer `manifold:search:reindex`].
5. Old ES data in the cluster is unused and can simply be discarded with the subchart.

---

## 5. File storage

### Local shared filesystem is still supported [V]

- `api/lib/storage/strategy.rb`: `Storage::Strategy.primary` reads `MANIFOLD_SETTINGS_STORAGE_PRIMARY` and **defaults to `"file"`**. Valid names (`api/lib/storage/types.rb`): `file`, `gcs`, `s3` (`aws` is accepted as an alias for `s3`).
- Mirror is optional: `MANIFOLD_SETTINGS_STORAGE_MIRROR` (nil by default).
- Local layout constants unchanged between v8.1.1 and 9.2.11 (`api/lib/storage/factory.rb`): path `public`, prefix `system` → `public/system`; cache prefix `system/cache`; tus path `data` (`MANIFOLD_SETTINGS_STORAGE_*_PATH` / `_PREFIX` overrides). These match the chart's three mounts (`public/system`, `public/system/cache`, `api/data`). **No file migration is needed to stay on `file`.**
- Production still serves files via nginx: `config.action_dispatch.x_sendfile_header = "X-Accel-Redirect"` (`environments/production.rb`). The existing nginx `/__send_file_accel` and `/system` locations stay valid.
- S3 is new and optional:
  - `MANIFOLD_SETTINGS_STORAGE_PRIMARY=s3`; `S3_ENDPOINT`, `S3_ACCESS_KEY_ID`, `S3_SECRET_ACCESS_KEY`, `S3_REGION`, `S3_FORCE_PATH_STYLE` (`S3Config`, anyway_config); `UPLOAD_BUCKET`, `UPLOAD_MIRROR_BUCKET`, `UPLOAD_PUBLIC`, `UPLOAD_USE_ASSET_CDN`, `UPLOAD_CDN_HOST`, `UPLOAD_MAPPED_HOST` (`UploadConfig`); `MANIFOLD_SETTINGS_STORAGE_*_BUCKET`/`_PREFIX` overrides. `api/bin/ensure-bucket` creates the bucket.
  - SeaweedFS is a dev-only default since 9.2.9 (commits `870f84320`, `0597204bd`; README "Note on migration to SeaweedFS"). The compose `api.env` sets `s3`.
- **Migrating from file to S3** would be a separate project:
  - Storage::Migrate (`api/app/services/storage/migrate.rb`) only mirrors via the `mirror` store (`attacher.file.trigger_mirror_upload`).
  - There is a CLI tool for deb-package installs, `api/lib/tasks/manifold_migrator.thor` (added `6b10d5e32`, removed `3411568f4`), which declares local `file` storage "not supported in a Dockerized hosting environment". That is upstream's opinion for single-container installs; with an RWX volume (as here) it works [V from code path].
- Caveat [I]: all pods that touch uploads (api, worker, nginx) must mount the same volume. The new `worker` writes derivatives and exports, so mount `volumeMounts` on it exactly as the sidekiq deployment does today.

---

## 6. Processes and env

### Processes upstream runs in production at 9.2.11

Upstream ships no production orchestration beyond `api/Dockerfile` and `client/Dockerfile` (their `docker-compose.yml` is dev-only; targets `development`). No `Procfile` at 9.2.11 [V].

| Process | Command | Source |
|---|---|---|
| API (web) | `bin/puma -C config/puma.rb` (`PUMA_APPLICATION=API`, port from `API_PORT`; image sets `RAILS_MIN/MAX_THREADS=16`, `WORKER_COUNT=0`) | `api/Dockerfile` `CMD`, compose `web` |
| Worker | `bin/good_job start --probe-port 7001` | compose `worker` |
| Client SSR | `./node_modules/.bin/npm-run-all _build:browser-config _serve:ssr` (port `CLIENT_SERVER_PORT`) | `client/Dockerfile` `CMD` |
| Migration (one-shot) | `bin/ensure-db` = `rails db:prepare` + `rails db:seed` | compose `migrations`, `api/bin/ensure-db` |
| Postgres | `postgres:13-alpine` (CI: `postgres:13.12-alpine`) | compose, `ci.yml` |

No nginx, cable, clockwork/zhong, sidekiq, elasticsearch or redis. `manifold:upgrade` is not run by any upstream script [V].

### Comparison with this repo's chart

| Chart deployment | Today | At 9.2.11 |
|---|---|---|
| `api-rails` | `bin/puma -C config/puma.rb`, port 3020 | Unchanged command. Add `SECRET_KEY_BASE`, cache DB env. [V] |
| `api-cable` (`bin/cable`) | Action Cable server, port 3021 | **Remove** (also its service, `API_CABLE_*`, nginx `/cable`). `action_cable/engine` is no longer required in `config/application.rb`; the client's websocket middleware and reducers were deleted; `api/bin/cable`, `api/cable/config.ru`, `config/cable.yml`, `app/channels` are all gone. [V] The Puma `CABLE` lookup was dropped. |
| `api-clockwork` (`bin/zhong zhong.rb`) | cron | **Remove**; cron runs inside good_job (§2). [V] |
| `api-sidekiq` (`bin/sidekiq`) | jobs | **Replace** with `bin/good_job start --probe-port 7001` (probes: HTTP 7001). Keep the shared-volume mounts. Resources: Sidekiq had 24Gi limit, but good_job is one process with 5 threads in one pool (`max_threads = 5`), so memory should be needed less [I]; keep a generous limit until measured. |
| `client` (`yarn run start`) | `_serve:ssr` only | Node 22; upstream's `CMD` regenerates `browser.config.js` from env at start. Today's local Dockerfile bakes `CLIENT_BROWSER_API_URL` etc. at build time, which still works if `build:prod` is unchanged. [V on commands; I on equivalence] |
| `nginx` | own image, upstreams api/cable/client | Keep. Remove the `/cable` location and `/api/sidekiq/*`. [V: nothing upstream serves them] |
| redis / elasticsearch / postgresql subcharts | in-cluster | Remove redis and elasticsearch; keep postgresql (≥13). |

New: a migration Job (§summary 7).

Also in the image (`api/Dockerfile`): `RAILS_LOG_TO_STDOUT=true`, `RAILS_SERVE_STATIC_FILES=true`, `LD_PRELOAD=libjemalloc.so.2`, `MAMMOTH_PATH=/usr/bin/mammoth`. `postgresql-client-13`.

### Env var changes (API side: names read in `api/{app,lib,config,db,bin,docker}`, v8.1.1 vs 9.2.11)

Compared against `configmap-env.yaml`:

- **Removed upstream:**
  - `RAILS_REDIS_URL`, `REDIS_URL`, `BOXEN_REDIS_URL`, `RAILS_REDIS_NAMESPACE`, `REDIS_NAMESPACE_QUIET`
  - `ELASTICSEARCH_URL`
  - `API_CABLE_HOST`, `API_CABLE_PORT` (Puma `CABLE` lookup dropped), `CLIENT_BROWSER_API_CABLE_URL`
  - `DISABLE_SPRING` / `BUNDLER_VERSION` (no longer read)
- **Added:**
  - `RAILS_CACHE_DB_HOST/PORT/USER/PASS/NAME` (+ `RAILS_CACHE_TEST_DB_NAME`), `RAILS_CACHE_NAMESPACE`
  - `LOCKBOX_MASTER_KEY` (optional, see below), `PROXY_CLIENT_IP_HEADER`, `CLIENT_SERVER_IP`
  - `RAILS_MAX_THREADS` (database.yml pool; falls back to 50)
  - `S3_*`, `UPLOAD_*`, `MANIFOLD_SETTINGS_STORAGE_*` (optional; file is default)
  - `SAML_*` provider config (optional; `SamlConfig`, `AbstractSamlProviderConfig`)
  - `MANIFOLD_SEARCH_STRATEGY` (default `pg`)
- **Renamed / changed meaning:**
  - **`SECRET_KEY_BASE`**: `api/config/secrets.yml` still maps `RAILS_SECRET_KEY` and the app still calls `Rails.application.secret_key_base`, but under Rails 7.2 `secrets.yml` is no longer honoured [I: Rails 7.2 removed `Rails.application.secrets`]. Upstream's own `docker/api/api.env` sets **both** `RAILS_SECRET_KEY` and `SECRET_KEY_BASE`. **Set `SECRET_KEY_BASE` to the same value as the current key**; this is needed for JWT, signed cookies and Lockbox. Verify by booting with only the old variable. [?]
  - `LOCKBOX_MASTER_KEY`: if unset, Lockbox falls back to `secret_key_base` (`api/config/initializers/25_lockbox.rb`). v8.1.1 also derived the key from `secrets.secret_key_base`, so the derivation is the same as long as `secret_key_base` is the same. **Do not change the secret.** Encrypted columns would become unreadable.
  - `CLIENT_SERVER_IP` / `PROXY_CLIENT_IP_HEADER`: behind Cloudflare + ingress, set `PROXY_CLIENT_IP_HEADER` (e.g. the Cloudflare client-IP header) so per-IP rate limits key on the real IP, and `CLIENT_SERVER_IP` to safelist the SSR server. Otherwise Rack::Attack derives public IPs by resolving `DOMAIN` (`ManifoldEnv.rate_limiting.derive_public_ips!`).
- **Client side** (`process.env.*` in `client/src`, script, webpack): unchanged names `DOMAIN`, `SSL_ENABLED`, `CLIENT_SERVER_PORT`, `CLIENT_SERVER_PROXIES`, `CLIENT_BROWSER_API_URL`, `CLIENT_SERVER_API_URL`, `CLIENT_URL`, `NODE_ENV`; **new**: `ENFORCE_CANONICAL_DOMAIN` (302s when host ≠ `DOMAIN`; useful with the `princeton-manifold-origin` host, so decide deliberately), `PROXY_DEBUG`, `WEBPACK_DEV_HOST`, `WEBPACK_WATCH_POLL`; removed: `DISABLE_HMR`. `CLIENT_BROWSER_API_CABLE_URL` is still templated in `client/webpack/templates/www_env.ejs` but nothing uses it [V: only locale text mentions "cable"].
  - The `ALLOW_SIGNUP` hook added locally in `www_env.ejs` still works as a mechanism, but the `LoginForm` was rewritten (§7).
- Client proxies (`CLIENT_SERVER_PROXIES=true`) at 9.2.11 only proxy `/system` and `/api/proxy` to the API, plus static assets (`ProxyHelper.js`). Not `/api` itself, so an nginx/ingress in front is still required, as today. [V]

---

## 7. CAS

### Gem compatibility

- [V] The `harvard-lts/omniauth-cas` fork at `harvard-main` (`a61f71e9`, 2024-01-03; locally resolved `omniauth-cas 2.0.1`) is **9 commits ahead / 58 behind** `dlindahl/omniauth-cas`. Changes: a SAML ticket validator (only used when `service_validate_url` contains `samlValidate`) and some `cas.rb` / gemspec edits. Its gemspec: `omniauth >= 1.9, < 3`, `nokogiri >= 1.15.5`, **`addressable ~> 2.8.5`**; no `required_ruby_version`.
- [V] **omniauth 2.1.4** (9.2.11 lock) is within `< 3`, and the strategy is plain `OmniAuth::Strategy` with `net/http`, nokogiri and addressable; I see no use of anything removed in Ruby 3.x/3.4 (`URI.escape`, etc.). [I] Likely runs on Ruby 3.4, but the fork has not been tested on it: its CI predates 3.4 and only produces frozen-string/`net/http` warnings at worst. Run its spec suite on Ruby 3.4 or integration-test.
- [V] **Bundler conflict:** 9.2.11's `Gemfile.lock` has `addressable (2.9.0)`, bumped in `cea4e1c8c` "update gems to resolve Dependabot alerts" (2026-06-10). The fork requires `~> 2.8.5` (< 2.9.0), so Bundler will have to **downgrade addressable** to 2.8.x, reintroducing the alerted version, or fail. Fix options:
  1. Fork/pin the fork with `addressable ~> 2.8`. One-line gemspec change.
  2. Move to upstream `dlindahl/omniauth-cas` **v3.0.2** (tags v3.0.0–3.0.2): `omniauth ~> 2.1`, `addressable ~> 2.8`, `nokogiri ~> 1.12`, `required_ruby_version >= 3.0`, CI tests Ruby 4.0. [V] It lacks the fork's SAML validator, which is unused here (the local config does not set `service_validate_url`). [?] The CAS attributes the local patch reads (`pustatus`, `mail`, `displayname`, `pudisplayname`) come from the Jasig-style `<cas:attributes>` block and are parsed by `ServiceTicketValidator`, which upstream has too; confirm with a real login or a recorded CAS response.
- Rails 7.2/Ruby 3.4 compatibility of the **local patch**: it only uses `OmniAuth::Builder#provider :cas, host:, url:` (no Rails API).

### Upstream OAuth code changed in ways that break the local patch [V]

`git diff v8.1.1..9.2.11` on `api/lib/middleware/omniauth_stack.rb`, `api/app/controllers/oauth_controller.rb`, `api/config/initializers/omniauth.rb`, `api/lib/manifold_env/*oauth*`, `client/src/**/oauth/*`.

1. **Login flow redesign** (popup + `postMessage` → full-page redirect + cookie + `/oauth` route). Upstream's `OauthController`:
   - `GET /auth/:provider/redirect` renders an auto-submitting **POST form** to `/auth/:provider` with an `authenticity_token` (CSRF-protected, via `omniauth-rails_csrf_protection`; the 9.2.11 `config/routes.rb` has `get "auth/:provider/redirect"`).
   - `authorize` now: runs `ExternalAuth::FindUser`, then `Identities::HandleExternalAuth`, sets a 1-minute `_oauth_auth_code` cookie (domain `.#{DOMAIN}`), stores user id in `Rails.cache` (`ManagesOauthCookie`), and **redirects** to `{manifold.url}/oauth`. The React `containers/OAuth` page exchanges that code for a token via `tokensAPI.createToken({ authCode })`. `window.opener.postMessage` is gone.
2. **The CAS callback route is missing upstream.**
   - 9.2.11 routes: `post "auth/:provider/callback"` only; `get "auth/:provider/callback"` is added **only `if Rails.env.test?`**. v8.1.1 had the GET route.
   - CAS redirects the browser back with `GET /auth/cas/callback?ticket=…` and OmniAuth then passes the request on to Rails. Without a GET route, CAS login would 404 in production.
   - The patch must add `get "auth/:provider/callback", to: "oauth#authorize"` (and the cookie domain handling should be tested).
3. **`omniauth_hash` override.** The local override of `OauthController#omniauth_hash` (maps `extra.pustatus` / `mail` / `uid` / `displayname` into `info.email` and `info.name`) still applies as a concept: 9.2.11 keeps `def omniauth_hash; request.env["omniauth.auth"]; end`, and `ExternalAuth::*` signatures changed only in style plus `Identities::HandleExternalAuth` (`outcome.identity`). The local override needs to be re-applied to the new file and rechecked against `ExternalAuth::Provisioners::User#extract_custom_details!` (now `user.name = auth_hash.info["name"]`, `user.nickname = auth_hash.info["nickname"] || auth_hash.info.first_name`).
4. **`omniauth_stack.rb`:** upstream added `SamlConfig.providers.each { provider(*saml.provider_args) }` before the OAuth providers. The local `if provider_args[0] == :cas … provider :cas, host: custom.host, url: custom.site + "/cas"` replacement still fits in the `ManifoldEnv.oauth.enabled.each` loop but must be re-merged. `OmniAuth.config.allowed_request_methods = [:get, :post]` in `config/initializers/omniauth.rb` is no longer needed: upstream's redirect action POSTs. It is harmless but would re-open GET request-phase (CSRF); [I] best dropped.
5. **`config/oauth.yml`:** `ManifoldEnv::OauthConfig` still loads it with `Rails.application.config_for(:oauth, env: "oauth")` and `CustomOauthProvider` still accepts `name, client_id, client_secret, host, protocol, endpoints, descriptive_name, *_key` (only `new(**options)` keyword splat changed). **The local `oauth.yml` should load as is.**
6. **Client:**
   - `Settings#identity_providers` (`api/app/models/settings.rb`) now returns every enabled OAuth provider (including custom ones such as `cas`) with `url: "/auth/<strategy>/redirect"`, and `LoginForm` / `OAuthProviderButton` render from that list (`href={provider.url}`). So the **hardcoded `<OAuthProviderButton provider="cas" icon="key32" />` and the `button-secondary--dark` removal no longer apply** and should not be re-applied: `OAuthProviderButton`'s props changed to a provider object. The CAS button should appear from `settings.attributes.authentication.identityProviders` automatically [I; test].
   - `OAuthLoginOptions` at 9.2.11 only hard-codes Google; the Facebook and Twitter buttons were removed (the omniauth gems remain).
   - **`ALLOW_SIGNUP`**: the `signupEnabled` guard in `LoginForm` must be re-applied around the "need an account" link (`LoginForm/index.js:156` at 9.2.11, in a rewritten file), and the Login test and snapshot are gone/changed (upstream deleted `__tests__/Login-test.js` and its snapshot).
7. **Option:** 9.2.11 supports **SAML** natively (`SamlConfig`, `omniauth-saml 2.2.4`, `SAML_PROVIDER_NAMES`, `SAML_<NAME>_*`; compose has a Keycloak profile). [?] Whether Princeton can federate via SAML instead of CAS is unknown. That would drop the fork entirely.

### Other local patches that disappear

- `api/app/services/search/options.rb`, `search/query_builder.rb` (ES), `searchkick`/`sentry-sidekiq` in the Gemfile: obsolete. Keep `sentry-rails`/`sentry-ruby`; `sentry-sidekiq` has nothing to hook into [I]. `config/initializers/sentry.rb` to be re-checked against `Rollbar` usage in `good_job.rb` (`on_thread_error` calls `Rollbar.error`, check that Rollbar is still in the Gemfile) [?].
- `api/db/structure.sql` one-line local change [?] (check what it was before rebasing; the file changes massively upstream).
- `.github/workflows/*` and root `Dockerfile`, `nginx/`, `chart/`, `ops/`, `docker-compose.yml`: repo-local, no upstream conflict except `.github/workflows`.
- Note the fork's repo layout differs from upstream's: this repo keeps `Gemfile`, `Brewfile`, `Procfile`, `config/`, `bin/`, `script/`, `.env.sample` at root (from v8.1.1). Those root files are **deleted** upstream by 9.2.11 (root contains only `api`, `client`, `docker`, `docker-compose.yml`, `.github`, …). Plan for rebase conflicts there.

### 7b. CAS deep dive: callback method, service URL, rollout risks

**Callback method.** [V from omniauth 2.1.4 `strategy.rb`] `call!` handles the callback phase for *any* HTTP method (`return callback_call if on_callback_path?`); `callback_phase` sets `omniauth.auth` and calls `call_app!`, which hands the **original request, with its original method**, to Rails. So the Rails route must match the method CAS uses to come back.

- CAS returns the user with a browser redirect: `GET /auth/cas/callback?url=…&ticket=ST-…`. Upstream's production routes only have `post "auth/:provider/callback"` (made for SAML POST bindings), so as shipped, CAS login 404s.
- **Option A (recommended): add a GET route for `cas` only**, restoring v8.1.1 behaviour, e.g. `get "auth/cas/callback", to: "oauth#authorize"`. No CAS-side change. A GET callback is inherent to CAS; the single-use ticket is validated server-side by the strategy (`serviceValidate`), and the strategy's CSRF check (`omniauth-rails_csrf_protection`) only applies to the request phase, not the callback.
- **Option B: have CAS POST the ticket.** [I] CAS protocol 3.0 / Apereo CAS honour a `method=POST` parameter on `/login` and POST the ticket to the service. It can be set without patching the gem: the fork's `login_url` option is `append_params`-merged, so `login_url: "/login?method=POST"` is preserved. [?] Princeton's CAS server (`fed.princeton.edu`) may not honour it; if ignored it silently falls back to GET and fails. Cost of B if supported: the callback is then cross-site POST, so the `_manifold_api_session` cookie is not sent (Rails 7.2 default `SameSite=Lax`). That is harmless for CAS (the strategy keeps no state in the session beyond `omniauth.origin`), and upstream's `post` route already exists, so no route change would be needed. B buys nothing over A unless there is a reason to avoid a GET callback. A can be done today; B needs a CAS-side test.
- Whichever is chosen, `OmniAuth.config.allowed_request_methods = [:get, :post]` should go: it re-enables GET on the **request** phase, which upstream deliberately closed (CSRF).

**Service URL (what the CAS service registry must accept).** [V from the fork's `cas.rb`] `service = callback_url + "?url=" + request.referer`; `callback_url = full_host + callback_path + query_string`.

- `full_host` = `Rails.configuration.manifold.api_url` (from `CLIENT_BROWSER_API_URL`), so host and path (`https://openpublishing.princeton.edu/auth/cas/callback`) are unchanged.
- **The `url=` value changes.** Before, the referer was the client page that opened the login popup. Now the POST to `/auth/cas` comes from the API's auto-submit page `/auth/cas/redirect`, so `url=` is that page [I: unless a Referrer-Policy strips it, then `url=` is absent]. [?] If Princeton's CAS service registration matches the service URL by exact string or a narrow regex including the query string, this could stop matching. Ask whoever administers the Princeton CAS registration whether it is a prefix/regex on `…/auth/cas/callback`.
- On the callback, the fork removes `ticket` from the service URL before validating (`service_validate_url`), so the validated service equals the one sent at login. Unchanged behaviour.
- The value of `url=` is no longer consumed by anything: upstream redirects to `{manifold.url}/oauth` after login (`post_authorize_redirect_uri`), not to `omniauth.origin`.

**After the callback** (all new code path, tested only for Google/SAML in upstream specs: `api/spec/requests/oauth_spec.rb`):

1. `ExternalAuth::FindUser` → `Identity.from_omniauth(auth_hash)` (provider `cas` + uid). `Identity` changed only by adding `ProvidesEntitlements`, `user_group_memberships`, and `validates :provider` now accepts `known_strategies + SamlConfig.provider_names`. `cas` is still a known strategy through `oauth.yml`. [V] Existing Princeton identities should match as long as the strategy name and uid field (`user`, the NetID) are unchanged.
2. The local `omniauth_hash` override (guest → `extra.uid` as email, otherwise `extra.mail`; name from `displayname`/`pudisplayname`) is evaluated twice now (FindUser and `Identities::HandleExternalAuth`). It uses `merge!`, so it is idempotent. [V by reading]
3. `Identities::HandleExternalAuth` (new) runs `SyncManagedUserGroups` and `SyncManagedEntitlements`, reading `auth_hash.info.user_groups` and `info.entitlements` with `&.`, so CAS logins with neither attribute are fine (no groups/entitlements, no error). [V] This is also a ready-made hook: a CAS attribute (for example an affiliation or group attribute) mapped into `info.user_groups` / `info.entitlements` would grant managed group membership or project access, if Princeton wants that. [I]
4. `set_auth_code` writes the user id to `Rails.cache` (solid_cache = Postgres, so the cache DB must be reachable and migrated) and sets the `_oauth_auth_code` cookie on `.{DOMAIN}`; the client reads it from JS and calls `tokensAPI.createToken`. A missing cache DB or a cookie-domain mismatch (`DOMAIN` ≠ the host users see, e.g. the Cloudflare custom hostname versus `princeton-manifold-origin`) shows as "An error has occurred logging you in". [V code; I failure mode]
5. Redirect lands on `/oauth?error=…` on failure.

**Provider enablement.** `ManifoldEnv.oauth.enabled` only lists providers with credentials, which is why the local `oauth.yml` carries placeholder `client_id`/`client_secret` ("unused placeholders"). Still true at 9.2.11 (`OauthProvider#has_credentials?`). They must stay non-blank.

**Test plan, since CAS is a black box.**
- Record a real `serviceValidate` success response (NetID user, a guest, and a non-guest with `pustatus`) and replay it with WebMock against the strategy (the fork already ships fixtures such as `spec/fixtures/cas_success_jasig.xml`).
- Add request specs modelled on `api/spec/requests/oauth_spec.rb`: OmniAuth `test_mode` with a mock `cas` hash, covering new user, existing user, guest, and the redirect target. Note `test_mode` bypasses the real GET/POST callback route, so one non-mocked end-to-end test against a staging CAS (or a local Apereo CAS container) is the only thing that proves the route and service URL.
- On staging: confirm the CAS service registry entry for the staging host, then the login round trip, then the cookie handoff.
- Fallback if the fork cannot be made to work: upstream `dlindahl/omniauth-cas` v3.0.2 (same strategy, supported on Ruby ≥ 3.0 / omniauth 2.1).

---

## 8. Postgres

- **Minimum 13** [V + I]:
  - Upstream tests and develops against Postgres 13 (`docker-compose.yml`: `postgres:13-alpine`; `ci.yml`: `postgres:13.12-alpine`; `api/Dockerfile`: `postgresql-client-13`).
  - `structure.sql` at 9.2.11 uses `gist_ltree_ops (siglen='24')` on `text_section_nodes` (the ltree `siglen` option arrived in PG 13), and `GENERATED ALWAYS … STORED` columns (12+), `hashtextextended` (11+), `INCLUDE` indexes (11+), `jsonb_path_query` (12+). So **PG 12 or lower will fail**.
  - The chart's Bitnami `14.5.0` (and subchart 11.9.13) satisfies this. [?] 14+ is not tested upstream, but nothing in the code suggests incompatibility. Do not jump major versions in the same change.
- **Extensions** [V] (`api/db/structure.sql` at 9.2.11; identical to the set in v8.1.1): `btree_gin`, `btree_gist`, `citext`, `intarray`, `ltree`, `pg_trgm`, `pgcrypto`, `unaccent`, `uuid-ossp`. All are contrib modules and trusted on PG 13+, so the DB owner can create them; the Bitnami image includes contrib. They are created by earlier migrations (already present in an 8.1.1 DB), so **no new extension is needed**.
- `pg_stat_statements` is only in the dev compose preload; not required.
- Two databases are needed (primary + cache) unless the cache is pointed at the primary (§3).
- Data-version note: DB major upgrades are separate from this change.

---

## Suggested cutover order (for the follow-up plan)

1. Back up: `pg_dump` of the production DB and a snapshot of the shared volume (EFS backup); record `SELECT version FROM upgrade_results`.
2. Restore the production dump into staging. Run the 9.2.11 image there: `db:migrate`, `manifold:upgrade`, then watch the good_job backlog and time everything. Test the CAS login and a file upload/derivative.
3. Production: scale clockwork down; quiesce traffic; wait for Sidekiq queues to drain; scale down sidekiq/cable/api.
4. `helm upgrade` with the new chart: pre-upgrade Job runs migrate then upgrade; start api, good_job worker, client, nginx.
5. Watch `/api/good_job` until the backfill queues finish; spot-check search.
6. Remove leftover redis/ES PVCs and old image tags later.

## Sources (refs)

`v8.1.1` = `8430515aa`; `9.2.11` tag. Key commits: `9d9a09081` and `34708f2b1` (good_job), `2ec21c17f` (Redis removal), `5e416c2cd` (searchkick removal), `511aafbc5` and `8f4273da5` (pg_search), `d444d9701` (S3), `0597204bd` (SeaweedFS dev default), `43f853b01` (Rails 7), `d03d4b529` (Ruby 3.4), `f89f972c5` (Node 22), `dd29c62ae` and `d5795437b` (`090000`), `cea4e1c8c` (addressable bump), `725522ed7` (Ruby 3.4.13).
