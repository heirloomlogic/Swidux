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
<appID>/<future>       arbitrary JSON            (room to grow; defaults to {})
```

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
   wrangler kv key put --binding=CONFIG <appID>/killswitch "$(cat seeds/<appID>/killswitch.json)"
   wrangler kv key put --binding=CONFIG <appID>/flags      "$(cat seeds/<appID>/flags.json)"
   ```
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
3. Save. Mirror it back into `seeds/<appID>/killswitch.json` and commit so the
   repo stays the source of truth.

**Propagation = max(edge cache, client `cacheLifetime`).** Edge cache for
`killswitch` is `max-age=60`; the *client* default is 3600s and dominates. For
a real emergency lever, ship apps with `cacheLifetime` ~300–900s and a
`.killswitch(.forceFetch)` on foreground (see README "Freshness").

## What this Worker deliberately is not

- **No write API.** Writes go through the dashboard or `wrangler` only — the
  Worker is read-only public config (`GET`/`HEAD`). Nothing to authenticate,
  nothing to abuse.
- **No per-user logic.** Flag bucketing is client-side in the plugin; the Worker
  just serves the config document. Keep it dumb; that's why it never needs a
  redeploy.
