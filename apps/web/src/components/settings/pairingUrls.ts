import { buildHostedPairingUrl } from "../../hostedPairing";
import { setPairingTokenOnUrl } from "../../pairingUrl";

export function resolveDesktopPairingUrl(endpointUrl: string, credential: string): string {
  const url = new URL(endpointUrl);
  url.pathname = "/pair";
  return setPairingTokenOnUrl(url, credential).toString();
}

export function appendPairingFallbackEndpoints(
  pairingUrl: string,
  endpointUrls: ReadonlyArray<string>,
): string {
  const url = new URL(pairingUrl);
  const hostedTarget = url.searchParams.get("host");
  const primaryOrigin = new URL(hostedTarget ?? url.origin).origin;
  const seen = new Set([primaryOrigin]);
  url.searchParams.delete("fallback");

  for (const endpointUrl of endpointUrls) {
    let endpoint: URL;
    try {
      endpoint = new URL(endpointUrl);
    } catch {
      continue;
    }
    if (!["http:", "https:"].includes(endpoint.protocol) || seen.has(endpoint.origin)) {
      continue;
    }
    seen.add(endpoint.origin);
    url.searchParams.append("fallback", endpoint.origin);
  }
  return url.toString();
}

export function resolveHostedPairingUrl(endpointUrl: string, credential: string): string | null {
  const url = new URL(endpointUrl);
  if (url.protocol !== "https:") {
    return null;
  }

  return buildHostedPairingUrl({
    host: endpointUrl,
    token: credential,
  });
}
