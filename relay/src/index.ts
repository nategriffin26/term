import { DurableObject } from "cloudflare:workers";
import { ApnsSender, type ApnsEnvironment } from "./apns";
import type { CounterPing, DeviceRegistration, NotifyRequest, PairingRegistration } from "./contract";
import { DAY, REGISTRATION_TTL, RAW_COUNTER_DAYS, ROLLUP_DAYS, RATE_LIMIT, RATE_WINDOW } from "./limits";

export interface Env extends ApnsEnvironment {
  PUSH_REGISTRY: DurableObjectNamespace<PushRegistry>;
  COUNTER_LEDGER: DurableObjectNamespace<CounterLedger>;
}

const hexSecret = /^[0-9a-f]{64}$/;
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

function problem(status: number, error: string, headers?: HeadersInit): Response {
  return Response.json({ error }, { status, headers });
}

async function digest(value: string): Promise<string> {
  const bytes = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value)));
  return Array.from(bytes, byte => byte.toString(16).padStart(2, "0")).join("");
}

function validBody(path: string, method: string, body: Record<string, unknown>): boolean {
  const keys = Object.keys(body).sort().join(",");
  const deviceId = typeof body.device_id === "string" && uuid.test(body.device_id);
  const secret = typeof body.secret === "string" && hexSecret.test(body.secret);
  switch (`${method} ${path}`) {
    case "POST /devices":
      return keys === "device_id,device_secret,environment,token" && deviceId &&
        typeof body.device_secret === "string" && hexSecret.test(body.device_secret) &&
        typeof body.token === "string" && /^(?:[0-9a-f]{2})+$/.test(body.token) &&
        (body.environment === "sandbox" || body.environment === "production");
    case "DELETE /devices": return keys === "device_id" && deviceId;
    case "POST /pairings":
    case "DELETE /pairings": return keys === "device_id,secret" && deviceId && secret;
    case "POST /notify":
      return keys === "kind,secret,session_ref" && secret &&
        typeof body.session_ref === "string" && hexSecret.test(body.session_ref) &&
        ["ask", "approval", "done", "error"].includes(body.kind as string);
    case "POST /ping":
      return keys === "ask_answered,host_ok,install_id,screen_opened" &&
        typeof body.install_id === "string" && uuid.test(body.install_id) &&
        [body.ask_answered, body.host_ok, body.screen_opened].every(value => typeof value === "boolean");
    default: return false;
  }
}

async function readBody(request: Request): Promise<Record<string, unknown> | Response> {
  if (request.headers.get("content-type")?.split(";")[0].trim().toLowerCase() !== "application/json") {
    return problem(415, "Use application/json.");
  }
  const reader = request.body?.getReader();
  if (!reader) return problem(400, "Send a JSON object.");
  const chunks: Uint8Array[] = [];
  let length = 0;
  while (true) {
    const { value, done } = await reader.read();
    if (done) break;
    length += value.byteLength;
    if (length > 2048) {
      await reader.cancel();
      return problem(413, "Request exceeds 2048 bytes.");
    }
    chunks.push(value);
  }
  const bytes = new Uint8Array(length);
  let offset = 0;
  for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength; }
  try {
    const body: unknown = JSON.parse(new TextDecoder("utf-8", { fatal: true, ignoreBOM: false }).decode(bytes));
    if (body && typeof body === "object" && !Array.isArray(body)) return body as Record<string, unknown>;
  } catch { /* Invalid input never reaches storage. */ }
  return problem(400, "Send a JSON object.");
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    try {
      const url = new URL(request.url);
      if (!["/devices", "/pairings", "/notify", "/ping"].includes(url.pathname)) return problem(404, "Unknown endpoint.");
      if (request.method !== "POST" && !(request.method === "DELETE" && ["/devices", "/pairings"].includes(url.pathname))) {
        return problem(405, "Use the endpoint's documented method.");
      }
      if (url.search) return problem(400, "Query parameters are not accepted.");
      const body = await readBody(request);
      if (body instanceof Response) return body;
      if (!validBody(url.pathname, request.method, body)) return problem(400, "Unexpected fields or invalid values.");
      if (typeof body.device_id === "string") body.device_id = body.device_id.toLowerCase();
      if (typeof body.install_id === "string") body.install_id = body.install_id.toLowerCase();
      const headers = new Headers({ "content-type": "application/json" });
      if (url.pathname === "/pairings" || request.method === "DELETE") {
        const auth = request.headers.get("authorization") ?? "";
        if (!/^Bearer [0-9a-f]{64}$/.test(auth)) return problem(401, "Device authorization required.");
        headers.set("authorization", auth);
      }
      const namespace = url.pathname === "/ping" ? env.COUNTER_LEDGER : env.PUSH_REGISTRY;
      return await namespace.get(namespace.idFromName("primary")).fetch(`https://internal${url.pathname}`, {
        method: request.method, headers, body: JSON.stringify(body),
      });
    } catch {
      return problem(503, "Relay unavailable. Try again later.");
    }
  },
  async scheduled(_controller: ScheduledController, env: Env): Promise<void> {
    await Promise.all([
      env.PUSH_REGISTRY.get(env.PUSH_REGISTRY.idFromName("primary")).expire(),
      env.COUNTER_LEDGER.get(env.COUNTER_LEDGER.idFromName("primary")).rollup(),
    ]);
  },
} satisfies ExportedHandler<Env>;

interface DeviceRow extends Record<string, SqlStorageValue> {
  device_id: string;
  secret_hash: string;
  token: string | null;
  environment: "sandbox" | "production";
  registered_at: number;
  expires_at: number;
}
interface PairingRow extends Record<string, SqlStorageValue> {
  pairing_id: string;
  device_id: string;
  window_start: number;
  attempts: number;
}

export class PushRegistry extends DurableObject<Env> {
  private readonly sql: SqlStorage;
  private readonly apns: ApnsSender;

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    this.sql = ctx.storage.sql;
    this.apns = new ApnsSender(env, ctx.storage);
    this.sql.exec(`
      CREATE TABLE IF NOT EXISTS devices (
        device_id TEXT PRIMARY KEY, secret_hash TEXT NOT NULL, token TEXT,
        environment TEXT NOT NULL, registered_at INTEGER NOT NULL, expires_at INTEGER NOT NULL,
        UNIQUE(token, environment)
      );
      CREATE TABLE IF NOT EXISTS pairings (
        pairing_id TEXT PRIMARY KEY, device_id TEXT NOT NULL,
        window_start INTEGER NOT NULL DEFAULT 0, attempts INTEGER NOT NULL DEFAULT 0
      );
      CREATE INDEX IF NOT EXISTS pairings_device ON pairings(device_id);
    `);
  }

  async expire(): Promise<void> {
    await this.ctx.blockConcurrencyWhile(async () => {
      this.removeExpired(Date.now());
      await this.apns.clearExpiredAuthorization();
    });
  }

  private removeExpired(now: number): void {
    this.ctx.storage.transactionSync(() => {
      this.sql.exec("DELETE FROM pairings WHERE device_id IN (SELECT device_id FROM devices WHERE expires_at <= ?)", now);
      this.sql.exec("DELETE FROM devices WHERE expires_at <= ?", now);
    });
  }

  async fetch(request: Request): Promise<Response> {
    // Include APNs completion in the gate: a successful revoke cannot be overtaken by an earlier queued send.
    return this.ctx.blockConcurrencyWhile(async () => {
      const now = Date.now();
      this.removeExpired(now);
      const path = new URL(request.url).pathname;
      if (path === "/notify") return this.notify(await request.json() as NotifyRequest, now);
      const body = await request.json() as DeviceRegistration & PairingRegistration;
      const secretHash = await digest(path === "/devices" && request.method === "POST"
        ? body.device_secret : request.headers.get("authorization")!.slice(7));
      const device = this.sql.exec<DeviceRow>("SELECT * FROM devices WHERE device_id = ?", body.device_id).toArray()[0];
      if (device && device.secret_hash !== secretHash) return problem(401, "Device authorization failed.");
      if (path === "/devices" && request.method === "POST") {
        const owner = this.sql.exec<{ device_id: string }>(
          "SELECT device_id FROM devices WHERE token = ? AND environment = ?", body.token, body.environment,
        ).toArray()[0];
        if (owner && owner.device_id !== body.device_id) return problem(409, "Token is already registered. Remove its previous registration first.");
        this.sql.exec(`INSERT INTO devices VALUES (?, ?, ?, ?, ?, ?)
          ON CONFLICT(device_id) DO UPDATE SET token=excluded.token, environment=excluded.environment,
          registered_at=excluded.registered_at, expires_at=excluded.expires_at`,
        body.device_id, secretHash, body.token, body.environment, now, now + REGISTRATION_TTL);
        return Response.json({ registered: true });
      }
      if (!device) return problem(401, "Register this device again.");
      if (path === "/devices" && request.method === "DELETE") {
        this.ctx.storage.transactionSync(() => {
          this.sql.exec("DELETE FROM pairings WHERE device_id = ?", body.device_id);
          this.sql.exec("DELETE FROM devices WHERE device_id = ?", body.device_id);
        });
        return new Response(null, { status: 204 });
      }
      const pairingId = await digest(body.secret);
      const pairing = this.sql.exec<PairingRow>("SELECT * FROM pairings WHERE pairing_id = ?", pairingId).toArray()[0];
      if (pairing && pairing.device_id !== body.device_id) return problem(409, "Use a new pairing secret.");
      if (request.method === "DELETE") {
        this.sql.exec("DELETE FROM pairings WHERE pairing_id = ? AND device_id = ?", pairingId, body.device_id);
        return new Response(null, { status: 204 });
      }
      this.sql.exec("INSERT OR IGNORE INTO pairings (pairing_id, device_id) VALUES (?, ?)", pairingId, body.device_id);
      return Response.json({ pairing_id: pairingId });
    });
  }

  private async notify(body: NotifyRequest, now: number): Promise<Response> {
    const pairingId = await digest(body.secret);
    const pairing = this.sql.exec<PairingRow>("SELECT * FROM pairings WHERE pairing_id = ?", pairingId).toArray()[0];
    if (!pairing) return problem(401, "Pair this host again.");
    const device = this.sql.exec<DeviceRow>("SELECT * FROM devices WHERE device_id = ?", pairing.device_id).toArray()[0];
    if (!device?.token) return problem(410, "Register push notifications on the phone again.");
    const windowStart = now - pairing.window_start >= RATE_WINDOW ? now : pairing.window_start;
    const attempts = windowStart === pairing.window_start ? pairing.attempts : 0;
    if (attempts >= RATE_LIMIT) return problem(429, "Pairing rate limit reached.", {
      "retry-after": String(Math.max(1, Math.ceil((windowStart + RATE_WINDOW - now) / 1000))),
    });
    this.sql.exec("UPDATE pairings SET window_start = ?, attempts = ? WHERE pairing_id = ?",
      windowStart, attempts + 1, pairingId);
    const result = await this.apns.send(device.token, device.environment, device.registered_at, pairingId, body);
    if (result === "accepted") return Response.json({ accepted: true });
    if (result === "invalid_token") {
      this.sql.exec("UPDATE devices SET token = NULL WHERE device_id = ?", device.device_id);
      return problem(410, "Register push notifications on the phone again.");
    }
    if (result === "unconfigured") return problem(503, "Configure the relay APNs key, key ID, team ID and topic.");
    return problem(502, "APNs unavailable. Try again later.");
  }
}

export class CounterLedger extends DurableObject<Env> {
  private readonly sql: SqlStorage;

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    this.sql = ctx.storage.sql;
    this.sql.exec(`
      CREATE TABLE IF NOT EXISTS pings (
        day TEXT NOT NULL, identity TEXT NOT NULL,
        host_ok INTEGER NOT NULL, screen_opened INTEGER NOT NULL,
        ask_answered INTEGER NOT NULL,
        PRIMARY KEY(day, identity)
      );
      CREATE TABLE IF NOT EXISTS rollups (
        day TEXT PRIMARY KEY, installs INTEGER NOT NULL, host_ok INTEGER NOT NULL,
        screen_opened INTEGER NOT NULL, ask_answered INTEGER NOT NULL,
        active_7d INTEGER NOT NULL
      );
    `);
  }

  async fetch(request: Request): Promise<Response> {
    const body = await request.json() as CounterPing;
    const day = new Date().toISOString().slice(0, 10);
    // Even a client that fails to rotate its UUID has no persistent cross-month storage identity.
    const identity = await digest(`${day.slice(0, 7)}:${body.install_id}`);
    this.sql.exec("INSERT OR IGNORE INTO pings VALUES (?, ?, ?, ?, ?)", day, identity,
      Number(body.host_ok), Number(body.screen_opened), Number(body.ask_answered));
    return Response.json({ accepted: true });
  }

  async rollup(): Promise<void> {
    const today = new Date().toISOString().slice(0, 10);
    const midnight = Date.parse(`${today}T00:00:00Z`);
    this.ctx.storage.transactionSync(() => {
      // Recompute recent completed days so delayed cron runs and retries are harmless.
      for (let offset = RAW_COUNTER_DAYS - 7; offset >= 1; offset--) {
        const day = new Date(midnight - offset * DAY).toISOString().slice(0, 10);
        const firstDay = new Date(midnight - (offset + 6) * DAY).toISOString().slice(0, 10);
        this.sql.exec(`INSERT INTO rollups
          SELECT ?, COUNT(*), COALESCE(SUM(host_ok),0), COALESCE(SUM(screen_opened),0),
            COALESCE(SUM(ask_answered),0),
            (SELECT COUNT(DISTINCT identity) FROM pings WHERE day BETWEEN ? AND ? AND (screen_opened = 1 OR ask_answered = 1))
          FROM pings WHERE day = ?
          ON CONFLICT(day) DO UPDATE SET installs=excluded.installs, host_ok=excluded.host_ok,
            screen_opened=excluded.screen_opened, ask_answered=excluded.ask_answered,
            active_7d=excluded.active_7d`, day, firstDay, day, day);
      }
      this.sql.exec("DELETE FROM pings WHERE day < ?", new Date(midnight - (RAW_COUNTER_DAYS - 1) * DAY).toISOString().slice(0, 10));
      this.sql.exec("DELETE FROM rollups WHERE day < ?", new Date(midnight - ROLLUP_DAYS * DAY).toISOString().slice(0, 10));
    });
  }
}
