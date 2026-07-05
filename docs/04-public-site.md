# 04 - The public PalBox site (Cloudflare)

A read-only, Access-gated copy of the dashboard's player views (Pals / Paldeck / Eggs / Effigy +
Spawn maps). Each player signs in with Cloudflare Access (email allowlist + one-time PIN) and the
Worker serves **only their own** data. Runs free on Cloudflare.

## How it's split

- A static **"shell"** (`index.html`, `_worker.js`, portraits, icons, and the rarely-changing
  `effigies.json` + `pal-species.json` ...) is deployed to **Cloudflare Pages** -- rarely, only
  when the UI changes.
- The frequently-changing **per-player data** (pals/paldeck/eggs/effigies/settings) lives in a
  **Cloudflare R2 bucket** bound to the Pages project, and is pushed there by `sync_public_data.ps1`
  on the Manager's poll cadence -- **no Pages deploy needed**, so it stays far under the free
  deploy cap while refreshing every few minutes.

The Worker (`site_src/_worker.js`) gates which R2 key each authenticated user may read, and
proxies the paldb.cc map tiles + spawn data (which need a server-side `Referer`).

## One-time Cloudflare setup

1. **Domain on Cloudflare.** You need a domain using Cloudflare DNS (the public site lives at a
   subdomain like `palbox.yourdomain.com`).
2. **Pages project (Direct Upload).** Create a Pages project (note its name). Add your subdomain
   as a **custom domain** on the project. (The Access policy binds to the hostname, so it must be
   the custom domain.)
3. **R2 bucket** (private, no public access). Then **bind it to the Pages project**:
   Pages project -> Settings -> Functions -> **R2 bucket bindings** -> add variable name **`DATA`**
   (production) pointing at your bucket. The binding takes effect on the next Pages deploy.
4. **Cloudflare Access** (Zero Trust): create a **self-hosted application** on your subdomain,
   policy = email allowlist + one-time PIN. From Zero Trust you'll need two values for the Worker:
   - **Team domain** (`<team>.cloudflareaccess.com`) -- Zero Trust -> Settings.
   - **Application Audience (AUD) Tag** (64-hex) -- Access -> Applications -> your app -> Overview.
5. **Wrangler auth** (env vars, never in a file): create an API token with **`Cloudflare Pages:Edit`**
   AND **`Workers R2 Storage:Edit`**, then set, as user environment variables:
   ```powershell
   setx CLOUDFLARE_API_TOKEN  "your-token"
   setx CLOUDFLARE_ACCOUNT_ID "your-account-id"
   ```
   `npm i -g wrangler` if you haven't.

## Configure the repo

Copy `config.example.ps1` -> `config.ps1` and set `$PagesProject` + `$R2Bucket`. That's it for
the repo -- the Worker's identity is **not** in any file; it comes from Pages environment variables.

## Worker identity (Cloudflare Pages environment variables)

The Worker reads who's-who from the environment, so no emails/GUIDs live in the repo. Set these on
the Pages project -> **Settings -> Environment variables -> Production** (values are JSON):

| Variable | Example value |
|---|---|
| `ALLOWED_HOSTS` | `["palbox.yourdomain.com"]` |
| `ADMINS` | `["you@yourdomain.com"]` (these emails see every player) |
| `EMAIL_TO_GUID` | `{"friend@example.com":"0123456789ABCDEF0123456789ABCDEF"}` |
| `TEAM_DOMAIN` | `your-team.cloudflareaccess.com` |
| `ACCESS_AUD` | `your-64-hex-aud-tag` |

The 32-hex GUID is the player's save folder name under `Pal\Saved\SaveGames\0\<world>\Players`
(uppercase); a player must have logged into the server at least once to exist. Environment-variable
changes take effect on the **next deploy** (`deploy_public_site.ps1 -Force`).

> **Fail-closed:** if `TEAM_DOMAIN`/`ACCESS_AUD` are wrong or unset, JWT verification fails and
> *everyone* (including admin) sees empty data. A bug here is an outage, not a leak -- roll back via
> Pages -> Deployments.

## Deploy + sync (two distinct operations)

```powershell
# DATA change (new save data -> R2). No Pages deploy. The Manager runs this every poll.
& .\sync_public_data.ps1 -Force

# SHELL change (you edited the dashboard UI or _worker.js). Manual, rare.
node --check .\site_src\_worker.js          # syntax-check the Worker first
& .\deploy_public_site.ps1 -Force           # builds the shell + wrangler pages deploy
```

- `gen_public_site.ps1` builds the static shell in `public\` by reading `dashboard.html`
  directly and transforming it read-only.
- `deploy_public_site.ps1` regenerates + `wrangler pages deploy`s the shell (republishes the Worker).
- `sync_public_data.ps1` builds the frequent per-player data and uploads **only changed files** to
  R2; it self-gates (exits if the save is unchanged), so it's cheap to run every poll.

## Auto-cadence

There's no scheduled task. The Manager's dashboard poll (every 300s) launches
`sync_public_data.ps1` detached. So the **Manager must be running** for auto-syncs. Want tighter
than ~5-min freshness? Lower the poll interval in the Manager.

## Per-user scoping (how it stays private)

Cloudflare Access authenticates every request and passes a signed JWT. The Worker
**cryptographically verifies** it (RS256 against the team JWKS, plus `aud`/`iss`/`exp` checks) and
maps the email to a player GUID (or admin). Only a fully valid token yields a scope; anything else
resolves to empty data. Direct access to the internal `all/**` or `by-player/**` keys is 403'd, and
`*.pages.dev` is host-locked so the data is reachable only through the Access-gated domain.

## Verify

Log in via your subdomain and confirm: admin sees all players; a scoped player sees only their own
Pals + maps. From outside Access, `your-subdomain/` returns **302** (Access login) and the bare
`*.pages.dev` returns **403** (host lockdown). If everyone (incl. admin) sees empty data, re-check
the R2 `DATA` binding and `TEAM_DOMAIN`/`ACCESS_AUD`. Fast rollback: Pages -> Deployments ->
"Rollback to this deployment".
