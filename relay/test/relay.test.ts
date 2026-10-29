import { env } from "cloudflare:workers";
import { reset, runInDurableObject, createScheduledController } from "cloudflare:test";
import { beforeEach, afterEach, describe, expect, it, vi } from "vitest";
import worker, { type Env as RelayEnv, PushRegistry, type CounterLedger } from "../src/index";
import { ApnsSender } from "../src/apns";
import { DAY, REGISTRATION_TTL, RATE_LIMIT } from "../src/limits";

// All handlers, SQL, cryptography and DO gates run in workerd; only Apple is a local HTTP server.
declare global {
  namespace Cloudflare {
    interface Env extends RelayEnv { APNS_TEST: Fetcher; APNS_PUBLIC_KEY: string }
  }
}

const device = {
  device_id: "123e4567-e89b-42d3-a456-426614174000", device_secret: "a".repeat(64),
  token: "b".repeat(64), environment: "sandbox" as const,
};
const pairing = { device_id: device.device_id, secret: "c".repeat(64) };
const notification = { secret: pairing.secret, session_ref: "d".repeat(64), kind: "ask" };
const ping = {
  install_id: "223e4567-e89b-42d3-a456-426614174000", host_ok: true,
  screen_opened: false, ask_answered: false,
};
const registry = () => env.PUSH_REGISTRY.get(env.PUSH_REGISTRY.idFromName("primary"));
const counter = () => env.COUNTER_LEDGER.get(env.COUNTER_LEDGER.idFromName("primary"));

async function request(path: string, body: unknown, method = "POST", secret?: string, headers?: HeadersInit) {
  const allHeaders = new Headers(headers);
  allHeaders.set("content-type", "application/json");
  if (secret) allHeaders.set("authorization", `Bearer ${secret}`);
  return worker.fetch(new Request(`https://relay.test${path}`, { method, headers: allHeaders, body: JSON.stringify(body) }), env);
}

async function configure(reply: Record<string, unknown> = {}) {
  await env.APNS_TEST.fetch("http://control/_configure", { method: "POST", body: JSON.stringify(reply) });
}

async function records(): Promise<{ url: string; headers: Record<string, string>; body: unknown }[]> {
  return (await env.APNS_TEST.fetch("http://control/_records")).json();
}

async function register() {
  expect((await request("/devices", device)).status).toBe(200);
  const response = await request("/pairings", pairing, "POST", device.device_secret);
  expect(response.status).toBe(200);
  return (await response.json() as { pairing_id: string }).pairing_id;
}

beforeEach(async () => {
  await reset();
  vi.useFakeTimers({ toFake: ["Date"] });
  vi.setSystemTime(new Date("2026-10-15T12:00:00Z"));
  await configure();
});
afterEach(() => { vi.useRealTimers(); });

describe("device and pairing authority", () => {
  it("rejects device-secret replacement and APNs token takeover by another device ID", async () => {
    await register();
    expect((await request("/devices", { ...device, device_secret: "e".repeat(64), token: "f".repeat(64) })).status).toBe(401);
    expect((await request("/devices", { ...device, device_id: "323e4567-e89b-42d3-a456-426614174000" })).status).toBe(409);
    await runInDurableObject<PushRegistry, void>(registry(), (_instance, state) => {
      expect(state.storage.sql.exec("SELECT token FROM devices").one()).toEqual({ token: device.token });
    });
    expect((await request("/devices", { ...device, token: "f".repeat(64), environment: "production" })).status).toBe(200);
    expect((await request("/notify", notification)).status).toBe(200);
    expect((await records())[0].url).toBe(`https://api.push.apple.com/3/device/${"f".repeat(64)}`);
  });

  it("keeps the host secret separate from device management authorization", async () => {
    await register();
    for (const secret of [undefined, pairing.secret, "f".repeat(64)]) {
      expect((await request("/pairings", pairing, "POST", secret)).status).toBe(401);
      expect((await request("/pairings", pairing, "DELETE", secret)).status).toBe(401);
      expect((await request("/devices", { device_id: device.device_id }, "DELETE", secret)).status).toBe(401);
    }
    expect((await request("/notify", { ...notification, secret: device.device_secret })).status).toBe(401);
    expect((await request("/notify", notification)).status).toBe(200);
  });

  it("revokes only the selected host and deletes all pairings with a device", async () => {
    await register();
    const second = { ...pairing, secret: "e".repeat(64) };
    expect((await request("/pairings", second, "POST", device.device_secret)).status).toBe(200);
    expect((await request("/pairings", pairing, "DELETE", device.device_secret)).status).toBe(204);
    expect((await request("/pairings", pairing, "DELETE", device.device_secret)).status).toBe(204);
    expect((await request("/notify", notification)).status).toBe(401);
    expect((await request("/notify", { ...notification, secret: second.secret })).status).toBe(200);
    expect((await request("/devices", { device_id: device.device_id }, "DELETE", device.device_secret)).status).toBe(204);
    expect((await request("/notify", { ...notification, secret: second.secret })).status).toBe(401);
    await runInDurableObject<PushRegistry, void>(registry(), (_instance, state) => {
      expect(state.storage.sql.exec("SELECT * FROM devices").toArray()).toEqual([]);
      expect(state.storage.sql.exec("SELECT * FROM pairings").toArray()).toEqual([]);
    });
  });

  it("serializes revocation behind an in-flight APNs send and prevents later sends", async () => {
    await register();
    await configure({ hold: true });
    const sending = request("/notify", notification);
    await env.APNS_TEST.fetch("http://control/_wait");
    const revoking = request("/pairings", pairing, "DELETE", device.device_secret);
    // workerd's input gate and the held TCP response use real dispatch, not Vitest timers.
    // Observe the absence of an early revoke response before releasing the network request.
    const deadline = Promise.withResolvers<"pending">();
    const timer = setTimeout(() => deadline.resolve("pending"), 100);
    const ordering = await Promise.race([revoking.then(() => "revoked"), deadline.promise]);
    clearTimeout(timer);
    await env.APNS_TEST.fetch("http://control/_release");
    expect(ordering).toBe("pending");
    expect((await sending).status).toBe(200);
    expect((await revoking).status).toBe(204);
    expect((await request("/notify", notification)).status).toBe(401);
    expect(await records()).toHaveLength(1);
  });

  it("keeps an idle pairing while its device registration is renewed", async () => {
    await register();
    const start = Date.now();
    vi.setSystemTime(start + REGISTRATION_TTL - 1);
    expect((await request("/devices", device)).status).toBe(200);
    vi.setSystemTime(start + REGISTRATION_TTL);
    expect((await request("/notify", notification)).status).toBe(200);
    await runInDurableObject<PushRegistry, void>(registry(), (_instance, state) => {
      expect(state.storage.sql.exec("SELECT COUNT(*) AS count FROM devices").one()).toEqual({ count: 1 });
      expect(state.storage.sql.exec("SELECT COUNT(*) AS count FROM pairings").one()).toEqual({ count: 1 });
    });
  });

  it("expires registrations at the exact boundary and removes their host pairings", async () => {
    await register();
    const start = Date.now();
    vi.setSystemTime(start + REGISTRATION_TTL - 1);
    expect((await request("/notify", notification)).status).toBe(200);
    vi.setSystemTime(start + REGISTRATION_TTL);
    expect((await request("/notify", notification)).status).toBe(401);
    await runInDurableObject<PushRegistry, void>(registry(), (_instance, state) => {
      expect(state.storage.sql.exec("SELECT COUNT(*) AS count FROM devices").one()).toEqual({ count: 0 });
      expect(state.storage.sql.exec("SELECT COUNT(*) AS count FROM pairings").one()).toEqual({ count: 0 });
    });
  });
});

describe("strict privacy boundary", () => {
  it("rejects additional metadata before any notification or counter write (strict-guard mutation target)", async () => {
    await register();
    for (const field of ["hostname", "question", "terminal", "ip", "device_id", "routing_key", "date", "metadata"]) {
      expect((await request("/notify", { ...notification, [field]: "sensitive" })).status).toBe(400);
      expect((await request("/ping", { ...ping, [field]: "sensitive" })).status).toBe(400);
    }
    expect(await records()).toEqual([]);
    await runInDurableObject<CounterLedger, void>(counter(), (_instance, state) => {
      expect(state.storage.sql.exec("SELECT * FROM pings").toArray()).toEqual([]);
    });
  });

  it("rejects wrong shapes, missing keys, content-bearing refs, invalid kinds and query metadata", async () => {
    await register();
    for (const body of [null, [], {}, { ...notification, kind: "working" }, { ...notification, session_ref: "host:private-session:%1" }, { ...notification, secret: "short" }]) {
      expect((await request("/notify", body)).status).toBe(400);
    }
    expect((await request("/ping", { ...ping, host_ok: 1 })).status).toBe(400);
    expect((await request("/ping?ip=1.2.3.4", ping)).status).toBe(400);
    expect((await request("/notify", { ...notification, text: "x".repeat(2048) })).status).toBe(413);
    expect((await worker.fetch(new Request("https://relay.test/notify", { method: "POST", body: "{}" }), env)).status).toBe(415);
    expect((await worker.fetch(new Request("https://relay.test/notify", { method: "POST", headers: { "content-type": "application/json" }, body: "{" }), env)).status).toBe(400);
  });

  it("stores neither raw secrets, routing refs, request headers nor a push-counter association", async () => {
    await register();
    const privateHeaders = { "cf-connecting-ip": "203.0.113.40", "x-forwarded-for": "198.51.100.20", "user-agent": "private-agent" };
    expect((await request("/notify", notification, "POST", undefined, privateHeaders)).status).toBe(200);
    expect((await request("/ping", ping, "POST", undefined, privateHeaders)).status).toBe(200);
    const stored = await runInDurableObject<PushRegistry, string>(registry(), (_instance, state) => JSON.stringify({
      devices: state.storage.sql.exec("SELECT * FROM devices").toArray(),
      pairings: state.storage.sql.exec("SELECT * FROM pairings").toArray(),
    }));
    const counted = await runInDurableObject<CounterLedger, string>(counter(), (_instance, state) => JSON.stringify({
      schema: state.storage.sql.exec("SELECT name, sql FROM sqlite_master WHERE type='table'").toArray(),
      pings: state.storage.sql.exec("SELECT * FROM pings").toArray(),
    }));
    for (const forbidden of [device.device_secret, pairing.secret, notification.session_ref, ...Object.values(privateHeaders)]) {
      expect(stored).not.toContain(forbidden);
      expect(counted).not.toContain(forbidden);
    }
    for (const forbidden of [device.device_id, device.token, ping.install_id, "device_id", "pairing_id"]) expect(counted).not.toContain(forbidden);
  });
});

describe("APNs and rate boundaries", () => {
  it("signs and caches valid ES256 JWTs and sends only the generic wire payload", async () => {
    const pairingId = await register();
    expect((await request("/notify", notification)).status).toBe(200);
    expect((await request("/notify", { ...notification, kind: "done" })).status).toBe(200);
    const sent = await records();
    expect(sent[0].body).toEqual({ aps: { alert: { title: "Term", body: "An agent needs you" }, sound: "default" }, term: { pairing_id: pairingId, session_ref: notification.session_ref, kind: "ask" } });
    expect(sent[1].body).toEqual({ aps: { alert: { title: "Term", body: "An agent finished" }, sound: "default" }, term: { pairing_id: pairingId, session_ref: notification.session_ref, kind: "done" } });
    expect(sent[0].headers["apns-topic"]).toBe("dev.term.tests");
    expect(sent[0].headers["apns-push-type"]).toBe("alert");
    expect(sent[0].headers["apns-expiration"]).toBe("1792069200");
    expect(sent[0].headers["apns-collapse-id"]).toBe(notification.session_ref);
    expect(sent[0].headers.authorization).toBe(sent[1].headers.authorization);
    const [header, payload, signature] = sent[0].headers.authorization.slice(7).split(".");
    const decode = (text: string) => Uint8Array.from(atob(text.replace(/-/g, "+").replace(/_/g, "/")), character => character.charCodeAt(0));
    expect(JSON.parse(new TextDecoder().decode(decode(header)))).toEqual({ alg: "ES256", kid: "TESTKEY123" });
    expect(JSON.parse(new TextDecoder().decode(decode(payload)))).toEqual({ iss: "TESTTEAM12", iat: 1792065600 });
    const publicDer = env.APNS_PUBLIC_KEY.replace(/-----BEGIN PUBLIC KEY-----|-----END PUBLIC KEY-----|\s/g, "");
    const publicKey = await crypto.subtle.importKey("spki", decode(publicDer), { name: "ECDSA", namedCurve: "P-256" }, false, ["verify"]);
    expect(await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, publicKey, decode(signature), new TextEncoder().encode(`${header}.${payload}`))).toBe(true);
    vi.setSystemTime(Date.now() + 2_999_000);
    expect((await request("/notify", notification)).status).toBe(200);
    expect((await records())[2].headers.authorization).toBe(sent[0].headers.authorization);
    vi.setSystemTime(Date.now() + 1000);
    expect((await request("/notify", notification)).status).toBe(200);
    expect((await records())[3].headers.authorization).not.toBe(sent[0].headers.authorization);
  });

  it("reuses the exact persisted provider token after sender recreation and invalidates changed keys", async () => {
    const pairingId = await register();
    expect((await request("/notify", notification)).status).toBe(200);
    const original = (await records())[0].headers.authorization;
    await runInDurableObject<PushRegistry, void>(registry(), async (_instance, state) => {
      const restarted = new ApnsSender(env, state.storage);
      expect(await restarted.send(device.token, "sandbox", Date.now(), pairingId, { ...notification, kind: "ask" })).toBe("accepted");
    });
    expect((await records())[1].headers.authorization).toBe(original);
    vi.setSystemTime(Date.now() + 3_000_000);
    await runInDurableObject<PushRegistry, void>(registry(), async (_instance, state) => {
      const expired = new ApnsSender(env, state.storage);
      expect(await expired.send(device.token, "sandbox", Date.now(), pairingId, { ...notification, kind: "ask" })).toBe("accepted");
    });
    const renewed = (await records())[2].headers.authorization;
    expect(renewed).not.toBe(original);
    await runInDurableObject<PushRegistry, void>(registry(), async (_instance, state) => {
      const changed = new ApnsSender({ ...env, APNS_KEY_ID: "NEWKEY1234" }, state.storage);
      expect(await changed.send(device.token, "sandbox", Date.now(), pairingId, { ...notification, kind: "ask" })).toBe("accepted");
    });
    expect((await records())[3].headers.authorization).not.toBe(renewed);
  });

  it("limits each pairing at 30 attempts, survives concurrent requests, and resets exactly after 60 seconds", async () => {
    await register();
    const replies = await Promise.all(Array.from({ length: RATE_LIMIT + 1 }, () => request("/notify", notification)));
    expect(replies.filter(reply => reply.status === 200)).toHaveLength(30);
    expect(replies.filter(reply => reply.status === 429)).toHaveLength(1);
    expect(replies.find(reply => reply.status === 429)!.headers.get("retry-after")).toBe("60");
    expect((await request("/pairings", pairing, "POST", device.device_secret)).status).toBe(200);
    expect((await request("/notify", notification)).status).toBe(429);
    vi.setSystemTime(Date.now() + 59_999);
    const limited = await request("/notify", notification);
    expect(limited.status).toBe(429);
    expect(limited.headers.get("retry-after")).toBe("1");
    expect((await request("/pairings", { ...pairing, secret: "e".repeat(64) }, "POST", device.device_secret)).status).toBe(200);
    expect((await request("/notify", { ...notification, secret: "e".repeat(64) })).status).toBe(200);
    vi.setSystemTime(Date.now() + 1);
    expect((await request("/notify", notification)).status).toBe(200);
  });

  it.each([{ status: 403, reason: "InvalidProviderToken" }, { status: 429, reason: "TooManyRequests" }, { status: 500, reason: "InternalServerError" }, { disconnect: true }])(
    "preserves registration and consumes the attempt when APNs fails: %j", async reply => {
      await register();
      await configure(reply);
      expect((await request("/notify", notification)).status).toBe(502);
      await runInDurableObject<PushRegistry, void>(registry(), (_instance, state) => {
        expect(state.storage.sql.exec("SELECT token FROM devices").one()).toEqual({ token: device.token });
        expect(state.storage.sql.exec("SELECT attempts FROM pairings").one()).toEqual({ attempts: 1 });
      });
      await configure();
      expect((await request("/notify", notification)).status).toBe(200);
    },
  );

  it.each([{ status: 400, reason: "BadDeviceToken" }, { status: 410, reason: "Unregistered" }])(
    "disables invalid APNs tokens until authenticated re-registration: %j", async reply => {
      await register();
      await configure(reply);
      expect((await request("/notify", notification)).status).toBe(410);
      expect((await request("/notify", notification)).status).toBe(410);
      expect(await records()).toHaveLength(1);
      await configure();
      expect((await request("/devices", { ...device, token: "e".repeat(64) })).status).toBe(200);
      expect((await request("/notify", notification)).status).toBe(200);
    },
  );

  it("does not invalidate a registration newer than APNs's Unregistered timestamp", async () => {
    await register();
    await configure({ status: 410, reason: "Unregistered", timestamp: Date.now() - 1 });
    expect((await request("/notify", notification)).status).toBe(502);
    await configure();
    expect((await request("/notify", notification)).status).toBe(200);
    await configure({ status: 410, reason: "Unregistered", timestamp: Date.now() });
    expect((await request("/notify", notification)).status).toBe(410);
  });

  it("reports missing signing configuration without contacting Apple", async () => {
    await runInDurableObject<PushRegistry, void>(registry(), async (_instance, state) => {
      const sender = new ApnsSender({}, state.storage);
      expect(await sender.send(device.token, "sandbox", Date.now(), "e".repeat(64), { ...notification, kind: "ask" })).toBe("unconfigured");
    });
    expect(await records()).toEqual([]);
  });

  it("reports a malformed private key as actionable configuration failure, even after a valid cached token", async () => {
    await register();
    expect((await request("/notify", notification)).status).toBe(200);
    await configure();
    await runInDurableObject<PushRegistry, void>(registry(), async (_instance, state) => {
      const malformed = new PushRegistry(state, { ...env, APNS_PRIVATE_KEY: "not a private key" });
      const response = await malformed.fetch(new Request("https://internal/notify", {
        method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(notification),
      }));
      expect(response.status).toBe(503);
      expect(await response.json()).toEqual({ error: "Configure the relay APNs key, key ID, team ID and topic." });
    });
    expect(await records()).toEqual([]);
  });
});

describe("anonymous daily counter", () => {
  it("rejects purchase status instead of accepting or storing it", async () => {
    for (const pro of [false, true]) {
      expect((await request("/ping", { ...ping, pro })).status).toBe(400);
    }
    await runInDurableObject<CounterLedger, void>(counter(), (_instance, state) => {
      expect(state.storage.sql.exec("SELECT * FROM pings").toArray()).toEqual([]);
    });
    expect((await request("/ping", ping)).status).toBe(200);
  });

  it("makes daily flags immutable under concurrent retries", async () => {
    expect((await request("/ping", ping)).status).toBe(200);
    await Promise.all(Array.from({ length: 5 }, () => request("/ping", { ...ping, screen_opened: true, ask_answered: true })));
    await runInDurableObject<CounterLedger, void>(counter(), (_instance, state) => {
      expect(state.storage.sql.exec("SELECT day, host_ok, screen_opened, ask_answered FROM pings").toArray()).toEqual([
        { day: "2026-10-15", host_ok: 1, screen_opened: 0, ask_answered: 0 },
      ]);
    });
  });

  it("rolls up UTC receipt days, counting active identities only for screen_opened OR ask_answered", async () => {
    vi.setSystemTime(new Date("2026-10-08T23:59:59Z"));
    await request("/ping", { ...ping, install_id: "523e4567-e89b-42d3-a456-426614174000", screen_opened: true });
    vi.setSystemTime(new Date("2026-10-09T23:59:59Z"));
    await request("/ping", { ...ping, screen_opened: true });
    vi.setSystemTime(new Date("2026-10-15T23:59:59Z"));
    await request("/ping", { ...ping, ask_answered: true });
    await request("/ping", { ...ping, install_id: "323e4567-e89b-42d3-a456-426614174000" });
    await request("/ping", { ...ping, install_id: "423e4567-e89b-42d3-a456-426614174000", screen_opened: true });
    vi.setSystemTime(new Date("2026-10-16T00:00:00Z"));
    await request("/ping", ping);
    await worker.scheduled(createScheduledController(), env);
    await worker.scheduled(createScheduledController(), env);
    await runInDurableObject<CounterLedger, void>(counter(), (_instance, state) => {
      expect(state.storage.sql.exec("SELECT * FROM rollups WHERE day = '2026-10-15'").one()).toEqual({ day: "2026-10-15", installs: 3, host_ok: 3, screen_opened: 1, ask_answered: 1, active_7d: 2 });
      expect(state.storage.sql.exec("SELECT * FROM rollups WHERE day = '2026-10-16'").toArray()).toEqual([]);
    });
  });

  it("separates a reused UUID at a month boundary and reports identity, not person, counts", async () => {
    vi.setSystemTime(new Date("2026-10-31T12:00:00Z"));
    await request("/ping", { ...ping, screen_opened: true });
    vi.setSystemTime(new Date("2026-11-01T12:00:00Z"));
    await request("/ping", { ...ping, screen_opened: true });
    vi.setSystemTime(new Date("2026-11-02T00:05:00Z"));
    await counter().rollup();
    await runInDurableObject<CounterLedger, void>(counter(), (_instance, state) => {
      const rows = state.storage.sql.exec("SELECT identity FROM pings ORDER BY day").toArray();
      expect(rows).toHaveLength(2);
      expect(rows[0].identity).not.toBe(rows[1].identity);
      expect(state.storage.sql.exec("SELECT active_7d FROM rollups WHERE day='2026-11-01'").one()).toEqual({ active_7d: 2 });
    });
  });

  it("deletes raw rows after 14 calendar days and aggregate rows after 90 completed days", async () => {
    await runInDurableObject<CounterLedger, void>(counter(), (_instance, state) => {
      state.storage.sql.exec("INSERT INTO pings VALUES ('2026-10-01', 'expired', 1, 1, 0), ('2026-10-02', 'retained', 1, 1, 0)");
      state.storage.sql.exec("INSERT INTO rollups VALUES ('2026-07-16',1,1,1,0,1), ('2026-07-17',1,1,1,0,1)");
    });
    await counter().rollup();
    await runInDurableObject<CounterLedger, void>(counter(), (_instance, state) => {
      expect(state.storage.sql.exec("SELECT day FROM pings ORDER BY day").toArray()).toEqual([{ day: "2026-10-02" }]);
      expect(state.storage.sql.exec("SELECT day FROM rollups WHERE day < '2026-10-01' ORDER BY day").toArray()).toEqual([{ day: "2026-07-17" }]);
    });
    vi.setSystemTime(Date.now() + DAY);
    await counter().rollup();
    await runInDurableObject<CounterLedger, void>(counter(), (_instance, state) => {
      expect(state.storage.sql.exec("SELECT * FROM pings").toArray()).toEqual([]);
    });
  });
});
