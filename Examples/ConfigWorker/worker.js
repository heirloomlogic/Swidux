// Shared config endpoint — one Cloudflare Worker, backed by Workers KV,
// serving killswitch + feature-flag (+ arbitrary future) config for every app
// in a portfolio.
//
// Route: GET /<appID>/<resource>  ->  KV key `<appID>/<resource>`
//   e.g.  GET /counter/killswitch ->  KV key "counter/killswitch"
//         GET /counter/flags     ->  KV key "counter/flags"
//
// The contract each Swidux plugin expects is unchanged: a plain GET that
// returns the resource's config-shaped JSON. SwiduxKillswitch decodes
// `KillswitchConfig`; SwiduxFeatureFlags' HTTPFeatureFlagsService decodes
// `FeatureFlagsConfig`. Both are fail-open, so a not-yet-seeded app must get a
// *decodable* default rather than an error (see DEFAULTS below).
//
// Onboarding a new app = adding its KV keys in the dashboard. No redeploy, no
// new Worker, no new URL. See README.md / DEPLOY.md.

// Route grammar: exactly `/<slug>/<slug>`, lowercase, each segment ≤ 64 chars.
// One anchored regex keeps the KV key space exactly `<slug>/<slug>` — no
// traversal, no injection, no `//`/trailing-slash aliases, and no key long
// enough to trip KV's 512-byte key limit (an oversized `get()` key throws).
const ROUTE = /^\/([a-z0-9][a-z0-9-]{0,63})\/([a-z0-9][a-z0-9-]{0,63})$/;

// Type-aware fail-open defaults for a key that isn't seeded yet. `{}` decodes
// to an allow-everyone KillswitchConfig; the flags default decodes to a valid
// v1 config with no flags. Unknown resources fall back to `{}`.
// `__proto__: null` so an attacker-shaped resource like "constructor" can't
// resolve up Object.prototype and defeat the `?? FALLBACK` chain.
const DEFAULTS = {
  __proto__: null,
  killswitch: "{}",
  flags: '{"version":1,"flags":{}}',
};
const FALLBACK = "{}";

// Per-resource Cache-Control header, honored by the *requesting client*
// (URLSession, a browser) — Cloudflare's CDN does not cache Worker responses,
// so this is not an edge cache. Killswitch is the incident lever — keep its
// hint short so a client that respects it re-fetches sooner. (The client's
// own `cacheLifetime` still dominates effective propagation either way; see
// README "Freshness".)
const CACHE_CONTROL = {
  __proto__: null,
  killswitch: "public, max-age=60",
  flags: "public, max-age=300",
};
const DEFAULT_CACHE_CONTROL = "public, max-age=300";

export default {
  async fetch(request, env) {
    // Read-only public config — only GET/HEAD make sense.
    if (request.method !== "GET" && request.method !== "HEAD") {
      return new Response("Method Not Allowed", {
        status: 405,
        headers: { Allow: "GET, HEAD" },
      });
    }

    const path = new URL(request.url).pathname;

    // Health target for smoke tests / uptime monitors.
    if (path === "/") {
      return new Response("swidux-config: ok\n", {
        headers: { "Content-Type": "text/plain" },
      });
    }

    // Expect exactly `/<appID>/<resource>`.
    const match = ROUTE.exec(path);
    if (!match) {
      return new Response("Not Found", { status: 404 });
    }
    const [, appID, resource] = match;

    // A KV read failure is not "unseeded" — serving the type-aware default
    // here would be indistinguishable from an intentional "no rules yet",
    // which would lift an active killswitch block or wipe every client's
    // cached feature flags for the KV outage's duration (both plugins treat
    // a 200 response as authoritative and overwrite their disk cache with
    // it). Fail closed instead: 503 + no-store tells the client "this
    // answer isn't authoritative, don't cache it, try again" — clients that
    // already hold a cached verdict/config keep it rather than treating an
    // empty response as the truth.
    let stored;
    try {
      stored = await env.CONFIG.get(`${appID}/${resource}`);
    } catch {
      return new Response("Service Unavailable", {
        status: 503,
        headers: { "Cache-Control": "no-store" },
      });
    }

    const body = stored ?? DEFAULTS[resource] ?? FALLBACK;

    return new Response(body, {
      headers: {
        "Content-Type": "application/json",
        "Cache-Control": CACHE_CONTROL[resource] ?? DEFAULT_CACHE_CONTROL,
      },
    });
  },
};
