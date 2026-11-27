# docker-patterns — Extended Reference

## Hardened CLI Installer Harnesses

Use containers to test installer behavior against disposable project copies without allowing the test to mutate the source checkout.

### Respect the Platform Boundary

- Run real containers for Linux distributions such as Debian and Ubuntu.
- macOS cannot run as a Docker container because Docker shares a Linux kernel. Run the same shell-free test entry point natively on macOS.
- Windows containers require a Windows Docker engine. Run platform-independent logic on a native Windows CI runner and reserve Windows containers for a Windows host.
- Keep a native Ubuntu/macOS/Windows CI matrix for host-specific paths, command shims, quoting, and filesystem behavior.

Do not claim that a Linux container validates macOS or Windows behavior.

### Enforce the Isolation Contract

- Pin base images by immutable digest and pin installed CLI versions.
- Run as a non-root numeric UID/GID when distro account names differ.
- Mount the repository and source project read-only.
- Copy the source project into a writable `tmpfs` workspace before any mutation.
- Mount `/workspace` with `noexec`, UID/GID 1000, and `mode=0700` so only the
  container user can inspect project data.
- Keep npm and npx's executable cache at `NPM_CONFIG_CACHE=/tmp/npm-cache` on
  the executable `/tmp` mount. Its default size is 2 GiB and can be adjusted
  with `ECC_TMPFS_SIZE`; `ECC_WORKSPACE_SIZE` separately controls the private
  workspace mount.
- Set `read_only: true`, `no-new-privileges:true`, `cap_drop: [ALL]`, and a finite `pids_limit`.
- Keep the default real-CLI services on `network_mode: none`. Add network access
  only through a visibly named opt-in service for an authenticated provider
  session; never make it an accidental environment-driven default.
- Create only the writable temporary paths the tool needs.
- Do not pass host credentials into the container by default.
- Default to a dry run and whitelist only the explicit `dry-run`, `install`,
  `plugin`, and `shell` modes.
- Use argument arrays or `spawnSync(..., { shell: false })` for cross-platform runners. Never interpolate project paths into a shell command.

### Exercise the ECC Plugin Setup Harness

Use `docker/plugin-setup/compose.yaml` as the reference implementation. It provides:

- `fixture-tests` for the focused install manifest, target, and executor suite.
- `real-cli` for the pinned Debian-based generic Linux image.
- `real-cli-ubuntu` for the pinned Ubuntu image.

Validate the Compose model before building:

```bash
docker compose -f docker/plugin-setup/compose.yaml config --quiet
```

Build both real Linux images:

```bash
docker compose -f docker/plugin-setup/compose.yaml \
  build real-cli real-cli-ubuntu
```

Run the safe default flow in each image:

```bash
docker compose -p ecc-plugin-debian-test \
  -f docker/plugin-setup/compose.yaml \
  run --rm -T real-cli dry-run

docker compose -p ecc-plugin-ubuntu-test \
  -f docker/plugin-setup/compose.yaml \
  run --rm -T real-cli-ubuntu dry-run
```

The dry run executes the current public command contract:

```bash
ecc install --profile core --target claude-project --dry-run --json
```

Before that command runs, the container creates a locally packed npm artifact
from the read-only checkout with `npm pack --ignore-scripts`. It extracts the
self-created tarball under `/tmp`, validates the `ecc-universal` package name,
required install manifests, and the confined `package.json` `bin.ecc` mapping,
then invokes the extracted `ecc` executable. The runtime stays on
`network_mode: none`, does not execute package lifecycle scripts, and does not
rely on host `node_modules`; its exact pinned production dependencies are
already present in the image.

The harness rejects an empty plan, a non-`claude-project` target, any operation
outside `/workspace/project/.claude`, or any dry run that creates the target
directory. `install` performs the isolated apply twice, checks its managed
install state, lists the installed target, and runs `doctor`.

### Start, Open, Reconnect, and Clean Up a Named Session

Start a detached container without `--rm` so leaving a terminal does not remove
the session:

```bash
docker compose -p ecc-plugin-session \
  -f docker/plugin-setup/compose.yaml \
  run --detach --name ecc-plugin-shell real-cli shell
```

The container copies the read-only fixture to the stable private directory
`/workspace/project`. Confirm it is running, then emit the Docker side of the
terminal-opener v1 data contract:

```bash
docker inspect --format '{{.State.Running}}' ecc-plugin-shell
node docker/plugin-setup/interactive-plan.js \
  --container ecc-plugin-shell \
  --workdir /workspace/project \
  --json \
  -- bash
```

The JSON result has exactly an `executable` and `argv` boundary (plus
`contractVersion: 1`): the executable is `docker`, and argv begins with
`exec`, `-it`, and `-w`. Pass that data to the separate terminal-opener skill
when it is installed. This Docker harness deliberately does not import a
terminal adapter, interpolate a shell command, or manage a host GUI process.
Until then, open the same PTY in the current host terminal directly:

```bash
docker exec -it -w /workspace/project ecc-plugin-shell bash
```

Exit the shell without stopping the detached container. Reconnect with the
same `docker exec -it` command. When finished, remove the exact named container
and its Compose project resources:

```bash
docker rm --force ecc-plugin-shell
docker compose -p ecc-plugin-session \
  -f docker/plugin-setup/compose.yaml \
  down --remove-orphans
```

Host credentials are absent by default and credential directories are never
mounted. The default service also has no network access. When an authenticated
provider session genuinely needs a network, build `real-cli` first and then opt
in visibly with `docker compose -f docker/plugin-setup/compose.yaml
--profile networked run --service-ports real-cli-networked shell`. The
`--service-ports` flag publishes the service's loopback callback mapping.
Prefer authenticating inside that disposable session. If a CI run must
inherit a host environment credential, make that opt-in at invocation with an
explicit Compose `--env NAME` flag, understand that the value is inspectable
and can be exfiltrated for the container lifetime, and remove the exact named
container immediately after.

### Authenticate Codex Inside the Networked Session

`codex login` binds its OAuth callback server to `127.0.0.1:1455` inside the
container. A Docker port publish forwards to the container interface, not
loopback, so the host browser's redirect to `http://localhost:1455` is refused
without a bridge. The `real-cli-networked` service publishes host
`127.0.0.1:1455` to container port `1456`; bridge that port to loopback before
logging in:

```bash
(
  set -e
  npm install --global @openai/codex@0.162.0   # the harness image does not ship codex
  node /ecc/docker/plugin-setup/codex-auth-relay.js &
  relay_pid=$!
  trap 'kill "$relay_pid" 2>/dev/null || true; wait "$relay_pid" 2>/dev/null || true' EXIT
  codex login
)
```

The networked service sets `NPM_CONFIG_PREFIX=/tmp/ecc-npm` and adds its `bin`
directory to `PATH`. This keeps the pinned installation writable for UID 1000
on the executable `/tmp` mount while the root filesystem remains read-only.

Complete the sign-in in the host browser. Each attempt mints a fresh
`state`/`code`, so always follow the newest printed link. The token stays in
the disposable container's `~/.codex/auth.json`; removing the named container
deletes that credential copy. The login block stops the relay on success or failure.
Only one container can hold host port 1455 at a time
because the OAuth redirect targets a fixed port.

The host publish is restricted to loopback. Inside the container, the relay
listens on all interfaces so Docker can forward to it; other containers on the
same bridge network can reach it while it runs. Use a dedicated network without
untrusted peers for this login, and remove the exact named container after use.
Idle callback connections close after 30 seconds.

Run the same focused suite natively on the host:

```bash
npm run test:plugin-setup-platform
```

Inspect the produced identity and environment before trusting the image:

```bash
docker image inspect ecc-plugin-setup:debian ecc-plugin-setup:ubuntu
```

Clean each named test project without deleting unrelated volumes or images:

```bash
docker compose -p ecc-plugin-debian-test \
  -f docker/plugin-setup/compose.yaml down --remove-orphans
docker compose -p ecc-plugin-ubuntu-test \
  -f docker/plugin-setup/compose.yaml down --remove-orphans
```

## .dockerignore

```
node_modules
.git
.env
.env.*
dist
coverage
*.log
.next
.cache
docker-compose*.yml
Dockerfile*
README.md
tests/
```

## Debugging

### Common Commands

```bash
# View logs
docker compose logs -f app           # Follow app logs
docker compose logs --tail=50 db     # Last 50 lines from db

# Execute commands in running container
docker compose exec app sh           # Shell into app
docker compose exec db psql -U postgres  # Connect to postgres

# Inspect
docker compose ps                     # Running services
docker compose top                    # Processes in each container
docker stats                          # Resource usage

# Rebuild
docker compose up --build             # Rebuild images
docker compose build --no-cache app   # Force full rebuild

# Clean up
docker compose down                   # Stop and remove containers
docker compose down -v                # Also remove volumes (DESTRUCTIVE)
docker system prune                   # Remove unused images/containers
```

### Debugging Network Issues

```bash
# Check DNS resolution inside container
docker compose exec app nslookup db

# Check connectivity
docker compose exec app wget -qO- http://api:3000/health

# Inspect network
docker network ls
docker network inspect <project>_default
```

## Anti-Patterns

```
# BAD: Using docker compose in production without orchestration
# Use Kubernetes, ECS, or Docker Swarm for production multi-container workloads

# BAD: Storing data in containers without volumes
# Containers are ephemeral -- all data lost on restart without volumes

# BAD: Running as root
# Always create and use a non-root user

# BAD: Using :latest tag
# Pin to specific versions for reproducible builds

# BAD: One giant container with all services
# Separate concerns: one process per container

# BAD: Putting secrets in docker-compose.yml
# Use .env files (gitignored) or Docker secrets
```
