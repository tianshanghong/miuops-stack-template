# miuOps Stack Template

Your private GitOps repo for deploying Docker services to a [miuOps](https://github.com/tianshanghong/miuOps)-bootstrapped server.

Push to `main` and GitHub Actions deploys your stacks via SSH.

## Prerequisites

- A server bootstrapped with [miuOps](https://github.com/tianshanghong/miuOps) (Docker, Traefik network, cloudflared, firewall)
- SSH access to the server (key-based)
- GitHub repo created from this template

## Quick Start

1. Click **"Use this template"** to create your private stack repo
2. Set up GitHub Actions secrets (see below)
3. Copy `.env.example`, fill in real values, paste into the `ENV_FILE` secret
4. Push to `main` — GitHub Actions deploys everything

## GitHub Actions Secrets

| Secret | Required | Description |
|--------|----------|-------------|
| `SSH_HOST` | Yes | Server IP or hostname |
| `SSH_USER` | Yes | SSH username |
| `SSH_PRIVATE_KEY` | Yes | SSH private key (full PEM) |
| `SSH_PORT` | No | SSH port (default: 22) |
| `ENV_FILE` | Yes | Contents of your `.env` file |

## Deploy Flow

On every push to `main`:

1. **Write `.env`** — Writes `ENV_FILE` secret to `/opt/stacks/.env` (chmod 600)
2. **Rsync** — Syncs `stacks/` to `/opt/stacks/` (deletes removed stacks, preserves `.env`)
3. **Deploy** — Runs `docker compose up -d` for each stack (Traefik first, then the rest)

## Adding a New Service

1. Create `stacks/<name>/docker-compose.yml`
2. Add any new env vars to `.env.example` and your `ENV_FILE` secret
3. Push to `main`

### Network Model

Every service must declare explicit `networks:`. Only Traefik binds host ports.

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
      - traefik_network
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
  traefik_network:
    external: true
  internal:
    internal: true  # no outbound internet access
```

**Key rules:**
- `traefik_network` (external) — join this to receive traffic from Traefik
- `internal: true` networks block outbound internet (use for databases)
- Use a plain `bridge` network (like `egress`) when a container needs outbound internet access

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

## Included Stacks

- **traefik** — Reverse proxy. Listens on 80 (redirect) and 443. Cloudflared connects to 443 with `noTLSVerify`.
- **backup** — Daily Docker volume backups to S3 via [offen/docker-volume-backup](https://github.com/offen/docker-volume-backup). No volumes are backed up by default — mount the ones you need (see above).
