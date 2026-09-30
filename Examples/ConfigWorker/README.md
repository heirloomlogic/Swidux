# Config Worker — killswitch + feature flags, one endpoint

A runnable backend that serves remote config for **every app in the portfolio**
from a single Cloudflare Worker backed by Workers KV. It answers both Swidux
plugins:

- `SwiduxKillswitch` — `KillswitchService.live(endpoint:)` GETs `KillswitchConfig` JSON.
- `SwiduxFeatureFlags` — `HTTPFeatureFlagsService(url:)` GETs `FeatureFlagsConfig` JSON.

Config lives in KV, so you push a change by editing one key — **no redeploy, no
git build, no per-app Worker.** Onboarding a new app is just adding its KV keys.

> **Migrating from the old single-app `KillswitchWorker`?** The URL shape
> changed: the endpoint is now `…/<appID>/<resource>`, not `…/`. Re-point your
> app and reseed under the new key names (below).

See the integration guides: <doc:HowToAddAVersionKillswitch> and
<doc:HowToAddFeatureFlags>.

## The routing model

```
GET /<appID>/<resource>   ->   KV key  "<appID>/<resource>"

GET /counter/killswitch   ->   KV key  "counter/killswitch"   (KillswitchConfig)
GET /counter/flags        ->   KV key  "counter/flags"        (FeatureFlagsConfig)
GET /                      ->   "swidux-config: ok"  (health target)
```

- `appID` is a lowercase slug of up to 64 characters (`^[a-z0-9][a-z0-9-]{0,63}$`). `resource` is `killswitch` or `flags`. Anything else → `404`, so a typo'd resource in an app's URL shows up as a fetch error instead of a config that can never block anyone. `GET`/`HEAD` only; else `405`.
- **Missing key → type-aware fail-open default**, so a not-yet-seeded app is never blocked and never breaks decode:
  - `killswitch` → `{}` (empty `KillswitchConfig` = `.allowed`)
  - `flags` → `{"version":1,"flags":{}}` (valid v1, no flags)
- **A KV read error → `503`, `Cache-Control: no-store`**, never the type-aware
  default — serving the "no rules" default on a KV outage would be
  indistinguishable from an intentional one, lifting an active killswitch
  block or wiping cached flags. Both client plugins treat a non-2xx response
  as a failure and fall back to whatever they already have cached, so a KV
  blip degrades to "use the cache," not "no rules."
- Per-resource `Cache-Control` header: `killswitch` `max-age=60`, `flags` `max-age=300`. Swidux clients ignore it, because both plugins request with `.reloadIgnoringLocalCacheData`. It matters to browsers, curl, and intermediary caches, and to Cloudflare only if you turn on Workers Caching (see "Cost & limits").

## What's here

- `worker.js` — the router above. Reads `env.CONFIG.get("<appID>/<resource>")`.
- `wrangler.toml` — Worker name (`swidux-config`) and the `CONFIG` KV binding
  (ids are placeholders you fill in during setup).
- `seeds/<appID>/<resource>.json` — representative seed configs you push into KV. `seeds/counter/killswitch.json` is `{}` — "no rules yet," safe to copy as-is for a new app; the library has no "soft" minimum, so the actual force-update shape lives only in DEPLOY.md's incident runbook, never in a seed you'd copy by habit. `seeds/counter/flags.json` mirrors the Counter example's flags.

Wire shapes: `KillswitchConfig` (`Sources/SwiduxKillswitch/KillswitchConfig.swift`)
and `FeatureFlagsConfig` (`Sources/SwiduxFeatureFlags/FeatureFlagsConfig.swift`).

## One-time setup

```sh
npm i -g wrangler
wrangler login

# Prints an `id` — paste into wrangler.toml's [[kv_namespaces]].id
wrangler kv namespace create CONFIG
# Prints a preview id — paste into preview_id
wrangler kv namespace create CONFIG --preview
```

## Seed / flip a value (the operational path)

```sh
# From this directory — key is "<appID>/<resource>":
wrangler kv key put --binding=CONFIG --remote --preview false counter/killswitch --path seeds/counter/killswitch.json
wrangler kv key put --binding=CONFIG --remote --preview false counter/flags      --path seeds/counter/flags.json

# Read it back from the production namespace:
wrangler kv key get --binding=CONFIG --remote --preview false --text counter/killswitch
```

Both flags are required. Without `--remote`, wrangler writes to local development storage, prints `Resource location: local`, and changes nothing in production. Because `wrangler.toml` sets both `id` and `preview_id`, wrangler refuses to write until `--preview false` (production) or `--preview` (preview) picks one. `--preview false` on its own still writes locally and exits 0. The read-back is how you confirm a flip actually landed.

**The "one place" you actually use day to day:** Cloudflare dashboard →
Workers & Pages → KV → the `CONFIG` namespace. Keys sort alphabetically, so
they group by app (`counter/flags`, `counter/killswitch`, `nextapp/…`). Click a
key, edit the JSON blob, save. That's the emergency block and the flag flip —
no terminal, no redeploy, no hunting for which URL belongs to which app.

## Deploy

```sh
wrangler deploy
```

Note the printed `https://swidux-config.<your-subdomain>.workers.dev` URL (or attach a custom route/domain in the dashboard). One URL for the whole portfolio.

If you attach a custom domain, set `workers_dev = false` in `wrangler.toml` and redeploy. Zone rules such as rate limiting apply only to your domain, so the workers.dev URL would otherwise stay open as a second way in.

## Smoke test

```sh
host=https://swidux-config.<your-subdomain>.workers.dev
curl -i $host/                      # 200 text/plain "swidux-config: ok"
curl -i $host/counter/killswitch    # 200 application/json, max-age=60
curl -i $host/counter/flags         # 200 application/json, max-age=300
curl -i $host/counter               # 404 (needs <appID>/<resource>)
curl -i $host/counter/other         # 404 (only killswitch and flags)
curl -i -X POST $host/counter/killswitch   # 405
```

A seeded key returns its blob verbatim; an unseeded one returns the type-aware
default above.

## Point the apps at it

```swift
// AppStore.swift — inside Store.configured()
let host = "https://swidux-config.<your-subdomain>.workers.dev"

// Killswitch
service: KillswitchService.live(
    endpoint: URL(string: "\(host)/counter/killswitch")!,
    cacheLifetime: 900   // see the freshness note below
)

// Feature flags
service: HTTPFeatureFlagsService(url: URL(string: "\(host)/counter/flags")!)
```

Each app uses its own `appID`; nothing else differs.

## Cost & limits

Cloudflare doesn't cache a Worker's responses unless you enable Workers Caching (`[cache] enabled = true` in `wrangler.toml`), and this example doesn't. Every request invokes the Worker, and every request for `killswitch` or `flags` reads KV. If you do enable Workers Caching, the `max-age` values above become how long a flip can take to reach clients. The free tier's 100k Worker requests/day and generous KV read quota cover a portfolio comfortably under normal app traffic, but neither this Worker nor the free tier rate-limits an individual caller: a script looping `GET /<random>/<random>` burns through the daily request quota, after which the Worker errors for the rest of the UTC day (clients that already hold a cached killswitch verdict or flags config are unaffected — they keep what they have; see "the fail-closed behavior on KV errors" under "The routing model" above). If that's a real risk for your deployment, add a Cloudflare zone rate-limiting rule for the config host, or move to a paid plan.

## Freshness: the backend can't fix client staleness

A KV write can take 60 seconds or more to reach every Cloudflare location. After that, what decides whether an app sees a flip is when the app asks again, not the Worker.

- A cold launch always asks the network. The plugin's freshness window lives in memory, so it starts empty on every launch.
- A running app goes back to the network only when something dispatches `.forceFetch`, or `.fetch` once `cacheLifetime` has passed. With one `.fetch` in the root view's `.task`, nothing dispatches either while that view stays on screen, so a running app doesn't re-check however long it runs.
- Dispatch `.killswitch(.forceFetch)` when the app returns to the foreground. That is what gets an emergency block to apps that are already running.
- `cacheLifetime` (default 3600s) only decides whether a repeated `.fetch` goes to the network or reuses the cached config. Lower it (300–900s, say) if you re-dispatch `.fetch` on a timer or on foreground instead of `.forceFetch`.

For the shared-deployment ops convention (org naming, onboarding a new app,
incident runbook), see `DEPLOY.md`.
