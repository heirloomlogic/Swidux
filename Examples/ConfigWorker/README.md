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

- `appID` and `resource` are lowercase slugs (`^[a-z0-9][a-z0-9-]*$`). Anything
  else → `404`. `GET`/`HEAD` only; else `405`.
- **Missing key → type-aware fail-open default**, so a not-yet-seeded app is
  never blocked and never breaks decode:
  - `killswitch` → `{}` (empty `KillswitchConfig` = `.allowed`)
  - `flags` → `{"version":1,"flags":{}}` (valid v1, no flags)
  - any other resource → `{}`
- **A KV read error → `503`, `Cache-Control: no-store`**, never the type-aware
  default — serving the "no rules" default on a KV outage would be
  indistinguishable from an intentional one, lifting an active killswitch
  block or wiping cached flags. Both client plugins treat a non-2xx response
  as a failure and fall back to whatever they already have cached, so a KV
  blip degrades to "use the cache," not "no rules."
- Per-resource `Cache-Control` header: `killswitch` `max-age=60` (it's the
  incident lever), `flags`/other `max-age=300`. This is a hint to the
  *requesting client* (`URLSession`, a browser) — see "Cost & limits" below
  for why it is not an edge cache.

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
wrangler kv key put --binding=CONFIG counter/killswitch "$(cat seeds/counter/killswitch.json)"
wrangler kv key put --binding=CONFIG counter/flags      "$(cat seeds/counter/flags.json)"
```

**The "one place" you actually use day to day:** Cloudflare dashboard →
Workers & Pages → KV → the `CONFIG` namespace. Keys sort alphabetically, so
they group by app (`counter/flags`, `counter/killswitch`, `nextapp/…`). Click a
key, edit the JSON blob, save. That's the emergency block and the flag flip —
no terminal, no redeploy, no hunting for which URL belongs to which app.

## Deploy

```sh
wrangler deploy
```

Note the printed `https://swidux-config.<your-subdomain>.workers.dev` URL (or
attach a custom route/domain in the dashboard). One URL for the whole portfolio.

## Smoke test

```sh
host=https://swidux-config.<your-subdomain>.workers.dev
curl -i $host/                      # 200 text/plain "swidux-config: ok"
curl -i $host/counter/killswitch    # 200 application/json, max-age=60
curl -i $host/counter/flags         # 200 application/json, max-age=300
curl -i $host/counter               # 404 (needs <appID>/<resource>)
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

Cloudflare's CDN does **not** cache Worker responses — the `Cache-Control` header above is a hint to the requesting client (`URLSession`, a browser), not an edge cache. Every request invokes the Worker and reads KV. The free tier's 100k Worker requests/day and generous KV read quota cover a portfolio comfortably under normal app traffic, but neither this Worker nor the free tier rate-limits an individual caller: a script looping `GET /<random>/<random>` burns through the daily request quota, after which the Worker errors for the rest of the UTC day (clients that already hold a cached killswitch verdict or flags config are unaffected — they keep what they have; see "the fail-closed behavior on KV errors" under "The routing model" above). If that's a real risk for your deployment, add a Cloudflare zone rate-limiting rule for the config host, or move to a paid plan.

## Freshness: the backend can't fix client staleness

The killswitch plugin caches the fetched config for `cacheLifetime`
(**default 3600s**) regardless of how fresh the endpoint is. With the default, a
perfectly deployed emergency block still won't reach an already-launched app for
up to an hour. If fast emergency response matters:

- Lower `cacheLifetime` to ~300–900s in `KillswitchService.live(...)`.
- Dispatch `.killswitch(.forceFetch)` on app-foreground (it bypasses the
  freshness gate) so a returning user re-checks immediately.

Keep the Worker's edge `Cache-Control` (`killswitch` is `max-age=60` in
`worker.js`) at or below the client `cacheLifetime` — caching longer at the edge
than the client will re-ask buys nothing.

For the shared-deployment ops convention (org naming, onboarding a new app,
incident runbook), see `DEPLOY.md`.
