# Restoring a PostgreSQL backup

Backups made by `pg-backup.sh` are `pg_dump` custom-format archives, written
uncompressed and then gzipped: `<database>_<UTC timestamp>.dump.gz`.

The examples use the database `app`, the role `app` and the backup directory
`/var/backups/postgres`. Run the commands as a sudo user on the server.

## 1. Pick a backup

Local copies:

```bash
sudo ls -lh /var/backups/postgres/
```

Off-site copies, if rclone is configured for the postgres user:

```bash
sudo -u postgres rclone lsl offsite:app-db
sudo -u postgres rclone copy offsite:app-db/app_20261115T023000Z.dump.gz /var/backups/postgres/
```

Set a variable for the rest of the steps:

```bash
BACKUP=/var/backups/postgres/app_20261115T023000Z.dump.gz
```

## 2. Check the archive before using it

```bash
sudo gzip -t "$BACKUP" && echo "gzip OK"
sudo -u postgres bash -c "gunzip -c '$BACKUP' | pg_restore --list | head -n 20"
```

The listing should show the expected tables, including `alembic_version`.

## 3. Restore drill into a scratch database

Do this once a month, and always before trusting a backup in an emergency.
It does not touch the live database.

```bash
sudo -u postgres createdb --owner app app_restore_check
sudo -u postgres bash -c "gunzip -c '$BACKUP' | pg_restore --no-owner --role=app --exit-on-error --single-transaction --dbname=app_restore_check"
```

Compare it with the live database:

```bash
sudo -u postgres psql -d app_restore_check -c "SELECT version_num FROM alembic_version;"
sudo -u postgres psql -d app -c "SELECT version_num FROM alembic_version;"
sudo -u postgres psql -d app_restore_check -c "SELECT relname, n_live_tup FROM pg_stat_user_tables ORDER BY relname;"
```

Row counts in the drill should be close to production, allowing for writes
since the backup time. Clean up when done:

```bash
sudo -u postgres dropdb app_restore_check
```

## 4. Restore over production

The live database is renamed, not dropped, so you can go back to it if the
restore turns out to be the wrong call.

1. Stop the API so nothing writes during the restore. The web app keeps
   serving pages; API calls return 502 until step 6.

   ```bash
   sudo -u deploy pm2 stop api
   ```

2. Take a fresh backup of the current state, even if it is broken:

   ```bash
   sudo -u postgres /opt/server-deploy-toolkit/backup/pg-backup.sh --database app
   ```

3. Move the live database aside and create an empty one:

   ```bash
   sudo -u postgres psql -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = 'app' AND pid <> pg_backend_pid();"
   sudo -u postgres psql -c "ALTER DATABASE app RENAME TO app_before_restore;"
   sudo -u postgres createdb --owner app app
   ```

4. Restore. `--single-transaction` means a failure leaves the new database
   empty instead of half restored:

   ```bash
   sudo -u postgres bash -c "gunzip -c '$BACKUP' | pg_restore --no-owner --role=app --exit-on-error --single-transaction --dbname=app"
   ```

5. Check the schema version matches the deployed code:

   ```bash
   sudo -u postgres psql -d app -c "SELECT version_num FROM alembic_version;"
   sudo -u deploy bash -c 'cd /srv/app/current/api && set -a && . /srv/app/shared/.env && set +a && .venv/bin/alembic current'
   ```

   If the backup is older than the latest migration, run
   `.venv/bin/alembic upgrade head` the same way before starting the API.

6. Start the API and check health:

   ```bash
   sudo -u deploy pm2 start api
   curl -fsS http://127.0.0.1:8000/api/health
   ```

7. Once the app has been confirmed working for a few days:

   ```bash
   sudo -u postgres dropdb app_before_restore
   ```

## Notes

- Extensions that need a superuser to create (not the trusted ones such as
  `pgcrypto` or `citext`) must exist before step 4:
  `sudo -u postgres psql -d app -c "CREATE EXTENSION <name>;"`.
- Restore is single-threaded. If restore time becomes a problem, switch to
  directory-format dumps (`pg_dump --format=directory --jobs N`), which
  `pg_restore --jobs N` can restore in parallel.
- The `.env` sourcing in step 5 assumes plain `KEY=value` lines, which is what
  `env/.env.example` uses.
