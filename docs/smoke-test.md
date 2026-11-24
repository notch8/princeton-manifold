# Post-deploy smoke test

Run after every deploy, friends first, then production with the same SHA.

## Deploy

- [ ] `helm upgrade` finished without `--atomic` rollback
- [ ] All pods Ready (probes pass), no restarts: `kubectl -n <ns> get pods`
- [ ] Migration hook Job succeeded (friends; production once enabled): `kubectl -n <ns> get jobs`. A failed Job is kept; read its logs.

## App

- [ ] Home page renders
- [ ] A project and its reader render
- [ ] CAS login works
- [ ] Admin backend loads
- [ ] Search returns results
- [ ] Create a project and ingest a text
- [ ] Upload a large file (tus)
- [ ] A background job completes (Sidekiq in `/api/sidekiq`)
- [ ] Sentry receives a test event
- [ ] No new error spike in Sentry or pod logs

## Backups

- [ ] `velero backup describe <name> --details` shows the postgres pre-hook ran and the pod volume backup completed
- [ ] AWS Backup shows a recovery point for the uploads filesystem

## Before each production step

- [ ] On-demand backup `Completed`: `velero backup create manifold-pre-<step> --include-namespaces princeton-manifold-production --default-volumes-to-fs-backup --ttl 720h`
- [ ] The same data has been restored on friends (staging refresh)
