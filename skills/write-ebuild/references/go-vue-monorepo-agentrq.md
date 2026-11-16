# AgentRQ — Go + Vue.js Monorepo Ebuild Example

**Package:** app-misc/agentrq (live/9999 ebuild)
**Source:** https://github.com/agentrq/agentrq
**License:** Apache-2.0

## Structure

Three packages in localrepo:

```
app-misc/agentrq/
├── agentrq-9999.ebuild   # main ebuild
├── files/
│   └── agentrq.service   # systemd unit
├── metadata.xml          # GitHub remote-id
└── Manifest

acct-group/agentrq/agentrq-0.ebuild   # GID 498
acct-user/agentrq/agentrq-0.ebuild    # UID 498, /var/lib/agentrq
```

## Ebuild approach

- **Live (9999)** — `git-r3` fetches latest main, `go-module_live_vendor` vendors Go deps at build time
- **Multi-stack** — builds Vue frontend (npm ci + npm run build) then Go backend (CGO_ENABLED=0)
- **Static binary** — Go is compiled with `CGO_ENABLED=0` so it has zero C library deps
- **Binary at /usr/libexec** — installed via `exeinto`/`doexe` not `dobin`, because systemd service controls the runtime WorkingDirectory
- **Config via symlinks** — binary reads `./_config/` relative to CWD; service unit uses `ExecStartPre` to symlink `/etc/agentrq/` files into the WorkingDirectory

## Config loading

The binary reads `./_config/base.yaml` + `./_config/{ENV}.yaml` from CWD. Both files expand `${ENV_VAR}` placeholders from the environment. So config can be entirely via env vars (Docker pattern) or via files.

Pitfall: env vars containing special chars (`***`, `&`, `:`) get expanded into the YAML at parse time. If the expanded value breaks YAML syntax, the binary crashes at startup with `yaml: line N: did not find expected alphabetic or numeric character`. Prefer setting values via a env-specific YAML override file (e.g. `_config/development.yaml`) with real YAML literals instead of env vars with non-alphanumeric characters.

## Local testing (without ebuild)

For testing the project without installing:

```bash
git clone https://github.com/agentrq/agentrq.git
cd agentrq
make install          # go mod download + npm install
# Enable root login:
echo 'auth:
  rootLoginEnabled: true
  rootAccessToken: my-test-token' > backend/cmd/server/_config/development.yaml
cd backend/cmd/server
go build -o agentrq_binary main.go
ENV=development ./agentrq_binary
```

Then authenticate:
```bash
# The JSON field is "rootToken" NOT "accessToken"
curl -X POST http://localhost:3000/api/v1/auth/root/login \
  -H "Content-Type: application/json" \
  -d '{"rootToken": "my-test-token"}'
# Returns {"status":"ok"} with a Set-Cookie: at=JWT_TOKEN
curl -b /tmp/cookies http://localhost:3000/api/v1/workspaces
# Returns {"workspaces":[]}
```

Key API details:
- Auth config: `GET /api/v1/auth/config` (shows if rootLoginEnabled, githubLoginEnabled)
- Root login: `POST /api/v1/auth/root/login` with JSON body `{"rootToken": "..."}` — NOT `accessToken`
- Response is a JWT cookie named `at` (HTTPOnly, 24h expiry)
- Workspace CRUD: `GET/POST /api/v1/workspaces`
- Tasks: `GET/POST /api/v1/workspaces/{id}/tasks`
- MCP endpoint: `GET /mcp/{workspaceId}?token={token}`

## Systemd service pattern

The service unit uses `ExecStartPre` to:
1. Create state directories
2. Symlink production.yaml from /etc/agentrq/ into the WorkingDirectory
3. Copy base.yaml if not yet present

This avoids modifying the binary or wrapping it in a shell script.

## Relevant pkgcheck warnings fixed

- `VariableOrderWrong` — `S` must come before `RESTRICT`
- `MissingRemoteId` — needs `metadata.xml` with `<remote-id type=\"github\">`
- `MismatchedPN` — acct-user/acct-group ebuilds must be named `<name>-0.ebuild`, NOT `<cat>-<name>-0.ebuild`
