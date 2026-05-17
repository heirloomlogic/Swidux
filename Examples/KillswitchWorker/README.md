# SwiduxKillswitch — Cloudflare Worker config endpoint

A runnable backend for `SwiduxKillswitch`. The Worker serves the JSON config
that `KillswitchService.live(endpoint:)` fetches; the config itself lives in a
Workers KV key, so you push an emergency block by writing one key — **no
redeploy, no git build.**

See the integration guide: <doc:HowToAddAVersionKillswitch> → "Hosting the JSON
config".

## What's here

- `worker.js` — reads KV key `config` (binding `KILLSWITCH`) and returns it
  verbatim with `Content-Type: application/json` and a short `Cache-Control`.
  Missing key → `{}` (fail-open: an empty `KillswitchConfig` evaluates to
  `.allowed`). Only `GET`/`HEAD`; anything else → `405`.
- `wrangler.toml` — Worker name, entry point, and the `KILLSWITCH` KV binding
  (ids are placeholders you fill in during setup).
- `killswitch.json` — a representative seed config (soft-minimum shape) you push
  into KV. Edit this and re-`put` it to change the live config.

The wire shape is `KillswitchConfig` (every field optional):
`minimumSupportedVersion`, `blockedVersions`, `blockedRanges`, `blockedTitle`,
`blockedMessage`, `updateURL`. See
`Sources/SwiduxKillswitch/KillswitchConfig.swift`.

## One-time setup

```sh
npm i -g wrangler
wrangler login

# Prints an `id` — paste it into wrangler.toml's [[kv_namespaces]].id
wrangler kv namespace create KILLSWITCH
# Prints a preview id — paste into preview_id
wrangler kv namespace create KILLSWITCH --preview
```

## Seed / flip the config (the emergency-block path)

```sh
# From this directory:
wrangler kv key put --binding=KILLSWITCH config "$(cat killswitch.json)"
```

This is the operation you run to block a bad build in seconds: edit
`killswitch.json` (or pass an inline string), re-run the `put`, done — no deploy.
The Cloudflare dashboard (Workers & Pages → KV → your namespace → edit the
`config` key) does the same thing if you don't have a terminal handy.

## Deploy

```sh
wrangler deploy
```

Note the printed `https://swidux-killswitch.<your-subdomain>.workers.dev` URL
(or attach a custom route/domain in the dashboard).

## Smoke test

```sh
curl -i https://swidux-killswitch.<your-subdomain>.workers.dev/
```

Expect `200`, `Content-Type: application/json`, a `Cache-Control` header, and a
body equal to your seeded config (or `{}` if the KV key isn't set). A `POST`
should return `405`.

## Point the app at it

```swift
// App/AppStore.swift — inside Store.configured()
service: KillswitchService.live(
    endpoint: URL(string: "https://swidux-killswitch.<your-subdomain>.workers.dev/")!,
    cacheLifetime: 900   // see the freshness note below
)
```

## Cost & limits

Free tier covers this comfortably: 100k Worker requests/day and a generous KV
read quota. The endpoint is a single KV read per request, edge-cached for the
`Cache-Control` window, so origin load stays near zero even at scale.

## Freshness: the backend can't fix client staleness

The plugin caches the fetched config for `cacheLifetime` (**default 3600s**)
*regardless of how fresh your endpoint is*. With the default, a perfectly
deployed emergency block still won't reach a launched app for up to an hour.

If fast emergency response matters:

- Lower `cacheLifetime` to ~300–900s in `KillswitchService.live(...)`.
- Dispatch `.killswitch(.forceFetch)` on app-foreground (it bypasses the
  freshness gate) so a returning user re-checks immediately.

Keep the Worker's `Cache-Control` (`max-age=300` by default in `worker.js`) at
or below your `cacheLifetime` — there's no point caching at the edge longer than
the client will re-ask.
