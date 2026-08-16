import { afterEach, describe, expect, it, vi } from "vite-plus/test";

import {
  appendPairingFallbackEndpoints,
  resolveDesktopPairingUrl,
  resolveHostedPairingUrl,
} from "./pairingUrls";

describe("settings pairing URL helpers", () => {
  afterEach(() => {
    vi.unstubAllEnvs();
  });

  it("uses direct backend pairing URLs for HTTP endpoints", () => {
    expect(resolveHostedPairingUrl("http://192.168.1.44:3773", "PAIRCODE")).toBeNull();
    expect(resolveDesktopPairingUrl("http://192.168.1.44:3773", "PAIRCODE")).toBe(
      "http://192.168.1.44:3773/pair#token=PAIRCODE",
    );
  });

  it("uses hosted pairing URLs for HTTPS endpoints", () => {
    vi.stubEnv("VITE_HOSTED_APP_URL", "https://preview.t3.codes");

    expect(resolveHostedPairingUrl("https://host.tailnet.example.ts.net:3773", "PAIRCODE")).toBe(
      "https://preview.t3.codes/pair?host=https%3A%2F%2Fhost.tailnet.example.ts.net%3A3773#token=PAIRCODE",
    );
  });

  it("adds unique endpoint fallbacks without changing the pairing token", () => {
    const result = appendPairingFallbackEndpoints("http://192.168.1.47:3773/pair#token=PAIRCODE", [
      "http://192.168.1.47:3773/",
      "http://100.81.12.71:3773/",
      "http://100.81.12.71:3773/",
    ]);
    const url = new URL(result);

    expect(url.searchParams.getAll("fallback")).toEqual(["http://100.81.12.71:3773"]);
    expect(url.hash).toBe("#token=PAIRCODE");
  });

  it("compares hosted fallbacks with the target environment", () => {
    const result = appendPairingFallbackEndpoints(
      "https://app.t3.codes/pair?host=https%3A%2F%2Fdesktop.example.ts.net#token=PAIRCODE",
      ["https://desktop.example.ts.net", "http://100.81.12.71:3773"],
    );

    expect(new URL(result).searchParams.getAll("fallback")).toEqual(["http://100.81.12.71:3773"]);
  });
});
