# Term push relay

A Cloudflare Worker sends generic APNs alerts without receiving terminal text, questions, hostnames, session names or pane IDs. The phone resolves the opaque route over its existing pinned SSH connection. The independent, opt-in counter records three usage flags once per UTC receipt day, never purchase information.

Nothing here has been deployed. Real delivery needs a Cloudflare account, an APNs-enabled App ID and Apple's signing key.

## Local operation

Use Node.js 22 or later and npm:

```sh
cd relay
npm ci
npm run dev
```

Wrangler serves the Worker locally and stores local Durable Object data under `.wrangler/`. To exercise actual APNs sends locally, create the ignored `relay/.dev.vars` with these values:

```dotenv
APNS_PRIVATE_KEY="-----BEGIN PRIVATE KEY-----\n<the .p8 key body>\n-----END PRIVATE KEY-----"
APNS_KEY_ID="<Apple key ID>"
APNS_TEAM_ID="<Apple team ID>"
APNS_TOPIC="<the installed app's bundle ID>"
```

Keep the `.p8` file and `.dev.vars` private. Never commit them. A future deployment must configure these as Worker secrets, especially `APNS_PRIVATE_KEY`; this repository deliberately contains neither credentials nor a deployment command. The registered device selects `sandbox` or `production`, matching the app's signed `aps-environment` entitlement. Neither a client-supplied APNs URL nor a client-supplied topic is accepted. Missing configuration or a malformed private key returns actionable 503, not a pretend successful delivery.

Tests do not need Apple credentials or contact Apple:

```sh
npm run typecheck
npm test
```

The Vitest Cloudflare plugin runs the Worker, real SQLite Durable Objects, Web Crypto and concurrency gates in Miniflare/workerd. A localhost HTTP server receives APNs requests and provides documented success/error responses, a connection failure and a held response for the revocation race. Test signing keys are generated in memory. Test-only outbound routing cannot be selected by a production request. No test result is asserted in this README; run the commands above.

Dependency versions are pinned in `package.json` and `package-lock.json`. The [Cloudflare integration guide](https://developers.cloudflare.com/workers/testing/vitest-integration/write-your-first-test/) and [plugin configuration](https://developers.cloudflare.com/workers/testing/vitest-integration/configuration/) were checked on October 28, 2026. The Worker uses compatibility date October 13, the newest supported by the plugin's workerd binary. Miniflare is pinned to the plugin's version. Vitest's host-filesystem module cache is disabled because workerd cannot read it; modules still execute in the real Worker runtime.

## Configure the iOS build

Set the relay URL in the ignored `app/Config/Local.xcconfig`. Escape `//` for xcconfig:

```xcconfig
TERM_RELAY_URL = https:/$()/your-relay.example
```

Once the explicit App ID has Push Notifications enabled and signing profiles include it, also set:

```xcconfig
TERM_DEVICE_ENTITLEMENTS = Config/Term.entitlements
```

Run `xcodegen generate` in `app/`, then build normally. Debug uses the development entitlement; Release uses production. Device builds without this setting retain their existing signing configuration. Simulator builds include the entitlement automatically. For local simulator development, the URL can be `http:/$()/127.0.0.1:8787`.

Install `term-notify` on the host, connect once in Term to verify its SSH host key, then use Settings › Notifications to enable notifications and pair that host. Unpair revokes the relay credential before removing the host file. If a network failure leaves registration uncertain, Term retains its Keychain credential so reopening the app or turning notifications off can recover safely.

Settings › About › Send Daily Usage Count controls the counter, independently of push. It defaults off. Onboarding can enable it after consent with `UsageCounter.shared.setEnabled(true)`. Purchase status is never collected or transmitted; App Store Connect supplies payer counts. `ask_answered` requires an unmodified Return in the observed asking pane followed by that pane leaving its stop; merely opening or clearing a session does not count.


## Protocol and installation

[`src/contract.ts`](src/contract.ts) is the wire contract. All requests use JSON with exactly the documented keys; unknown keys, query parameters, malformed values, and bodies over 2,048 bytes are rejected. UUIDs must be random version-4 UUIDs. Secrets and references are lowercase hex. APNs tokens must be nonempty, even-length lowercase hex; their byte length is not assumed fixed.

| Endpoint | Request | Authority and result |
| --- | --- | --- |
| `POST /devices` | `device_id`, `device_secret`, `token`, `environment` | First registration claims a random device ID. Updates require the same secret in the body. 200 on success; 401 for a different secret; 409 if another device already owns that APNs token in that environment. |
| `DELETE /devices` | `device_id` | Device bearer secret; deletes the registration and every pairing. 204 on success; 401 if absent or unauthorized. |
| `POST /pairings` | `device_id`, `secret` | Device bearer secret; returns `pairing_id = SHA256(UTF8(secret))`. Repeating it is idempotent and does not reset the rate limit. A secret cannot belong to two devices. Pairings last until revoked or their device is deleted or expires. |
| `DELETE /pairings` | `device_id`, `secret` | Device bearer secret; 204 even if already absent, provided the device authorization is valid. |
| `POST /notify` | `secret`, `session_ref`, `kind` | Host pairing secret only. `kind` is `ask`, `approval`, `done` or `error`. 200 means Apple accepted the push, not that the phone displayed it. |
| `POST /ping` | `install_id`, `host_ok`, `screen_opened`, `ask_answered` | No push identity, purchase status or authorization. All three flags are booleans. First record wins; duplicate requests return 200 without changing flags. A `pro` field is rejected as unknown metadata. |

Management authorization is `Authorization: Bearer <device_secret>`. The host's secret cannot register pairings, update the device or delete it. Invalid metadata returns 400; wrong content type 415; oversized input 413. Notification responses are 401 for an unknown/revoked/expired pairing, 410 when the phone must register its token again, 429 with `Retry-After` for the pairing rate limit, 502 for an APNs/network error, or 503 for missing configuration or relay failure.

The phone creates separate random 32-byte device, pairing and routing secrets. Only the device secret remains phone-only. Over SSH it installs a per-host/device file at `~/.config/term/notify/<pairing_id>.json`, with directory mode 0700 and file mode 0600. The file contains the relay URL, host pairing secret and independent routing key, never the APNs token or device secret. See [`../integrations/notify/README.md`](../integrations/notify/README.md) for notifier installation and uninstall commands.

The opaque route is HMAC-SHA256 with the hex-decoded routing key over UTF-8 `[session_name, pane_id, start_time, pid].join("\0")`; the last two fields identify the tmux server. The relay does not know the routing key. On a tap the phone enumerates the host's panes through SSH and finds the matching HMAC. A stale server or missing pane must fail on the phone, never silently attach to a different pane.

## Consistency and APNs

Two SQLite Durable Objects own separate state: one push registry, one counter ledger. This intentionally favors a small, understandable store over shards and cross-object authorization races. The push registry serializes management, rate checks and the full APNs send in a concurrency gate. Sends have a 10-second network timeout. A completed revocation prevents subsequent sends; a push accepted before revocation may still appear on the phone afterward. Slow APNs requests also delay unrelated devices through this single registry, so this is not a high-throughput design.

Each pairing allows 30 attempts in a fixed 60-second window. Failed APNs attempts count. Re-pairing the same secret does not reset its window; different pairings have independent limits. Fixed windows can permit 60 attempts across a boundary, not a rolling-minute ceiling. Revocation and expiration use the same consistent registry as sends; there is no stale KV authorization cache.

The sender imports the P-256 `.p8` key and signs ES256 JWTs with Web Crypto. The exact signed JWT, issue time and a hash identifying its signing configuration are cached in Durable Object storage for reuse across eviction, with a memory fast path and renewal after 50 minutes (Apple's limit is one hour). A changed key, key ID, team or topic invalidates reuse. The private signing key remains in Worker secrets, never SQLite. Sandbox and production use Apple's fixed endpoints.

The payload contains only `aps` with title `Term`, generic body `An agent needs you` or `An agent finished`, and `term` with pairing ID, opaque route and stop kind. Expiration is one hour after submission, allowing Apple to deliver when the phone comes back online. The opaque session reference is the collapse ID, so newer alerts for that route can replace older pending alerts. Revoking a pairing does not recall an alert Apple already accepted.

`BadDeviceToken` and current `Unregistered` responses clear the stored token but retain device authorization and pairings. Only authenticated registration restores sending. An `Unregistered` timestamp older than the registration does not invalidate its newer token. Provider authorization failures, throttling, network failures and 5xx responses do not delete the registration. The relay does not retry uncertain sends, because Apple may already have accepted them. APNs acceptance is not a delivery guarantee. See [Apple's provider API](https://developer.apple.com/library/archive/documentation/NetworkingInternet/Conceptual/RemoteNotificationsPG/CommunicatingwithAPNs.html).

## Counter and retention

The app sends completed-day flags at its next active opportunity. No client date is transmitted: the relay groups by UTC **receipt day**, so late submissions are not historical daily activity measurements. The first submission for an identity/day is immutable; later flags cannot upgrade it.

An install used on only one day and never reopened sends no completed-day report. Installs and payers must come from App Store Connect; these flags measure observed returning usage, not a complete first-use funnel.

The app replaces its random install UUID monthly, independently of push registration. The server stores `SHA256(UTC receipt month + ":" + install_id)`, never the raw UUID. The counter has no device, token, pairing or route column and makes no lookup against the push registry.

The daily cron runs at 00:05 UTC. It writes daily totals for installs and each flag plus `active_7d`: distinct monthly identities with **`screen_opened OR ask_answered`** on that day or the six preceding receipt days. `host_ok` alone is not active. A person crossing a month boundary can count twice within that seven-day window, as can a reinstall. This is an active-identity count, not deduplicated people. No attempt is made to join identities across a month. Counter requests are unauthenticated; fabricated UUIDs can inflate counts. These are operational estimates, not fraud-resistant billing evidence.

Recent rollups are recomputed idempotently and recover up to seven missed daily runs while raw history remains. Longer outages lose the ability to reconstruct older days; missing historical activity must not be treated as measured zero. Aggregates live in the counter object's `rollups` table, not on a public HTTP endpoint.

| Stored data | Live-store retention |
| --- | --- |
| Random device ID, SHA-256 device-secret verifier, APNs token/environment, registration/expiry times | 90 days after authenticated device registration. Re-registration refreshes the lease; notifications alone do not. Deleting the device removes all of this immediately. |
| Pairing-secret SHA-256 ID, owning device ID, current rate window/count | Until explicit revoke, device deletion or device lease expiry. Authenticated device renewal keeps idle paired hosts working. |
| Exact signed APNs provider JWT, issue time and signing-configuration hash | Replaced after 50 minutes on the next send; expired JWTs are removed by daily cleanup. Apple accepts a JWT for at most one hour after issue. The private `.p8` key is never stored here. |
| Counter receipt day, month-scoped hashed identity, three usage flags | Current UTC date and preceding 13 dates; cleaned at daily cron. |
| Daily aggregate counts, including active identities | 90 completed UTC dates; cleaned at daily cron. No IDs or flags per install remain in these rows. |
| Session references, stop kinds, raw request bodies, request IPs, HTTP headers, raw bearer/host secrets | Not persisted by the application. Needed request fields exist transiently in memory; generic push fields go to Apple. |

Push expiration is checked on every registry request and by cron. Inactive rows are physically removed at the next daily cleanup. Counter deletion depends on the daily cron; a disabled or failing schedule extends live retention. These are application retention policies, **not an instant erasure claim**: Cloudflare SQLite [point-in-time recovery](https://developers.cloudflare.com/durable-objects/api/sqlite-storage-api/#pitr-point-in-time-recovery-api) can retain recoverable database history for 30 days after deletion. Cloudflare's infrastructure and account-level retention policies also apply. Restoring an old registry backup can restore revoked credentials; do not restore it without treating the restored pairings as compromised and re-pairing affected devices.

## Threat model

**The relay sees:** source network connections, device registration tokens, opaque device/pairing identifiers, generic stop kind and timing, stable opaque routes for the same pane/server, and anonymous counter flags. It can correlate hosts sending through the same device's pairings and repeated stops for the same route. It never needs terminal content, prompts, answers, hostnames, SSH credentials, the routing key, session names or pane IDs.

**A stolen host pairing file:** permits generic pushes and route fabrication for that one host/device pairing until revocation or expiration, constrained by its rate limit. It does not grant management authority. It contains the routing key, so a host-file attacker who already knows the session and pane can construct routes. Revoke the pairing on the phone, remove its file on the host, then pair again with fresh secrets.

**A stolen live database:** exposes APNs device tokens, device/pairing relationships, expiry/rate metadata, recent anonymous counter patterns and the cached provider JWT. That JWT is a usable Apple send credential until its one-hour validity ends; possession can bypass this relay's generic-payload and rate restrictions. Device/host secret verifiers are hashes of independent random 256-bit values; their raw secrets and the private `.p8` signing key are not in the database. A compromised running relay or Cloudflare account can additionally observe incoming secrets and IPs, alter code, recover backups, sign new provider tokens and correlate traffic. It still cannot recover terminal content never sent. Revoke Apple's key, replace relay secrets and re-pair devices after a database, runtime or account compromise.

**Transport is not anonymity:** Cloudflare necessarily handles client IP addresses and TLS metadata; Apple sees device tokens, notification payloads and timing. Timing can correlate a counter request with phone activity or a push. The relay makes no promise that these providers cannot correlate traffic. Worker Observability is disabled, and the code does not log requests, IP addresses, payloads or provider errors. Operators must not enable request-body capture, IP logging, Logpush or diagnostic tailing that defeats this policy; platform/security metadata outside this code remains under Cloudflare's policies.

**Limits:** registration is open and proves knowledge of a random secret, not device attestation or human identity. A token already registered under another device cannot be taken over through this API, but initial knowledge of an unregistered token is not ownership proof. There is no account recovery for a lost device-management secret. Reinstalling while its token remains registered may require waiting for expiry or an operator's authenticated recovery procedure; no unauthenticated takeover path is provided. No per-IP abuse database is kept. An attacker can create registrations or counter identities to consume storage and cost; per-pairing notification limits do not prevent that. This relay is a privacy-minimal transport, not end-to-end encrypted push delivery or an abuse-proof public service.
