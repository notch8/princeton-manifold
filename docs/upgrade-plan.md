# Princeton Manifold: incremental upgrade plan

## Context

The app runs upstream Manifold **v8.1.1** (March 2024) on EOL runtimes: Ruby 2.7.8, Rails 6.1.7.3, Node 18 with webpack 4, Sidekiq 5, Debian bullseye (already off the live apt mirrors), and frozen `bitnamilegacy` Postgres 14.5 / Redis 7.2 / Elasticsearch 8.12 images.

What the investigation found:

- **The fork is thin.** 188 local commits, ~95% ops. App changes are ~80 lines in 9 files: CAS login, `ALLOW_SIGNUP` flag, Sentry, a search patch. No local migrations. Never synced with upstream.
- **Upstream has done the upgrades.** 9.2.11 (19 Nov 2026) is Ruby 3.4.13, Rails 7.2.3.2, Node 22, webpack 5, Yarn 4. It replaced Sidekiq with good_job and removed Elasticsearch (pg_search). 10.0.0 is at rc.1 (react-router 5→7, LTI/OIDC).
- **Decision: rebase onto upstream 9.2.11** and re-apply the local patches, rather than upgrading 8.1.1 in place.
- **CI is red for an environmental reason.** `ubuntu-latest` became ubuntu-26.04; `bundle install` fails compiling old native gems (`unicode`, `debase`, an ICU-based gem) with the newer GCC/ICU. No lint or spec actually ran. Last green: 29 May 2026 on main.
- **The deploy pipeline has no safety net.** No `db:migrate` / `manifold:upgrade` on deploy, no probes (so `--atomic` can't catch a broken app), backups that cover the database only loosely and the uploads not at all (Velero, see Phase 1), secrets in a ConfigMap, subcharts unlocked from a deprecated registry, and staging runs a client image built with production URLs.

## Status (23 Nov 2026)

- **Done:** CI green on PR #80 (runners pinned to `ubuntu-24.04`; no real lint/spec failures behind the red build). Deploy credentials for both environments replaced with the `github-deploy` service-account kubeconfig (notch8-ops#833; Manifold's two secrets only). PR #80 deployed to friends (Helm rev 24, `7d9332a3`, nginx 1.31.9).
- **Done:** Phase 2 discovery, in `docs/upstream-9.2.11-upgrade-notes.md` (uncommitted). Findings are folded into Phases 3 and 4 below.
- **Done on production (Phase 0b, partly):** ingress values reconciled with live state; on-demand Velero backup `manifold-prod-pre-deploy-20261123` (kept to 23 Dec) plus a local YAML export; baseline Helm revision 39 (current values, March images) so an `--atomic` rollback has a safe target; origin certificate renewed to 21 Feb 2027 after adding `http01-edit-in-place` to the ingress and `http01-override-ingress-name` to the existing Certificate (notch8-ops#841, draft, declares the latter).
- **Done on friends:** notch8/princeton-manifold#59 fixed (client regenerates `browser.config.js` at start).
- **Next:** the real production deploy of `deploy_updates` (Phase 0b step 4) and merging PR #80; Phase 1 repo work is in progress on branch `phase1-safety-net`.

Rule for every phase: merge to main → deploy to **friends (r2-friends)** → verify → deploy the *same SHA* to **production (r2-besties)**. One concern per phase, so a regression has one suspect.

## Phase 0 — Green CI (before anything else)

- `.github/workflows/continuous_integration.yml`: pin `runs-on` for `api-lint` and `api-tests` to `ubuntu-24.04` (GCC 13, ICU 74). If native gems still fail there, fall back to `ubuntu-22.04`, or run both jobs inside the built `manifold-api` image (same toolchain we ship).
- Pin `runs-on` in `build_docker_images.yml` too, so the runner image stops changing under us.
- Once bundle installs, fix whatever real rubocop/rspec failures surface (unknown until it runs).
- Rebase PR #80 (`deploy_updates`) on the fix, get it green, merge, deploy friends → production. This ships nginx 1.31.9.

## Phase 0b — Production catch-up (before any other production change)

Production has drifted from the repo, so the first Helm deploy there is not a small one.

| Finding (r2-besties, 23 Nov) | Consequence |
|---|---|
| Running images `b6a4a12a` (24 Mar); Helm rev 38 is from 25 Mar. `main` is 12 commits ahead. | The next deploy ships everything since March plus PR #80. |
| Ingress carries `kubectl replace`/`kubectl annotate` edits; Sidekiq has a 16Gi limit Helm never deployed. Body-size and 600s timeout annotations from `main` are **not** live. | Helm will overwrite hand edits with `ops/production-deploy.tmpl.yaml`. |
| Certificate `production-princeton-manifold-tls-4` expired 22 Jul; both HTTP-01 challenges pending since 22 Jun (`wrong status code '404'`). Public hosts serve a valid cert to Jan 2027, presumably Cloudflare's edge cert (unconfirmed). | Origin TLS is only working because Cloudflare isn't validating it. A deploy that recreates the ingress could surface this. |

Steps:

1. Render the production release locally (`helm template` with the envsubst'd values, or `helm diff upgrade`) and compare with live `kubectl get -o yaml` for the ingress and each deployment. Put any hand edit worth keeping into `ops/production-deploy.tmpl.yaml`.
2. Fix certificate issuance before deploying: find why the HTTP-01 solver returns 404 (likely the Cloudflare proxy or the ingress class the solver uses) or move production to the DNS-01 issuer as friends did (PR #76). Confirm Cloudflare's SSL mode.
3. Take the long-TTL on-demand Velero backup (Phase 1.1 command; it works today).
4. Merge PR #80, deploy `main` to friends, then production, in a low-traffic window. Smoke test.

## Phase 1 — Safety net (on the current 8.1.1 app)

Each item is a small PR, shipped friends → production.

1. **Backups: build on Velero, close its three gaps.**

   What exists (checked 23 Nov 2026; config in `notch8-ops/argocd/clusters/{r2-besties,r2-friends}/resources/velero/values.yaml`): Velero 1.18 with kopia fs-backup, schedule `daily-full-cluster` at 01:00 UTC, opt-out, so both Manifold namespaces are included. Last production run `velero-daily-full-cluster-20261123010055` Completed, with the Postgres, Redis and Elasticsearch volumes backed up to `s3://r2-besties-velero-backups`.

   | Gap | Why it matters | Fix |
   |---|---|---|
   | **Uploads are not backed up.** The resource policy skips every `efs.csi.aws.com` volume, which includes `princeton-manifold-production-shared-pvc`. No EFS backup is defined in notch8-ops terraform. | Uploaded texts, resources and ingestion sources have no copy. | Enable AWS Backup on the EFS filesystem (terraform in notch8-ops, daily, ≥14 days). Confirm first that it isn't already on in the AWS console. Skipping stays correct for Velero. |
   | **Postgres is copied live, file-level, with no hook.** | Crash-consistent at best; a restore may need WAL recovery or fail. | Add a Velero pre-backup hook annotation on the postgres pod (subchart `primary.podAnnotations` in `ops/*-deploy.tmpl.yaml`) that runs `pg_dump -Fc` into a path on the data volume, so every Velero backup carries a consistent dump. |
   | **48h retention.** | Shorter than an upgrade soak; the pre-upgrade state expires before we'd decide to roll back. | Before each production upgrade step run an on-demand backup with a long TTL: `velero backup create manifold-pre-<step> --include-namespaces princeton-manifold-production --default-volumes-to-fs-backup --ttl 720h`. Add this to the deploy runbook. |

   Also: add `helm.sh/resource-policy: keep` to `shared-pvc.yaml`. Out of scope but worth reporting to whoever owns notch8-ops: friends' `daily-full-cluster` is PartiallyFailed daily (8 errors, "failed to get shared config profile, default" from `volumeSnapshotLocation.config.profile`); the Manifold volumes on friends still complete via fs-backup.

2. **Prod → staging refresh runbook (doubles as the restore test).** Velero can't restore across clusters here (separate buckets per cluster), so: restore the on-demand production backup into a scratch namespace on r2-besties to prove the Velero restore works, then move data to friends with `pg_dump | pg_restore` into `princeton_manifold_friends` and an `rsync`/DataSync of the uploads volume. Gives every later phase real data.
3. **Migrations on deploy.** Helm `pre-upgrade` hook Job running `bin/rails db:migrate` then `manifold:upgrade` (`api/lib/tasks/upgrade.rake`), using the api image. Today both are manual `kubectl exec`.
4. **Probes.** Wire the existing `livenessProbe`/`readinessProbe` values (`values.yaml:113-120`) into the rails, client and nginx deployment templates so `--atomic` in `bin/helm_deploy` means something.
5. **Staging correctness.**
   - Fix `ingress.ingressClassName` → `ingress.className` in `ops/friends-deploy.tmpl.yaml`.
   - **Fix notch8/princeton-manifold#59 (staging logs in against production). Blocks all CAS and login testing on friends.** Confirmed on the current build: friends serves `/browser.config.js` with `openpublishing.princeton.edu` URLs and an empty `ALLOW_SIGNUP`, because the file is generated once at image build (`Dockerfile:49-54`, `client/script/build-browser-config.js`). The client pod's runtime env is already correct, and nginx proxies the file from the client pod, so the fix is to regenerate it at container start: change the command in `chart/princeton-manifold/templates/deployment-client.yaml` from `yarn run start` to run `_build:browser-config` then `_serve:ssr` (what upstream's image does), and drop the baked production `ENV` lines from the Dockerfile.
   - Memory caveat: running `_build:browser-config` in the friends client pod (256Mi limit) was OOM-killed. Raise the friends client memory limit, or generate the file in an initContainer with its own limit into a shared `emptyDir`. Verify with `curl https://princeton-manifold-friends.notch8.cloud/browser.config.js`.
6. **Reproducible charts.** Commit a `Chart.lock` (or vendor the three subcharts) so a rollback re-render doesn't depend on the deprecated Bitnami OCI registry.
7. **Smoke checklist** in the repo (see Verification), run after every deploy.

Deferred, tracked separately: moving secrets from the ConfigMap to k8s Secrets (changes helm history exposure, not blocking upgrades).

## Phase 2 — Upstream discovery (done; see `docs/upstream-9.2.11-upgrade-notes.md`)

Answers: direct hop 8.1.1 → 9.2.11 (47 migrations + one system upgrade, `Manifold090000`; untested on real data). Redis, Action Cable and clockwork are gone. Search is Postgres full-text and is rebuilt by `manifold:upgrade`. Local shared-filesystem storage still works. Postgres 13 is the minimum. The CAS patch needs rework (Phase 3.2). Original questions, for reference:

- `git remote add upstream https://github.com/ManifoldScholar/manifold.git`, fetch tags.
- Read what v8.1.1 → 9.2.11 requires: the `SystemUpgrades` files after `manifold080200.rb`, the v9.0.0 notes, and the good_job, pg_search and storage changes. Answer:
  - Can 8.1.1 data upgrade straight to 9.2.11, or is a stop at 9.0.x required?
  - Is Redis still needed (cable, cache)? Is the clockwork/zhong process gone?
  - Does upstream now expect S3-style storage (SeaweedFS in dev), or does the shared-filesystem PVC still work?
  - Does `harvard-lts/omniauth-cas` work with omniauth 2.1 / Ruby 3.4?
- Output: the hop list for Phase 3 and the chart change list.

## Phase 3 — Rebase onto upstream 9.2.11

Branch from the upstream tag and re-apply local work as separate commits (do not merge 188 commits forward):

1. **Ops layer** — `chart/`, `ops/`, `bin/helm_deploy`, `bin/start-and-run`, workflows, `nginx/`. Replace the root `Dockerfile` stages with upstream's `api/Dockerfile` (`ruby:3.4-slim-bookworm`) and `client/Dockerfile` (`node:22-slim`), keeping our nginx stage; update `docker-compose.yml` build targets since CI builds through it. This removes the archive.debian.org and `--openssl-legacy-provider` workarounds.
2. **CAS** (the riskiest local patch; upstream reworked OAuth) — `api/lib/middleware/omniauth_stack.rb`, `api/app/controllers/oauth_controller.rb`, `api/config/oauth.yml`, the `cas` button in `client/src/global/components/oauth/`.
   - Replace the `harvard-lts/omniauth-cas` fork with upstream `omniauth-cas` 3.0.2 (omniauth 2.1, Ruby ≥ 3.0).
   - Upstream's production routes only accept `POST auth/:provider/callback`; CAS returns by browser redirect, so as shipped CAS login would 404. Add `get "auth/cas/callback", to: "oauth#authorize"` for CAS only.
   - Drop the local `OmniAuth.config.allowed_request_methods = [:get, :post]`; upstream closed GET on the request phase deliberately.
   - The CAS `service` URL changes shape (the login now starts from the API's `/auth/cas/redirect` page). Check with Princeton that the CAS service registration accepts it, for both staging and production hosts.
   - Add request specs modelled on `api/spec/requests/oauth_spec.rb`, plus one real end-to-end login on friends (needs #59 fixed).
   - Worth asking Princeton: 9.2.11 supports SAML natively, which would remove this patch entirely.
3. **Sign-up flag** — `LoginForm/index.js`, `www_env.ejs`; regenerate the snapshot.
4. **Sentry** — initializer and gems; swap `sentry-sidekiq` for good_job error reporting.
5. **Drop** the search patch (`search/query_builder.rb`, `options.rb`) and the `structure.sql` edit; both are moot upstream.
6. **Chart changes**
   - Replace `api-sidekiq` with a good_job worker: `bin/good_job start --probe-port 7001`, probes `/status/started` and `/status/connected`. Carry over the memory limits and re-measure.
   - Remove the `api-cable` and `api-clockwork` deployments and the cable service; recurring jobs move into good_job's cron config.
   - Remove the Elasticsearch **and Redis** subcharts and their env (`ELASTICSEARCH_URL`, `REDIS_URL`, `RAILS_REDIS_URL`, `API_CABLE_*`, `CLIENT_BROWSER_API_CABLE_URL`).
   - Add env: `SECRET_KEY_BASE` (same value as `RAILS_SECRET_KEY`, inferred) and the cache database vars `RAILS_CACHE_DB_{HOST,PORT,USER,PASS,NAME}`. Create the cache database before the first migrate.
   - nginx: drop the `/cable` and `/api/sidekiq/*` locations; keep `/system` and the X-Accel mapping.
   - New apt packages in the api image (libvips, mediainfo, pandoc, poppler, librsvg, jemalloc and others; list in the notes).
   - Bump `appVersion`.
7. **CI** — adopt upstream's CI workflow and setup actions (Ruby 3.4, Node 22, Yarn 4).

Rollout:

- Refresh friends from production (Phase 1.2), deploy, let the hook run migrations and `manifold:upgrade`, run the smoke checklist plus a full CAS login, an ingestion (EPUB, Word via mammoth, Google Doc), a large tus upload, and search.
- Single hop, no intermediate release. Cutover order: stop traffic to writes, **drain Sidekiq** (pending, scheduled and retry jobs in Redis are lost otherwise), deploy, let the hook run `db:migrate` and `manifold:upgrade` (which also rebuilds the search index; time it on the production copy).
- Soak on friends, then production: announce a window, take the long-TTL on-demand Velero backup (Phase 1.1) and confirm the EFS recovery point, deploy the validated SHA, smoke test.
- **Rollback:** `helm rollback` to the 8.1.1 release *and* restore the database from the `pg_dump` inside that Velero backup (migrations are not reversible by helm); restore uploads from AWS Backup only if the upgrade rewrote files. Keep the Elasticsearch PVC until the release has been stable.

## Phase 4 — Data services

Separate from the app upgrade, one service per deploy, friends first:

- **Postgres 14.5 → the version upstream supports** (PG 14 reaches EOL this month): dump/restore into a new maintained image; uses the Phase 1 backup tooling.
- Redis is removed in Phase 3, so only Postgres remains to move off `bitnamilegacy`.
- Remove `bitnamilegacy/*` entirely; delete the Elasticsearch data after Phase 3 is stable.
- Align `docker-compose.yml` and CI service versions with production.

## Phase 5 — Stay current

- Keep the `upstream` remote; take each 9.2.x patch release as a small rebase/merge through friends → production.
- Plan 10.0 after it goes GA and has a patch release; the local client patches are tiny, so react-router 7 is upstream's cost, not ours.
- Dependabot for GitHub Actions and base images; consider offering CAS and `ALLOW_SIGNUP` upstream to shrink the fork further.

## Verification

- **CI:** all four jobs green on every PR; `build_docker_images` produces api/client/nginx images for the SHA.
- **Local:** `docker compose up` boots; `bin/rspec` and `yarn test-ci` pass in the containers.
- **Per deploy (friends, then production):** pods ready via probes; hook Job succeeded; home page and reader render; CAS login; admin backend loads; search returns results; create a project and ingest a text; upload a large file; a background job completes; Sentry receives a test event; no new error spike.
- **Backups:** `velero backup describe <name> --details` shows the postgres hook ran and the pod volume backup completed; AWS Backup shows a recovery point for the uploads filesystem.
- **Before each production step:** on-demand Velero backup Completed, and that same data proven restorable via the staging refresh.
