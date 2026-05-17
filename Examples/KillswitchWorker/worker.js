// SwiduxKillswitch config endpoint — Cloudflare Worker backed by Workers KV.
//
// SwiduxKillswitch's `KillswitchService.live(endpoint:)` issues a plain GET and
// JSON-decodes the body into `KillswitchConfig`. That's the entire contract:
// return KillswitchConfig-shaped JSON. Every field is optional; `{}` means
// "allow everyone".
//
// Config lives in a KV namespace (binding `KILLSWITCH`, key `config`), so you
// push an emergency block by writing one KV key — no redeploy. See README.md.

const KV_KEY = "config";

// Tune to taste. The iOS client also caches `cacheLifetime` (default 3600s),
// so the *effective* propagation delay is roughly max(this, cacheLifetime).
// Keep this short so a config flip reaches edge caches fast; lower the client's
// `cacheLifetime` (and/or `.forceFetch` on foreground) for fast blocks.
const CACHE_CONTROL = "public, max-age=300";

export default {
  async fetch(request, env) {
    // Read-only public config — only GET/HEAD make sense.
    if (request.method !== "GET" && request.method !== "HEAD") {
      return new Response("Method Not Allowed", {
        status: 405,
        headers: { Allow: "GET, HEAD" },
      });
    }

    // Missing key => `{}`. This mirrors the plugin's fail-open semantics:
    // an empty config evaluates to `.allowed`, so a never-seeded namespace
    // never accidentally blocks anyone.
    const body = (await env.KILLSWITCH.get(KV_KEY)) ?? "{}";

    return new Response(body, {
      headers: {
        "Content-Type": "application/json",
        "Cache-Control": CACHE_CONTROL,
      },
    });
  },
};
