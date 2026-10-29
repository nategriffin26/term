import { cloudflareTest } from "@cloudflare/vitest-plugin";
import { defineConfig } from "vitest/config";
import { generateKeyPairSync } from "node:crypto";
import { fetch as nodeFetch, type Request as MiniflareRequest } from "miniflare";

const key = generateKeyPairSync("ec", {
  namedCurve: "prime256v1",
  privateKeyEncoding: { type: "pkcs8", format: "pem" },
  publicKeyEncoding: { type: "spki", format: "pem" },
});

function apnsProxy(port: number) {
  return async (request: MiniflareRequest) => {
    const url = new URL(request.url);
    const headers = Object.fromEntries(request.headers);
    headers["x-test-original-url"] = request.url;
    return nodeFetch(`http://127.0.0.1:${port}${url.pathname}${url.search}`, {
      method: request.method, headers,
      body: request.method === "GET" || request.method === "HEAD" ? undefined : await request.arrayBuffer(),
      signal: request.signal,
    });
  };
}

export default defineConfig({
  plugins: [cloudflareTest(({ inject }) => ({
    wrangler: { configPath: "./wrangler.jsonc" },
    miniflare: {
      bindings: {
        APNS_PRIVATE_KEY: key.privateKey,
        APNS_PUBLIC_KEY: key.publicKey,
        APNS_KEY_ID: "TESTKEY123",
        APNS_TEAM_ID: "TESTTEAM12",
        APNS_TOPIC: "dev.term.tests",
      },
      outboundService: apnsProxy(inject("apnsPort")),
      serviceBindings: {
        APNS_TEST: apnsProxy(inject("apnsPort")),
      },
    },
  }))],
  test: {
    globalSetup: ["./test/apns-server.ts"],
    fileParallelism: false,
    // workerd cannot read Vitest's host-filesystem transform cache.
    fsModuleCache: false,
  },
});

declare module "vitest" {
  interface ProvidedContext { apnsPort: number }
}
