# miuOps Fleet Template

Your private GitOps repo for a fleet of [miuOps](https://github.com/tianshanghong/miuops)-managed servers.

One repo describes every server you run: its inventory, its per-server config, its
encrypted secrets, and its Docker service stacks. Push to `main` and GitHub Actions
deploys the changed servers — each server's stacks are synced and brought up over SSH.

miuOps provides the shared infrastructure host-side on each server — Docker, cloudflared,
the firewall, the Traefik reverse proxy, and volume backups. This repo holds your
user-workload stacks and the config that places them on servers.

## Layout

```
fleet/
  inventory.ini                 # which servers exist (server -> host, user)
  group_vars/
    all.yml                     # fleet-wide config: the Grafana Cloud observability endpoints
  host_vars/
    server-01.yml               # per-server config: domains + tunnel_id
  secrets/
    server-01.env               # SOPS-encrypted app env (committed, unreadable without your key)
    <tunnel_id>.json            # SOPS-encrypted Cloudflare tunnel credential
    all.vars.json               # SOPS-encrypted fleet-wide deployed vars (the Grafana Cloud token)
    <server>.vars.json          # SOPS-encrypted per-server deployed vars (AWS backup credentials)
  stacks/
    server-01/                  # one directory per server
      whoami/
        docker-compose.yml      # one directory per stack
.sops.yaml                      # encryption rule for fleet/secrets/*
.env.example                    # cleartext template for fleet/secrets/<server>.env
.github/workflows/
  deploy.yml                    # ~10-line caller -> miuops reusable deploy workflow
  ci.yml                        # runs the miuops stack policy-check on every push/PR
```

Stacks are exactly two levels deep: `fleet/stacks/<server>/<stack>/`. The `<server>`
matches a handle in `inventory.ini`; the `<stack>` is one Docker Compose project.

## Prerequisites

- The [miuOps](https://github.com/tianshanghong/miuops) CLI installed locally
- A server you control with SSH access (key-based)
- A Cloudflare account + API token (the bootstrap creates the tunnel and DNS)
- [`sops`](https://github.com/getsops/sops) and an [`age`](https://github.com/FiloSottile/age)
  key (or a YubiKey age recipient) for secrets

## Adopt this template

1. Click **"Use this template"** to create your private fleet repo, then clone it.

2. **Bootstrap a server.** From the repo root, run the CLI with your Cloudflare token
   and the domains this server serves:

   ```bash
   CF_API_TOKEN=… miuops up server-01 example.com
   ```

   This provisions the server, creates its Cloudflare tunnel, and writes the plaintext
   config into `fleet/` — the `inventory.ini` host line and `fleet/host_vars/server-01.yml`
   (`domains:` + `tunnel_id:`). It also stores the tunnel credential, encrypted, at
   `fleet/secrets/<tunnel_id>.json`.

3. **Wire the deploy key.** Generate a deploy keypair and give the server only the
   public half (the tool installs it into the deploy user's `authorized_keys`). Create a
   per-server [GitHub Environment](https://docs.github.com/actions/deployment/targeting-different-environments/using-environments-for-deployment)
   named after the server handle (e.g. `server-01`) and set these environment secrets:

   | Secret | Required | Description |
   |--------|----------|-------------|
   | `SSH_HOST` | Yes | Server IP or hostname |
   | `SSH_USER` | Yes | SSH username (the deploy user) |
   | `SSH_PRIVATE_KEY` | Yes | The deploy **private** key (full PEM) |
   | `SSH_PORT` | No | SSH port (default: 22) |
   | `SSH_KNOWN_HOSTS` | No | Pinned host keys (`ssh-keyscan -p <port> <host>`). When set, deploys verify the host key (no MITM window); unset falls back to trust-on-first-use on the first connection. Set it for production. |

   The deploy workflow targets `environment: <server>`, so each server reads only its own
   environment's secrets.

4. **Fill in app secrets.** Copy the env template, fill in real values, encrypt it, and
   commit the encrypted file:

   ```bash
   cp .env.example fleet/secrets/server-01.env
   #   …edit fleet/secrets/server-01.env…
   sops -e -i fleet/secrets/server-01.env
   git add fleet/secrets/server-01.env
   ```

5. **Configure observability + deployed secrets.** Observability is **enabled by default** —
   it activates as soon as you set the Grafana Cloud connection (no flag to flip); until then
   the converge gracefully skips it. The endpoints are **config** — set them in
   `fleet/group_vars/all.yml` (copy `group_vars/all.yml.example`). The **token** is a secret —
   put it in `fleet/secrets/all.vars.json`. Create it with the SOPS editor so the plaintext
   never lands on disk or in your shell history:

   ```bash
   cp fleet/group_vars/all.yml.example fleet/group_vars/all.yml   # …fill in the endpoints…
   sops fleet/secrets/all.vars.json   # opens $EDITOR; add { "grafana_cloud_token": "glc_..." }, save → encrypted in place
   ```

   Per-server deployed secrets — e.g. a server's AWS backup credentials — go in
   `fleet/secrets/<server>.vars.json` the same way. These are applied by the **converge**
   (`miuops up` / `miuops apply <server>`, run from this repo — which decrypts them with your
   age key and renders them into the on-host config with **no per-apply env**), not by the
   stack deploy in steps 6–7. See **Secrets** below.

6. **Add a stack.** Put a compose file at `fleet/stacks/server-01/<stack>/docker-compose.yml`
   (the included `whoami` example shows the shape). Point its `Host(...)` rule at a
   hostname under one of the server's domains.

7. **Push to `main`.** GitHub Actions runs the policy-check, then deploys the servers whose
   stacks changed.

## Secrets

`fleet/secrets/` holds everything sensitive, encrypted with [SOPS](https://github.com/getsops/sops):

- `<server>.env` — the per-server app environment, installed to `/opt/stacks/.env`.
- `<tunnel_id>.json` — the Cloudflare tunnel credential.
- `all.vars.json` — fleet-wide **deployed vars**: the Grafana Cloud token. Decrypted at
  converge and handed to Ansible, so the secret renders into the on-host config with no
  per-apply env. Its companion config — the observability endpoints — is committed in the
  clear in `group_vars/all.yml`.
- `<server>.vars.json` — per-server deployed vars: that server's AWS backup credentials.

`.sops.yaml` (at the repo root) is the single source of truth for what gets encrypted; its
one rule matches `^fleet/secrets/.*\.(json|env)$` and nothing else. **Replace the
placeholder `age:` recipient in `.sops.yaml` with your own** — an `age` public key from
`age-keygen`, or a YubiKey/age-plugin recipient (both are `age1…` strings). List more than
one recipient (comma-separated) to let several operators or a backup key decrypt.

The encrypted files are committed — they are unreadable without your key. The plaintext
`inventory.ini` and `host_vars/*.yml` are **config, not secrets**, and are committed in the
clear. `.gitignore` re-allows the encrypted `fleet/secrets/*.{json,env}` and blocks the
`*.dec` / `*.plain` scratch conventions. Because it matches by filename, it cannot catch a
secret decrypted in place or a plaintext copy that keeps the `.json`/`.env` name — so always
`sops -e -i` in place and confirm the committed file is ciphertext (it contains `ENC[`).
CI never sees plaintext: the deploy excludes `.env` from the sync.

## Deploy flow

`deploy.yml` is a thin caller — it delegates to the miuOps reusable workflow, pinned to an
immutable tag:

```yaml
jobs:
  deploy:
    uses: tianshanghong/miuops/.github/workflows/deploy.yml@v0.1.0
    secrets: inherit
```

On every push to `main`, the reusable workflow discovers which servers changed, syncs each
changed server's `fleet/stacks/<server>/` to its `/opt/stacks/`, and brings the stacks up.
Host-side Traefik routes to each stack through that stack's per-stack `ingress` network.

The tag is pinned (never `@main`) on purpose: the reusable workflow holds an SSH deploy key,
so a mutable ref would let any upstream change take over every server in your fleet.

## Upgrading

Upgrading the deploy machinery is a one-line bump: change the `@v0.1.0` tag in `deploy.yml`
to the new miuOps release, and update your local `miuops` CLI to a matching version. There is
no machinery to merge into this repo — the deploy logic lives in the pinned reusable workflow,
and the policy-check is fetched fresh from miuOps on every CI run. Review the release notes,
bump the tag, push.

## Adding a new stack

1. Create `fleet/stacks/<server>/<name>/docker-compose.yml`.
2. Add any new env vars to `.env.example`, set them in `fleet/secrets/<server>.env`
   (`sops -e -i …`), and commit the re-encrypted file.
3. Push to `main`.

### Environment variables

Every stack on a server **shares one `/opt/stacks/.env`** (decrypted from
`fleet/secrets/<server>.env`), so every variable must be **namespaced** — never a
bare/generic name (e.g. `DB_PASSWORD`, `API_KEY`), or two projects silently override
each other.

- **Project vars** — prefix with the project handle, then map to the app's expected name
  in the compose `environment:` block (left = the name the app/SDK reads, right = the
  namespaced `.env` name):

  ```yaml
  services:
    myapp:
      environment:
        DB_PASSWORD: ${MYAPP_DB_PASSWORD}
        ANTHROPIC_API_KEY: ${MYAPP_ANTHROPIC_API_KEY}
  ```

- **Shared infrastructure** — the S3 credentials for in-stack WAL-G archiving use the
  `BACKUP_` namespace (`BACKUP_AWS_ACCESS_KEY_ID`, …). Reference them from each database
  stack that archives WAL; don't duplicate them under per-project names.

The app-facing name stays standard (the SDK still sees `ANTHROPIC_API_KEY`) while the
shared file stays collision-free. See `.env.example`.

### Network model

Every service declares explicit `networks:`. No stack binds host ports — web services are
reached only through their Traefik labels plus the per-stack `ingress` network. Each stack
gets its own isolated `ingress` network, so stacks cannot reach each other. The default
bridge is not used.

**Web service** (receives traffic via Traefik):

```yaml
services:
  myapp:
    image: myapp@sha256:…        # digest-pinned for an immutable deploy
    cap_drop: [ALL]
    labels:
      - traefik.enable=true
      - traefik.http.routers.myapp.rule=Host(`app.example.com`)
      - traefik.http.routers.myapp.entrypoints=websecure
      - traefik.http.services.myapp.loadbalancer.server.port=8080
    networks:
      - ingress
      - internal
  db:
    image: postgres@sha256:…
    cap_drop: [ALL]
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
- `ingress` — per-stack network that receives traffic from Traefik. Stacks are isolated from each other.
- `internal: true` — backend services (databases, caches) use this to block outbound internet.
- `egress` — plain bridge network for containers that need outbound internet access.
- The default bridge is not used — every service joins a named network.
- No host-bound `ports:` — all ingress goes through Traefik labels. If a service must publish a port, bind it to `127.0.0.1`.

The included `whoami` example and the CI policy-check enforce these rules.

### Domains & TLS

Route a service by giving it a Traefik `Host(...)` rule (above) under a hostname that
points at this server's tunnel. The server's `domains:` (in `fleet/host_vars/<server>.yml`)
each get a `<domain>` plus a one-level wildcard `*.<domain>` CNAME.

**Cloudflare free Universal SSL** covers the zone apex and a **one-level** wildcard
(`*.example.com`) — so `example.com`, `app.example.com`, and `api.example.com` all get
HTTPS for free.

It does **not** cover a **second-level** wildcard (`*.sub.example.com`). Nesting hosts
another level deep (e.g. `api.sub.example.com`) needs Cloudflare **Advanced Certificate
Manager** (paid).

**Prefer first-level subdomains to stay on free certs.** `app.example.com`,
`api.example.com`, … are all covered by Universal SSL, and each can point at a
**different server** via its own domain entry (an exact subdomain record overrides the
apex `*.example.com`). So splitting hosts across servers — **by service, by environment
(prod/dev), by tenant, or any other reason** — stays on free certs as long as the names
remain first-level; nesting another level (`*.sub.example.com`) is what triggers the ACM
requirement.

### Private registry authentication

To deploy images from private registries (GHCR, Docker Hub, self-hosted), add credentials to
the server's `fleet/secrets/<server>.env` using this pattern:

```bash
DOCKER_REGISTRY_<NAME>_URL=<registry-url>
DOCKER_REGISTRY_<NAME>_USER=<username>
DOCKER_REGISTRY_<NAME>_PASSWORD=<token>
```

Name each registry whatever you like. The deploy auto-discovers all `DOCKER_REGISTRY_*`
entries and logs in before deploying stacks.

**Example** — pulling from GitHub Container Registry:

```bash
DOCKER_REGISTRY_GHCR_URL=ghcr.io
DOCKER_REGISTRY_GHCR_USER=your-github-username
DOCKER_REGISTRY_GHCR_PASSWORD=ghp_xxxxxxxxxxxx
```

Create tokens with read-only package access:
- **GHCR**: [Personal Access Token](https://github.com/settings/tokens) with `read:packages` scope
- **Docker Hub**: [Access Token](https://hub.docker.com/settings/security)

See `.env.example` for more examples.

### Backing up volumes

Docker volume backups are handled host-side by the miuOps `backup` role (a host `systemd`
timer). For PostgreSQL, use the in-stack WAL-G pattern below.

### PostgreSQL + WAL-G continuous archiving

For PostgreSQL databases, use the pre-built
[`postgres-walg`](https://github.com/tianshanghong/miuops/tree/main/images/postgres-walg)
image for continuous WAL archiving to S3. It adds [WAL-G](https://github.com/wal-g/wal-g) to
the official `postgres` image with archive mode pre-configured. WAL-G also supports MySQL,
MariaDB, MongoDB, and other databases — see the [WAL-G docs](https://github.com/wal-g/wal-g#databases)
to build a similar image for other engines.

WAL-G writes to the project's S3 bucket under a `db/` prefix, one sub-prefix per app:

```
myproject-backup/          # One bucket per project
  db/                      # WAL-G database backups
    myapp/                 #   per-app prefix
      basebackups_005/
      wal_005/
```

Example compose file using the `postgres-walg` image:

```yaml
services:
  db:
    image: ghcr.io/tianshanghong/postgres-walg@sha256:…
    cap_drop: [ALL]
    environment:
      POSTGRES_DB: myapp
      POSTGRES_USER: myapp
      POSTGRES_PASSWORD: ${MYAPP_DB_PASSWORD}
      WALG_S3_PREFIX: ${MYAPP_WALG_S3_PREFIX}
      AWS_ACCESS_KEY_ID: ${BACKUP_AWS_ACCESS_KEY_ID}
      AWS_SECRET_ACCESS_KEY: ${BACKUP_AWS_SECRET_ACCESS_KEY}
      AWS_REGION: ${BACKUP_AWS_REGION}
    volumes:
      - db_data:/var/lib/postgresql/data
    networks:
      - internal
      - egress      # WAL-G needs outbound internet to reach S3

volumes:
  db_data:

networks:
  internal:
    internal: true   # no outbound internet
  egress:            # plain bridge: outbound internet (so WAL-G reaches S3)
```

**Host cron** for daily base backups (in addition to continuous WAL archiving):

```
0 3 * * * cd /opt/stacks/myapp && docker compose exec -T -u postgres db walg-backup.sh
```

**Retention**: Object Lock (Governance mode, 30 days) prevents deletion without explicit
override. S3 lifecycle transitions to Glacier after 30 days and expires after 90 days.

## CI policy-check

`ci.yml` runs the canonical miuOps stack policy-check over every
`fleet/stacks/*/*/docker-compose.yml` on each push and pull request. It is fetched fresh from
miuOps on each run (so the policy always tracks upstream) and gates public/non-loopback
published ports, `privileged`, host-namespace sharing, the default bridge, missing
`cap_drop: [ALL]`, dangerous `cap_add`, sandbox-weakening `security_opt`, sensitive
bind-mounts, and devices; it warns on un-pinned images.

## Verifying the structure

`tests/template_structure_test.sh` is a structure-lint you can run locally to confirm the
fleet skeleton and the machinery-free deploy are intact (pinned tag, SOPS rule, `.gitignore`
allow/block lists, the example stack passing the policy-check). Run `--list-mutations` to see
the broken-state checks it guards against.

## License

The template itself is [Apache License 2.0](LICENSE) (see [NOTICE](NOTICE)). A private fleet
repo you create from it is yours — relicense or remove this as you like.
