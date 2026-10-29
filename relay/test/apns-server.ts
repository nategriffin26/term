import { createServer, type ServerResponse } from "node:http";
import type { TestProject } from "vitest/node";

// Provider error fixtures follow Apple's documented status/reason response format.
export default async function setup(project: TestProject) {
  let reply: { status?: number; reason?: string; timestamp?: number; disconnect?: boolean; hold?: boolean } = {};
  let records: { url: string; headers: Record<string, unknown>; body: unknown }[] = [];
  const waiting: ServerResponse[] = [];
  const pending: ServerResponse[] = [];
  const respond = (response: ServerResponse) => {
    response.writeHead(reply.status ?? 200, { "content-type": "application/json", "apns-id": "123e4567-e89b-42d3-a456-426614174000" });
    response.end(reply.status && reply.status !== 200 ? JSON.stringify({ reason: reply.reason, timestamp: reply.timestamp }) : "");
  };
  const server = createServer(async (request, response) => {
    const url = new URL(String(request.headers["x-test-original-url"] ?? request.url), "http://control");
    let text = "";
    for await (const chunk of request) text += chunk;
    if (url.pathname === "/_configure") {
      reply = JSON.parse(text);
      records = [];
      response.end("{}");
      return;
    }
    if (url.pathname === "/_records") {
      response.setHeader("content-type", "application/json");
      response.end(JSON.stringify(records));
      return;
    }
    if (url.pathname === "/_wait") {
      if (records.length) response.end("{}");
      else waiting.push(response);
      return;
    }
    if (url.pathname === "/_release") {
      for (const held of pending.splice(0)) respond(held);
      response.end("{}");
      return;
    }
    if (!url.pathname.startsWith("/3/device/")) {
      response.writeHead(404).end();
      return;
    }
    records.push({ url: url.href, headers: request.headers, body: JSON.parse(text) });
    for (const waiter of waiting.splice(0)) waiter.end("{}");
    if (reply.disconnect) { request.socket.destroy(); return; }
    if (reply.hold) { pending.push(response); return; }
    respond(response);
  });
  const listening = Promise.withResolvers<void>();
  server.once("error", listening.reject);
  server.listen(0, "127.0.0.1", listening.resolve);
  await listening.promise;
  const address = server.address();
  if (!address || typeof address === "string") throw new Error("Fake APNs did not bind TCP.");
  project.provide("apnsPort", address.port);
  return async () => {
    server.closeAllConnections();
    const closed = Promise.withResolvers<void>();
    server.close(error => error ? closed.reject(error) : closed.resolve());
    await closed.promise;
  };
}
