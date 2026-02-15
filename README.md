# miuOps Stack Template

Your private GitOps repo for deploying Docker services to a [miuOps](https://github.com/tianshanghong/miuops)-bootstrapped server.

Push to `main` and GitHub Actions deploys your stacks via SSH.

## Prerequisites

- A server bootstrapped with [miuOps](https://github.com/tianshanghong/miuops) (Docker, cloudflared, firewall)
- SSH access to the server (key-based)
- GitHub repo created from this template

## Quick Start

1. Click **"Use this template"** to create your private stack repo
2. Set up GitHub Actions secrets (see below)
3. SSH into the server and fill in `/opt/stacks/.env` (pre-created by miuOps with secure permissions):
   ```bash
   ssh root@your-server nano /opt/stacks/.env
   ```
   Copy variables from `.env.example` and fill in real values.
4. Push to `main` — GitHub Actions deploys everything

## GitHub Actions Secrets

| Secret | Required | Description |
|--------|----------|-------------|
| `SSH_HOST` | Yes | Server IP or hostname |
| `SSH_USER` | Yes | SSH username |
| `SSH_PRIVATE_KEY` | Yes | SSH private key (full PEM) |
| `SSH_PORT` | No | SSH port (default: 22) |

## Deploy Flow

On every push to `main`:

1. **Rsync** — Syncs `stacks/` to `/opt/stacks/` (deletes removed stacks, preserves `.env`)
2. **Deploy** — Runs `docker compose up -d` for each stack (Traefik first, then the rest). After each stack, connects Traefik to the stack's per-stack ingress network.

## Staying Up to Date

This repo includes a sync workflow that pulls changes from the upstream [miuops-stack-template](https://github.com/tianshanghong/miuops-stack-template). It runs weekly (Mondays) or on demand from the **Actions** tab > **Sync template**.

When new changes are available, it opens a PR for you to review and merge. Workflow files (`.github/workflows/`) cannot be synced automatically due to GitHub token limitations — if upstream workflows change, the PR body will list them so you can update manually.

## Adding a New Service

1. Create `stacks/<name>/docker-compose.yml`
2. Add any new env vars to `.env.example` and update `/opt/stacks/.env` on the server
3. Push to `main`

### Network Model

Every service must declare explicit `networks:`. Only Traefik binds host ports. Each stack gets its own isolated ingress network — stacks cannot reach each other.

**Web service** (receives traffic via Traefik):

```yaml
services:
  myapp:
    image: myapp:latest
    labels:
      - traefik.enable=true
      - traefik.http.routers.myapp.rule=Host(`app.example.com`)
      - traefik.http.routers.myapp.entrypoints=websecure
      - traefik.http.services.myapp.loadbalancer.server.port=8080
    networks:
      - ingress
      - internal
  db:
    image: postgres:17
    volumes:
      - db_data:/var/lib/postgresql/data
    networks:
      - internal

volumes:
  db_data:

networks:
  ingress: {}                # per-stack, auto-prefixed to <stack>_ingress
  internal:
    internal: true           # no outbound internet access
```

**Key rules:**
- `ingress` — per-stack network for receiving traffic from Traefik. The deploy workflow connects Traefik to each stack's ingress network automatically. Stacks are isolated from each other.
- `internal: true` — blocks outbound internet (use for databases, caches)
- `egress` — plain bridge network for containers needing outbound internet access
- No `ports:` except Traefik — all other ingress goes through Traefik labels

### Backing Up Volumes

The `backup` stack uses [offen/docker-volume-backup](https://github.com/offen/docker-volume-backup) to upload tarballs to S3 on a daily schedule. To back up a volume, mount it into the backup container under `/backup/`:

In `stacks/backup/docker-compose.yml`, add the volume to the `backup` service:

```yaml
services:
  backup:
    # ... existing config ...
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - db_data:/backup/myapp-db:ro

volumes:
  db_data:
    external: true  # defined in the myapp stack
```

For database consistency, add labels to stop the container before backup:

```yaml
# In stacks/myapp/docker-compose.yml
services:
  db:
    image: postgres:17
    labels:
      - docker-volume-backup.stop-during-backup=true
```

### PostgreSQL + WAL-G Continuous Archiving

For PostgreSQL databases, use the `postgres-walg` image (built from `images/postgres-walg/` in the metal repo) for continuous WAL archiving to S3. This runs alongside the volume backup stack — both write to the same S3 bucket under different prefixes:

```
myproject-backup/          # One bucket per project
  db/                      # WAL-G database backups
    myapp/                 #   per-app prefix
      basebackups_005/
      wal_005/
  vol/                     # Offen volume tarballs
    backup-2025-01-15T02-00-00.tar.gz
```

Example compose file using the `postgres-walg` image:

```yaml
services:
  db:
    image: ghcr.io/yourorg/postgres-walg:17
    environment:
      POSTGRES_DB: myapp
      POSTGRES_USER: myapp
      POSTGRES_PASSWORD: ${DB_PASSWORD}
      WALG_S3_PREFIX: ${WALG_S3_PREFIX}
      AWS_ACCESS_KEY_ID: ${AWS_ACCESS_KEY_ID}
      AWS_SECRET_ACCESS_KEY: ${AWS_SECRET_ACCESS_KEY}
      AWS_REGION: ${AWS_REGION}
    volumes:
      - db_data:/var/lib/postgresql/data
    networks:
      - internal
```

**Host cron** for daily base backups (in addition to continuous WAL archiving):

```
0 3 * * * cd /opt/stacks/myapp && docker compose exec -T -u postgres db walg-backup.sh
```

#### Encrypting Backups

Client-side encryption is **strongly recommended** since backups include your `.env` file (which contains secrets). The backup sidecar supports GPG and Age encryption — set one of the encryption variables in your `.env` to enable it. See the [Backup Encryption Guide](https://github.com/tianshanghong/miuops/blob/main/docs/BACKUP_ENCRYPTION.md) for setup instructions and method comparison.

**Retention**: Object Lock (Governance mode, 30 days) prevents deletion without explicit override. S3 lifecycle transitions to Glacier after 30 days and expires after 90 days.

## Included Stacks

- **traefik** — Reverse proxy. Listens on 80 (redirect) and 443. Cloudflared connects to 443 with `noTLSVerify`.
- **backup** — Daily Docker volume backups to S3 via [offen/docker-volume-backup](https://github.com/offen/docker-volume-backup). No volumes are backed up by default — mount the ones you need (see above). For PostgreSQL, use the WAL-G pattern above instead of stop-during-backup.
