# Shared-Host Mode (isolated, one OS account per person)

Let remote people use **this box's already-logged-in Claude Code** over SSH —
they never log in to Claude themselves — while each person is tracked and
rate-limited as their own dashboard identity, and isolated from everyone else.

```
Windows PowerShell / Terminal (person's laptop)
        │  ssh  (over Cloudflare tunnel, key auth)
        ▼
   this container ── logs in as their OWN OS account (alice, bob, …)
        │            sharing the box's Claude login
        │
        │  every prompt →  managed hook  →  limiter server (localhost:3000)
        ▼                     │
   Claude Code runs here      └─ identity derived from the OS uid, which
   using the shared login        selects WHICH dashboard user this is
```

**One OS account = one dashboard identity.** The binding is the uid itself, so
it cannot be faked from inside a session.

## Isolation model

Three things enforce it. Each closes a hole the earlier single-`dev`-account
design left open:

| Mechanism | Effect |
|---|---|
| **Identity from the uid.** `hook.js` reads the root-owned `/etc/claude-code/shared-host.json`; when `per_os_user` is set it derives `LIMITER_DIR`/`SERVER_FILE` from `os.userInfo()` and **ignores `CLAUDE_LIMITER_*` env vars** for non-root. | A person cannot repoint the limiter at a permissive server by exporting a variable in their own `.bashrc`. |
| **Root-owned keys.** `AuthorizedKeysFile /etc/ssh/authorized_keys/%u`, not `~/.ssh/authorized_keys`. | Nobody can add a key for someone else (which would let two people burn one quota) or attach options to their own key. |
| **Per-account files.** Home `0750`, cache dir `0700` owned by the person, token file `0640 root:<name>`. | Files, shell history, caches, and tokens don't leak sideways. |

Login is gated by membership in the **`claudeusers`** group (`AllowGroups`), so
adding a person needs no `sshd_config` edit.

**Root sessions bypass the limiter entirely**, so your own admin work is never
gated — consistent with the threat model (root can edit these files anyway).

## Site configuration

Hostnames are deliberately **not** in this repo — the source is published, and
committing real infrastructure names hands out a map of the deployment. The
scripts read them from `/etc/claude-code/site.env`, which is root-owned and
lives outside the working tree:

```sh
# /etc/claude-code/site.env
SSH_HOST=claude-ssh.example.com                        # make-client.sh, provision-user.sh
DASHBOARD_URL=https://claude-manager.example.com/dashboard   # start-all.sh
WEB_TERMINAL_HOST=claude-web.example.com               # web-terminal.sh hint text
CF_TEAM_DOMAIN=your-team.cloudflareaccess.com          # seeds web-terminal.json on first run
```

Every script sources it if present and falls back to a placeholder otherwise.
`make-client.sh` is the exception: it **exits** rather than emit a connection
package pointing at `example.com`, which would fail confusingly in the user's
hands. Point `SITE_ENV` elsewhere to override the path.

## What's already set up in this container

- One OS account per person, in group `claudeusers`; `sshd` on `127.0.0.1:22`,
  key-only, no root login, no `PermitUserEnvironment`.
- Each account has its own copy of the Claude credentials in
  `~/.claude/.credentials.json` (shared login, no re-login needed).
- Managed hooks at `/etc/claude-code/managed-settings.json` +
  `/etc/claude-code/limiter/hook.js` (root-owned).
- Patched hook: `shared_host:true` means the kill switch blocks a person's
  prompts **without** running `claude auth logout` (which would sign the whole
  box out).
- The old shared `dev` account is retired — it is not in `claudeusers` and has
  no authorized key, so it cannot log in.

## Add a person

1. **Dashboard** → Add User (e.g. `bob`) → set limits → copy the install code.
2. Get their **SSH public key** (they run `ssh-keygen -t ed25519` and send you
   the `.pub`).
3. On this box, as root:
   ```bash
   ./provision-user.sh bob CLM-bob-xxxxxx "ssh-ed25519 AAAA... bob@laptop"
   ```
   This creates the OS account, the key file, the cache dir, the root-owned
   token, a `/workspace/users/bob` workdir, and seeds the Claude credentials.
   Re-run with `-` instead of a code to keep the token and just update the key.

The `<name>` must match the dashboard user that owns the install code.

## Remove a person

```bash
rm -f /etc/ssh/authorized_keys/bob          # revoke access immediately
gpasswd -d bob claudeusers                  # drop the login gate
# optional, destroys their files:
# userdel -r bob && rm -rf /etc/claude-code/limiter-bob /etc/claude-code/secrets/bob.json
```

Set the dashboard user to **killed** as well if you want the server to reject
any session that is still open.

## Expose SSH through the existing Cloudflare tunnel

In the Cloudflare Zero Trust dashboard, on the **same tunnel** that serves the
dashboard, add a **Public Hostname** (Networks → Tunnels → your tunnel →
**Public Hostname** tab — not Access → Applications):

| Field | Value |
|-------|-------|
| Subdomain | `claude-ssh` |
| Domain | your domain (e.g. `example.com`) |
| Service Type | `SSH` |
| URL | `localhost:22` |

SSH key auth is the real gate. Do **not** put a browser-SSO Access application
in front of this hostname — Access intercepts the raw SSH stream and the
connection fails with `websocket: bad handshake`.

## Client setup (the remote person, once)

**Windows** — install cloudflared, then in PowerShell:
```powershell
winget install --id Cloudflare.cloudflared
```
Add to `%USERPROFILE%\.ssh\config` (note `User` is now their own name):
```
Host claude-box
    HostName claude-ssh.example.com
    User bob
    IdentityFile ~/.ssh/id_ed25519
    ProxyCommand cloudflared access ssh --hostname %h
```
Then just:
```powershell
ssh claude-box
claude            # uses the shared login, no sign-in; limits enforced as "bob"
```

macOS/Linux clients are identical (`brew install cloudflared` /
package manager), same `~/.ssh/config` block.

## Credentials drift

Every account holds its own copy of `~/.claude/.credentials.json`, and Claude
Code refreshes those copies independently. If one goes stale — or you re-login
as root — push root's current credentials back out to everyone:

```bash
sudo ./sync-credentials.sh
```

## Notes / limits of this design

- **Per-model caps** rely on the model Claude reports. Interactive `/model`
  selection is detected reliably; a scripted `claude -p --model X` may be
  mis-detected at session start. Model-agnostic **credit budgets** or total
  daily caps enforce regardless.
- **The shared Claude login is readable by each person**, because Claude Code
  has to read it as that user. Someone could copy `~/.claude/.credentials.json`
  and use the subscription off this box, outside the limiter. This is inherent
  to "share the box's login" — the only real mitigations are trusting the
  people you provision and rotating the login if someone leaves.
- After a container restart, run `sudo ./start-all.sh` to bring the server,
  tunnel, and sshd back up.
