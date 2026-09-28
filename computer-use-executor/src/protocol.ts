export type BrowserConfiguration = {
  initialURL: string;
  allowedOrigins: string[];
  artifactDirectory: string;
  scriptTimeoutMs?: number;
};

export type TableValue = {
  type: "table";
  columns: string[];
  rows: string[][];
  notes: string[];
};

export type ExecutorResult = {
  ok: true;
  value: TableValue;
  text: string[];
  artifacts: Array<{ path: string; mimeType: "image/png"; label: string }>;
  screenshot: { path: string; mimeType: "image/png"; label: string };
  browser: { url: string; title: string };
} | {
  ok: false;
  error: { kind: "script_error" | "capability_error" | "navigation_policy" | "invalid_result"; message: string };
  screenshot?: { path: string; mimeType: "image/png"; label: string };
  browser: { url: string; title: string };
};

export type SessionInfo = { url: string; title: string };

export type Request = {
  jsonrpc: "2.0";
  id: number;
  method: "session.start" | "script.execute" | "session.stop";
  params?: Record<string, unknown>;
};

export const maxScriptBytes = 64 * 1024;
export const maxResultBytes = 4 * 1024 * 1024;
export const defaultScriptTimeoutMs = 60_000;
export const maxScreenshots = 20;

export function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

export function parseConfiguration(value: unknown): BrowserConfiguration {
  if (!isRecord(value) || typeof value.initialURL !== "string" ||
    !Array.isArray(value.allowedOrigins) || value.allowedOrigins.some(item => typeof item !== "string") ||
    typeof value.artifactDirectory !== "string") {
    throw new Error("Invalid browser configuration.");
  }
  validateHTTPURL(value.initialURL, "initialURL");
  for (const origin of value.allowedOrigins) {
    validateOrigin(origin);
  }
  return {
    ...value,
    scriptTimeoutMs: Math.max(
      1,
      Math.min(
        typeof value.scriptTimeoutMs === "number" ? value.scriptTimeoutMs : defaultScriptTimeoutMs,
        defaultScriptTimeoutMs,
      ),
    ),
  } as unknown as BrowserConfiguration;
}

export function originOf(url: string): string {
  return new URL(url).origin;
}

export function isAllowedOrigin(url: string, allowedOrigins: string[]): boolean {
  return allowedOrigins.includes(originOf(url));
}

function validateHTTPURL(value: string, field: string): void {
  let parsed: URL;
  try {
    parsed = new URL(value);
  } catch {
    throw new Error(`Invalid ${field}.`);
  }
  if (!isHTTPProtocol(parsed.protocol) || parsed.username || parsed.password) {
    throw new Error(`Invalid ${field}.`);
  }
}

function validateOrigin(value: string): void {
  let parsed: URL;
  try {
    parsed = new URL(value);
  } catch {
    throw new Error("Invalid allowed origin.");
  }
  if (!isHTTPProtocol(parsed.protocol) || parsed.username || parsed.password || parsed.origin !== value) {
    throw new Error("Allowed origins must be exact HTTP(S) origins.");
  }
}

function isHTTPProtocol(protocol: string): boolean {
  return protocol === "http:" || protocol === "https:";
}
