import type { NotifyRequest, PushPayload } from "./contract";

export interface ApnsEnvironment {
  APNS_PRIVATE_KEY?: string;
  APNS_KEY_ID?: string;
  APNS_TEAM_ID?: string;
  APNS_TOPIC?: string;
}

export type ApnsResult = "accepted" | "invalid_token" | "unavailable" | "unconfigured";

function base64url(bytes: Uint8Array): string {
  return btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function encode(value: unknown): string {
  return base64url(new TextEncoder().encode(JSON.stringify(value)));
}

export class ApnsSender {
  private signingKey?: CryptoKey;
  private cached?: { token: string; issuedAt: number; keyIdentity: string };
  private keyIdentity?: string;

  constructor(private readonly env: ApnsEnvironment, private readonly storage: DurableObjectStorage) {}

  private async authorization(now: number): Promise<string | null> {
    if (!this.keyIdentity) {
      const identity = JSON.stringify([this.env.APNS_PRIVATE_KEY, this.env.APNS_KEY_ID, this.env.APNS_TEAM_ID, this.env.APNS_TOPIC]);
      this.keyIdentity = base64url(new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(identity))));
    }
    this.cached ??= await this.storage.get("apns_token");
    if (this.cached?.keyIdentity === this.keyIdentity && now >= this.cached.issuedAt && now - this.cached.issuedAt < 3000) {
      return this.cached.token;
    }
    if (!this.signingKey) {
      try {
        const pem = this.env.APNS_PRIVATE_KEY!.replace(/\\n/g, "\n");
        const der = pem.replace(/-----BEGIN PRIVATE KEY-----|-----END PRIVATE KEY-----|\s/g, "");
        this.signingKey = await crypto.subtle.importKey(
          "pkcs8", Uint8Array.from(atob(der), character => character.charCodeAt(0)),
          { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"],
        );
      } catch {
        return null;
      }
    }
    const unsigned = `${encode({ alg: "ES256", kid: this.env.APNS_KEY_ID })}.${encode({ iss: this.env.APNS_TEAM_ID, iat: now })}`;
    const signature = await crypto.subtle.sign(
      { name: "ECDSA", hash: "SHA-256" }, this.signingKey, new TextEncoder().encode(unsigned),
    );
    const token = `${unsigned}.${base64url(new Uint8Array(signature))}`;
    this.cached = { token, issuedAt: now, keyIdentity: this.keyIdentity };
    await this.storage.put("apns_token", this.cached);
    return token;
  }

  async clearExpiredAuthorization(): Promise<void> {
    const cached = await this.storage.get<{ issuedAt: number }>("apns_token");
    if (cached && Math.floor(Date.now() / 1000) - cached.issuedAt >= 3600) {
      await this.storage.delete("apns_token");
      this.cached = undefined;
    }
  }

  async send(
    token: string, environment: "sandbox" | "production", registeredAt: number,
    pairingId: string, notification: NotifyRequest,
  ): Promise<ApnsResult> {
    if (!this.env.APNS_PRIVATE_KEY || !this.env.APNS_KEY_ID || !this.env.APNS_TEAM_ID || !this.env.APNS_TOPIC) {
      return "unconfigured";
    }
    const payload: PushPayload = {
      aps: { alert: { title: "Term", body: notification.kind === "done" ? "An agent finished" : "An agent needs you" }, sound: "default" },
      term: { pairing_id: pairingId, session_ref: notification.session_ref, kind: notification.kind },
    };
    try {
      const now = Math.floor(Date.now() / 1000);
      const jwt = await this.authorization(now);
      if (!jwt) return "unconfigured";
      const origin = environment === "sandbox" ? "https://api.sandbox.push.apple.com" : "https://api.push.apple.com";
      const response = await fetch(`${origin}/3/device/${token}`, {
        method: "POST",
        headers: {
          authorization: `bearer ${jwt}`,
          "apns-topic": this.env.APNS_TOPIC,
          "apns-push-type": "alert",
          "apns-priority": "10",
          "apns-expiration": String(now + 3600),
          "apns-collapse-id": notification.session_ref,
          "content-type": "application/json",
        },
        body: JSON.stringify(payload),
        signal: AbortSignal.timeout(10_000),
      });
      if (response.status === 200) return "accepted";
      const error = await response.json() as { reason?: string; timestamp?: number };
      if (response.status === 400 && error.reason === "BadDeviceToken") return "invalid_token";
      if (response.status === 410 && error.reason === "Unregistered" &&
          (typeof error.timestamp !== "number" || error.timestamp >= registeredAt)) return "invalid_token";
      return "unavailable";
    } catch {
      // Never log provider errors: they can contain the token or notification body.
      return "unavailable";
    }
  }
}
