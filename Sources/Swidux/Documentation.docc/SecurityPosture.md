# Security Posture

What Swidux's soft controls actually guarantee, and what to do when you need a hard one.

## Overview

Several Swidux behaviors look like security controls but are deliberately not. The killswitch fails open. The parental gate is client-side arithmetic. The paywall gate is a boolean in app state. Each of those is the right default for the kind of app Swidux targets — but only if you know which is which.

This article states each by-design limit in one place: the behavior, why it is that way, and what to do instead if your threat model needs a harder guarantee. Nothing here is a bug report. Everything here is a decision, and every one of them is reversible on your side of the API.

The short version: **Swidux's remote-control and gating features are product controls, not security boundaries.** They shape what a cooperative user experiences. They do not withstand a user who controls the device — nothing client-side does. Anything you genuinely need to protect belongs behind a server you control.

## 1. The killswitch fails open

`KillswitchVerdict.evaluate` returns `.allowed` when it cannot decide, along three separate paths:

- An unparseable local version string returns `.allowed` and logs an error — the killswitch is silently inert for that install.
- No matching rule in the config falls through to `.allowed`.
- A fetch failure with no cache dispatches only `.fetchFailed`, which sets `state.fetchError` and leaves `state.verdict` untouched. `verdict` defaults to `.unknown`, and `.unknown` is not blocked.

So a device kept offline never blocks, and a device that has never once fetched a config never blocks.

**Why.** The alternative — fail closed — means a CDN outage, a DNS failure, or a bad deploy bricks every copy of your app simultaneously, including for users who are doing nothing wrong. That is a far larger and far more likely harm than an out-of-date client continuing to run. A killswitch that can take down your whole install base on a network blip is a bigger risk than the thing it protects against.

**What it is for.** Retiring versions with a broken API contract, forcing an upgrade past a data-corrupting bug, sunsetting a backend. It is an *update nudge with teeth*, and it works because the overwhelming majority of users are not adversaries.

**If you need a hard guarantee.** Enforce it server-side. Have the backend reject requests from client versions you have retired, and let the killswitch handle the UI. The client-side blocker then becomes a courtesy — it explains the failure instead of causing it. That way an offline client gets no data, which is the actual enforcement, and a cooperative client gets a clear message.

## 2. The parental gate is an intent gate

`ParentalGatePlugin` compares the submitted answer to `challenge.expected`, which lives in client state. The arithmetic challenge is small by design. And `ParentalGateAction` is a public enum, so `.answerAccepted(reason:)` can be dispatched directly by any code holding the store — landing straight in the handler that inserts into `passedReasons`, with no challenge involved.

There *is* real hardening around the honest path: reaching the attempt limit starts a cooldown, and during cooldown answers are refused even when correct, so the cooldown itself cannot be waited out by guessing. Two things it does not do. A wrong answer is counted through an effect, so `attempts` rises a main-actor turn later than the submission — a *synchronous burst* of `.submitAnswer` dispatches is therefore all evaluated against one challenge before the first rejection is counted. And none of it constrains a direct `.answerAccepted` dispatch. Both are bypasses available to your own code, not to a user tapping the screen, and code that can do either can do the simpler one.

**Why.** This gate exists to satisfy App Review's requirement that a child cannot casually stumble into an external link, a purchase flow, or an age-inappropriate destination. Apple's guidance is explicitly about intent, not cryptography: the barrier needs to be beyond a small child's ability, not beyond an adult's. Anything stronger — a server round trip, a real credential — makes the app worse for the parent it is meant to serve.

**If you need a hard guarantee.** You are describing account-level parental controls, not a gate: a real adult identity, verified server-side, with the restricted capability enforced by the backend rather than hidden by the UI. Consider Apple's Family Controls and Screen Time APIs, or Ask to Buy for purchases, all of which are enforced outside your process.

## 3. The paywall gate is client state

`PaywallState.isGateSatisfied` is `isPro || hasPermanentLicense`. Both operands are plain public `var`s on a struct that lives in app state, settable by any code that holds it. The gate reflects what the entitlement provider last said; it does not prove it.

`ResilientPaywallService` deliberately widens this: it vouches for a cached last-known-good entitlement while the provider is unreachable, so a transient network failure never presents a paying user as free. Its *Threat model* section spells out what the cache does and does not defend against — back it with `KeychainKeyValueStore` rather than `UserDefaults`, because a plist is user-editable and restorable from a doctored backup. See <doc:HowToAddAPaywall> and <doc:PluginPaywallReference>.

**Why.** Client-side entitlement state is what makes the UI fast and correct offline. A paid user on a plane must keep their features. The cost of that is that the same state is forgeable on a device someone fully controls — and no client-side design fixes it, because the attacker owns the process. Obfuscation only raises the effort; it does not change the outcome.

**If you need a hard guarantee.** Validate server-side. Anything with real marginal cost — server compute, model inference, licensed content, a shared quota — must check entitlement at the point of service, using the receipt or provider webhook, not the client's opinion of itself. Use `isGateSatisfied` to decide what the UI offers, and your backend to decide what it delivers. For purely local features, the client gate is proportionate and fine.

## 4. `KeychainKeyValueStore` is for opaque identifiers, not secrets

The store is built for anonymous device identity that should survive reinstall — a UUID that lets analytics correlate sessions in an app with no accounts. It uses the data-protection keychain and never triggers a user-facing prompt, precisely *because* it requests no `kSecAttrAccessControl`: no Touch ID, Face ID, or password challenge. The default accessibility is `afterFirstUnlockThisDeviceOnly`, so items stay readable in the background and are excluded from iCloud Keychain sync and device migration.

**Why.** The type is tuned for things that must be silently readable at launch, on a background wake, before any user interaction. Biometric gating is incompatible with that access pattern by construction.

**If you need a hard guarantee.** For material that genuinely warrants a user presence check — an auth token, a decryption key, anything whose disclosure is a real loss — request the Keychain directly with a `SecAccessControl` specifying `.userPresence` or `.biometryCurrentSet`, and choose a stricter accessibility class such as `whenPasscodeSetThisDeviceOnly`. That is a different access pattern with a different API, and it should be, so don't route it through this store's `Codable` convenience surface.

## 5. The SwiftData store has no explicit file-protection class

`ContainerFactory.makeContainer` is the single point of `ModelContainer` construction, and it sets no file-protection attribute on the on-disk paths. The store inherits the platform default — on iOS, complete-until-first-user-authentication.

**Why.** The default is right for the common case: a persisted store must be readable by background refresh, by a widget timeline reload, and by a notification service extension, all of which can run while the device is locked. Raising protection to `.complete` makes those paths fail with I/O errors that surface as data loss, not as a clear permission error.

**If you need a hard guarantee.** If your rows are sensitive enough that at-rest protection on a locked, seized device matters, set `NSFileProtectionComplete` on the store URL yourself and confirm nothing in your app touches the store while locked — no background tasks, no extensions, no widget reloads. Because `ContainerFactory` is the only place a configuration is built, you have exactly one place to intervene: pass an explicit `url` and apply the protection attribute to it before the container opens.

## 6. Remote config is trusted infrastructure

Both remote-config channels — the killswitch and feature flags — are hardened in transit and against malformed or hostile payloads:

- **HTTPS is enforced by precondition**, not by convention, regardless of the host app's ATS settings. Plain `http` is permitted only for `localhost` / `127.0.0.1` development servers.
- **Responses are capped at 1 MB** (`1_000_000` bytes) and the cap is enforced *during* transfer: the status is checked before the body is read, a declared `Content-Length` over the cap is rejected outright, and otherwise bytes accumulate chunk by chunk with the transfer aborted the moment the count exceeds the limit. The process never buffers a hostile payload whole. Both channels share one implementation (`BoundedResponse`) rather than a copy each — a size guard that exists twice is one a fix can be applied to once.
- **Config-side versions parse strictly** as full `major.minor.patch`, while the app's own `CFBundleShortVersionString` parses leniently — a deliberate asymmetry, since you control the config but not the shape of a marketing version string.
- **Update URLs are scheme-allowlisted** to `https`, `itms-apps`, and `macappstore`. A config carrying any other scheme yields no openable URL, and the blocker renders without an Update button rather than with a dead one.

What none of that changes: **the blocker's title and message are arbitrary remote-controlled text rendered over a non-dismissible, interaction-disabling overlay.** Whoever can write your config can display whatever they like, full-screen, with the app unusable behind it.

**Why.** That is the feature. A blocker you cannot dismiss is the only kind that works, and copy has to be editable without an app release or you cannot explain an outage as it unfolds.

**What to do.** Treat the config endpoint as production infrastructure with the same care as your deploy pipeline: locked-down write access, change review, and an audit trail. The transport is protected; the *authority* is whoever can publish to that URL. If that set of people is larger than the set who can ship a release, the killswitch is the weaker link.

### 6a. The killswitch cache is a second input path, and it is on disk

The endpoint is not the only way a config becomes a verdict. `KillswitchService.live` persists the last successful fetch and reads it back on any fetch failure — including the very first one, so an app launched offline that has *never* fetched anything still evaluates whatever is on disk. A file that decodes is a verdict.

Two things narrow that path:

- The cache lives in a **bundle-scoped subdirectory** of the caches directory, not at a fixed shared filename. This matters on a non-sandboxed macOS build, where `.cachesDirectory` is `~/Library/Caches` for the whole user account: an unscoped name meant every Swidux app read every other's blocked verdict. On iOS, and on a sandboxed macOS app, the caches directory is already per-container.
- The cached payload **records the endpoint it came from**, and a payload written for a different one reads as absent. Repointing your endpoint invalidates the cache rather than inheriting it.

**What that does not do.** It is not an authenticated file. On a platform where the caches directory isn't sandboxed, a process running as the user can write it, and one that knows your endpoint URL can put a `blocked` verdict there. There is no client-side fix — a key shipped in the binary is a key the same process can read.

**If you need a hard guarantee.** The same answer as §6: enforce retirement server-side and let the blocker explain it. An attacker who can write files as your user has already won on a desktop; what this scoping buys you is that ordinary co-installed apps, and your own earlier endpoints, cannot block you by accident.

## 7. The dev services log publicly, on purpose

`ConsoleAnalyticsService` logs the analytics user ID and full property bags at `privacy: .public` to the unified log. `SimulatedPaywallService` grants entitlements with nothing charged and no receipt.

Both are supported in Release builds so TestFlight and QA can exercise the real pipelines without an SDK or a vendor commitment — and both emit `logger.fault` at init in Release as a submission tripwire, loud and greppable in Console and a sysdiagnose during submission prep.

**Why.** Deferring the vendor decision is a stated goal: you should be able to build, ship internally, and validate an entire analytics or paywall integration before choosing a provider. Public logging is what makes that debuggable, so it is deliberate rather than accidental — and the tripwire is the guardrail that keeps a deliberate development choice from becoming an accidental shipping one.

**Before you submit.** Check for both faults in a Release build and swap in real services. Replacing them is the usual two-line change in `Store.configured()`. See <doc:HowToAddAnalytics> and <doc:HowToAddAPaywall>.

## Topics

### Related

- <doc:DesignPrinciples>
- <doc:HowToAddAVersionKillswitch>
- <doc:HowToAddAParentalGate>
- <doc:HowToAddAPaywall>
- <doc:KeyValueStoreGuide>
