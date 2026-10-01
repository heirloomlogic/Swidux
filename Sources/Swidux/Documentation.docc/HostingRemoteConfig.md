# Host Remote Config

Build the endpoint that serves killswitch and feature-flag config, so that it fails safe, can't be cheaply exhausted, and passes a conformance checklist.

## Overview

`KillswitchService.live` and `HTTPFeatureFlagsService` each fetch config with a plain HTTPS `GET`. Any server that answers that request correctly works: a static object behind a CDN, a serverless function over a key-value store, your own backend. <doc:HowToAddAVersionKillswitch#Where-to-host-it> compares the options.

Swidux doesn't ship a server. This article covers what the clients expect from one and the decisions that shape it, and ends with a checklist to run against whatever you build. Most of it applies to any host. Where it names a platform, it uses Cloudflare Workers with Workers KV as the example.

## How the clients read a response

Both clients behave the same way:

- The URL must be HTTPS. Plain `http` is allowed only for `localhost` and `127.0.0.1`.
- Requests use `reloadIgnoringLocalCacheData`, so the device's URL cache is never consulted.
- The whole transfer must finish within the service's `fetchTimeout` (10 seconds by default), and the body must stay under 1 MB.
- A **2xx response whose body decodes** replaces the client's cached config, and the client persists it as the new last-known-good.
- **Anything else** keeps the last-known-good config: a non-2xx status, a transport error, a timeout, an oversized body, or a body that doesn't decode. With nothing cached, the killswitch stays unblocked and every flag reads its Swift default.

So the status code decides whether the client changes anything. A 2xx with a decodable body is an instruction to replace the config; everything else means "keep what you have". The server's job is to send a 2xx only when it knows the answer.

## Choose the response for each case

| Case | Response |
|---|---|
| Config is stored | `200`, the stored JSON exactly as stored |
| Known app, nothing stored yet | `200` with the empty config, plus `X-Config-Source: default` |
| The store failed or timed out | `503`, non-JSON body, `Cache-Control: no-store` |
| The stored value isn't a JSON object | `502`, non-JSON body, `Cache-Control: no-store` |
| Unknown resource, or a malformed path | `404` |
| Unknown app ID | `404`, without reading the store |
| Any method other than `GET` or `HEAD` | `405` |

**Never answer a storage failure with a default.** `{}` decodes as an allow-everyone `KillswitchConfig`, and `{"version":1,"flags":{}}` decodes as a config with no flags. Served with a 200 during an outage, either replaces every client's cache: active killswitch blocks lift and remote flags revert to their defaults, all at once. Return a non-2xx instead. Make the body non-JSON too, so it can't decode even if a client ignores the status.

**Serve an empty config only when you know nothing is stored.** For a known app, a 200 default means "no rules yet", which is correct. The empty killswitch config is `{}`; the empty flags config is `{"version":1,"flags":{}}`. Add `X-Config-Source: default`: in debug builds, both clients log a warning for a 2xx carrying it, because it usually means the app ID in the URL is wrong. Marking the other cases (`kv`, `error`, `invalid`, or your own names) costs nothing and makes `curl -i` answer "is this key really seeded?".

**Return 404 for resources you don't serve.** A server that answers any path with `200 {}` turns a typo in a shipped URL (`/<appID>/kill-switch`) into a killswitch that decodes as allow-everyone and can never fire. A 404 keeps the client on its cache and logs `HTTP 404`, which is how you find the typo.

## Constrain the URL space

- **Pick each app ID once.** It is baked into the URLs of every build you ship, so it can never change. Use a lowercase slug, not a bundle ID.
- **Accept one spelling per resource.** Match the whole path against a strict pattern, such as `^/[a-z0-9][a-z0-9-]{0,63}/[a-z0-9][a-z0-9-]{0,63}$`. Reject double slashes, trailing slashes, and uppercase rather than normalizing them, so each config has exactly one URL.
- **Bound every segment.** Key-value stores cap key length (Workers KV allows 512 bytes), and an oversized key can throw. A request should never be able to produce a 5xx.
- **Don't look path segments up in a plain JavaScript object.** `constructor` and `__proto__` resolve through the prototype. Use a `Map`, an explicit allowlist, or an object created with a `null` prototype.

## Validate config before publishing

The clients fail open on rules they can't parse, so a config that decodes can still do nothing. Check every value against the client's rules before it reaches the store:

- **Killswitch versions are strict `MAJOR.MINOR.PATCH`.** `"1.5"`, `"v1.5.0"`, and `" 1.5.0"` are skipped as unparseable, and a skipped rule never blocks. See <doc:PluginKillswitchReference#Verdict-evaluation-rules>.
- **A misspelled killswitch key decodes as an absent rule.** `minimumSupportedVerison` produces a config with no minimum, and only debug builds log it. Reject keys `KillswitchConfig` doesn't declare.
- **`updateURL` must be `https`, `itms-apps`, or `macappstore`.** The plugin won't open any other scheme.
- **Flags documents have `version: 1`.** Never bump it on an endpoint that shipped builds read; see <doc:PluginFeatureFlagsReference#Schema-evolution>. A rollout outside 0–100 or variant weights that don't sum to 100 reject the whole document, which keeps clients on stale config.
- **Parse strictly.** Reject duplicate keys, which JSON parsers resolve differently, as well as byte-order marks, `NaN`, and trailing data.

Keep the source of truth in version control, one file per app and resource, so every change has a diff and a known-good value to restore.

## Onboard apps safely

- **Start every app with an empty killswitch config.** Never copy an incident config as a template: a `minimumSupportedVersion` above the version you ship blocks every user of the new app.
- **Seed before you ship.** If the server rejects unknown app IDs (see below), a killswitch can't reach the app until its ID is listed.
- **Onboarding shouldn't need a redeploy.** Keep the list of app IDs and their config in the store, not in the server's code, so adding an app is a data write.

## Keep the endpoint available

A killswitch matters most during an incident, and the endpoint is public and unauthenticated. Anything that costs money or quota per request can be used against it.

- **Serve from one origin.** Disable alternate hostnames such as a platform's default subdomain (`workers_dev = false` on Cloudflare), so edge rules can't be sidestepped through a second URL.
- **Reject unknown app IDs before reading config.** Otherwise each request for `/<random-slug>/flags` misses every cache and costs a billable read. Keep an allowlist of app IDs in the store, cache it in memory, and refresh it about once a minute. If the allowlist is missing or malformed, disable the check rather than returning 404 for every app, because a 404 for every app makes every killswitch undeliverable. If reading it fails and no copy is cached, return 503.
- **Filter and rate-limit at the edge.** A rule that runs before your code (a WAF custom rule, a rate-limiting rule) costs nothing per blocked request. Block methods and paths no client sends, and limit each IP to a small burst, such as 10 requests per 10 seconds. A client makes a few requests per launch. A blocked client gets a 429, keeps its last-known-good config, and picks up the change on its next fetch. Devices behind one NAT share a counter.
- **Bound each storage read.** Time out a hung read (3 seconds, say) and return 503, so a slow store can't hold requests open.

### Plans with a daily cap

Some hosting plans meter by the day. Cloudflare Workers Free allows 100,000 Worker requests and 100,000 KV reads per day, shared across the account and reset at 00:00 UTC. Past either limit, config stops reaching apps until the reset. Apps keep their last-known-good config, so nothing breaks on screen, but a new killswitch block can't be delivered.

- **On a capped plan,** the allowlist and a per-IP rate limit keep any single IP below the cap. At 10 requests per 10 seconds, one IP can make at most 86,400 requests a day. Two IPs can still exhaust the allowance, and so can one IP plus the account's other traffic. Choose this plan only if losing killswitch delivery for the rest of a UTC day is an acceptable worst case.
- **On a metered plan with no daily cap** (Workers Paid), the same flood becomes a usage bill instead of an outage. Keep the edge rules anyway; they bound the bill.

Check your provider's current limits and pricing before you decide.

## Make writes verifiable

- **Confirm a write reached production.** Some CLIs default to local or preview storage: in Wrangler 4, `wrangler kv key put` writes to local storage and exits 0 unless you pass `--remote`. After every write, `GET` the URL and compare.
- **Show a plan before applying.** Read the live values, print which keys will be created, updated, or left alone, and confirm. A live value may be an incident edit nobody has copied back to version control yet.
- **Check for drift.** Compare live config with the source of truth on a schedule, so an emergency dashboard edit doesn't silently become the permanent config.
- **Log storage failures on the server.** The clients fail open and stay quiet, so a broken config channel is invisible unless the server records it.

Changes don't reach running apps instantly, however fast the server is. See <doc:HowToAddAVersionKillswitch#Freshness-the-backend-cant-fix-client-staleness> for the client side. Keep any server-side cache in front of killswitch reads short, such as a 60-second `cacheTtl` on a Workers KV read. `Cache-Control` doesn't affect Swidux clients, but it does control intermediary caches such as a CDN in front of a static object.

## Conformance checklist

Set `host` to your endpoint and `app` to a seeded, listed app ID, then run each check. Some checks can only run against your handler in tests, because you can't force a storage outage in production.

```sh
host=https://config.example.com
app=example
```

**Serving**

- `curl -i $host/$app/killswitch` returns `200` with the stored JSON, byte for byte.
- `curl -i $host/$app/flags` returns `200` with a `version: 1` document.
- A known app with nothing stored returns `200`, the empty config for that resource, and `X-Config-Source: default`.
- `curl -i -X POST $host/$app/flags` returns `405`, or is blocked at the edge.

**Failure (in tests)**

- A storage read that throws returns `503` with a non-JSON body and `Cache-Control: no-store`. Never `200`.
- A storage read that hangs returns `503` within your timeout.
- A stored value that isn't a JSON object returns a non-2xx with a non-JSON body.

**URL space**

- `curl -i $host/$app/kill-switch` returns `404`, not `200 {}`.
- `curl -i $host/$app/constructor` and `curl -i $host/$app/__proto__` return `404`.
- `curl -i "$host//$app//killswitch"`, `curl -i $host/$app/killswitch/`, and an uppercase app ID return `404`.
- `curl -i "$host/$(printf 'a%.0s' $(seq 600))/flags"` returns `404`, never a 5xx.

**Availability**

- `curl -i $host/not-listed/flags` returns `404`, and the server's logs or metrics show no config read for it.
- Any alternate hostname for the service (a platform default subdomain) doesn't serve config.
- A burst above the rate limit from one IP gets `429`, then recovers after the window.

**Publishing**

- The validator rejects `"1.5"`, `minimumSupportedVerison`, a duplicate key, and a flags document with `version: 2`.
- A write through your publishing tool is visible at the production URL within the propagation window.
- A newly onboarded app's killswitch is `{}`, and a debug build of the app shows no `remoteconfig` or `killswitch` warning in Console.

## See Also

- <doc:HowToAddAVersionKillswitch>
- <doc:HowToAddFeatureFlags>
- <doc:PluginKillswitchReference>
- <doc:PluginFeatureFlagsReference>
