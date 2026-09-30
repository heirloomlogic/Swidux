# Shared config Worker — operations guide

`README.md` is the per-clone tutorial (set up, seed, point one app at it). This
file is the **portfolio operating convention**: one Worker, one KV namespace,
serving every app you ship. It is the answer to "I just want one place to
update a value and not track down commands or URLs."

## The single source of truth

- **One Worker** (`swidux-config`) and **one KV namespace** (`CONFIG`) for the
  entire portfolio. Do not create per-app Workers or namespaces.
- **One URL base**: `https://swidux-config.<subdomain>.workers.dev` (or a
  custom domain, e.g. `https://config.example.com`). Every app's endpoints
  are paths under it — there is never a second URL to remember.
- **The control plane is the Cloudflare KV dashboard.** Workers & Pages → KV →
  `CONFIG`. Keys sort alphabetically and read as `<appID>/<resource>`, so the
  whole portfolio is one alphabetised list grouped by app. Editing a value is:
  open the namespace, click the key, edit JSON, save.

## Key-naming convention

```
<appID>/killswitch     KillswitchConfig          (gate / force-update)
<appID>/flags          FeatureFlagsConfig        (rollouts, variants, values)
```

The Worker serves only these two resources and answers `404` for anything else. A new resource means adding it to `RESOURCES` in `worker.js` and redeploying.

- `appID` is the app's stable slug (lowercase, `[a-z0-9-]`). Pick it once and
  keep it forever — it's baked into the shipped app's endpoint URLs.
- Keep the canonical JSON for each key in `seeds/<appID>/<resource>.json` in
  this repo so there's a reviewable history and a known-good to paste back.

## Onboarding a new app (no redeploy)

1. Choose its `appID`.
2. Add `seeds/<appID>/killswitch.json` and `seeds/<appID>/flags.json` (copy
   `seeds/counter/*` as a starting point), commit.
3. Seed the keys — dashboard, or:
   ```sh
   wrangler kv key put --binding=CONFIG --remote --preview false <appID>/killswitch --path seeds/<appID>/killswitch.json
   wrangler kv key put --binding=CONFIG --remote --preview false <appID>/flags      --path seeds/<appID>/flags.json
   ```
   Keep both flags: without `--remote` the write goes to local development storage and production never sees it (README "Seed / flip a value").
4. In the app's `Store.configured()`, point the plugins at
   `…/<appID>/killswitch` and `…/<appID>/flags`.

No `wrangler deploy`, no new Worker, no DNS. An unseeded key already serves the
safe fail-open default, so step 3 is not even blocking for launch — it just
means "no rules yet."

## Incident runbook — block a bad build

1. Dashboard → KV → `CONFIG` → `<appID>/killswitch`.
2. Set the gate, e.g.:
   ```json
   {
     "minimumSupportedVersion": "1.4.1",
     "blockedTitle": "Update required",
     "blockedMessage": "Please update to keep using <App>.",
     "updateURL": "https://apps.apple.com/app/idXXXXXXXXX"
   }
   ```
3. Save. To do it from a terminal instead, put the JSON in `seeds/<appID>/killswitch.json` and run `wrangler kv key put --binding=CONFIG --remote --preview false <appID>/killswitch --path seeds/<appID>/killswitch.json`. Either way, `wrangler kv key get --binding=CONFIG --remote --preview false --text <appID>/killswitch` shows what production now holds.
4. Mirror it into `seeds/<appID>/killswitch.json` if you used the dashboard, and commit so the repo stays the source of truth.

**How fast a block lands depends on when each app asks, not on the Worker.** The Worker reads KV on every request (this example doesn't enable Workers Caching), and a KV write can take 60 seconds or more to reach every Cloudflare location. Swidux clients ignore the `Cache-Control` header. A cold launch always fetches. A running app goes back to the network only on `.forceFetch`, or on a `.fetch` once `cacheLifetime` has passed. For a real emergency lever, ship apps that dispatch `.killswitch(.forceFetch)` on foreground (see README "Freshness").

## What this Worker deliberately is not

- **No write API.** Writes go through the dashboard or `wrangler` only — the
  Worker is read-only public config (`GET`/`HEAD`). Nothing to authenticate,
  nothing to abuse.
- **No per-user logic.** Flag bucketing is client-side in the plugin; the Worker
  just serves the config document. Keep it dumb; that's why it never needs a
  redeploy.
