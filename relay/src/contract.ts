// Wire contract shared by the Worker, term-notify and the iOS app.
export type StopKind = "ask" | "approval" | "done" | "error";
export interface DeviceRegistration {
  device_id: string; // random UUID; unrelated to the counter install ID
  device_secret: string; // 32 random bytes, lowercase hex; phone only
  token: string; // APNs token, lowercase hex
  environment: "sandbox" | "production";
}
// POST /devices creates or updates a device; updates require the same secret.
// DELETE /devices: {device_id}, Authorization: Bearer <device_secret>.
export interface PairingRegistration {
  device_id: string;
  secret: string; // independent 32 random bytes, lowercase hex, per host + phone
}
// POST /pairings and DELETE /pairings use PairingRegistration and device bearer auth.
// POST /pairings returns {pairing_id: SHA256(secret), lowercase hex}.
export interface NotifyRequest {
  secret: string;
  session_ref: string; // HMAC-SHA256(routing_key, UTF8([session, pane, server_start, server_pid].join("\0"))), lowercase hex
  kind: StopKind;
}
// POST /notify. No other keys accepted. 2xx = accepted; 429 includes Retry-After.
export interface PushPayload {
  aps: { alert: { title: "Term"; body: "An agent needs you" | "An agent finished" }; sound: "default" };
  term: { pairing_id: string; session_ref: string; kind: StopKind };
}
export interface CounterPing {
  install_id: string; // random UUID, replaced monthly; never a push identity
  host_ok: boolean;
  screen_opened: boolean;
  ask_answered: boolean;
}
// POST /ping: one immutable record per install_id per UTC day; server assigns date.
// Counter is opt-in; no purchase/Pro information is collected or transmitted.
// App accumulates flags for a UTC day and sends that completed day on next active opportunity.
// No dates or other metadata transmitted. Rollups count the server receipt day.
export interface HostPairing {
  version: 1;
  relay_url: string;
  secret: string;
  routing_key: string; // independent 32 random bytes, lowercase hex; NEVER sent to relay
}
// Phone writes ~/.config/term/notify/<pairing_id>.json over SSH, directory 0700 / file 0600.
// Host notifier reads all *.json there; no APNs token or device-management secret on host.
// Tap: phone identifies host by pairing_id, lists session_name, pane_id, start_time, pid over pinned SSH (tmux -u),
// computes HMAC for each, then attaches to exact matching session and selects that pane.
// start_time and pid identify the tmux server generation: reused pane IDs after restart must not match old pushes.
// Unknown/deleted routes show an actionable error; never attach to a different pane.
