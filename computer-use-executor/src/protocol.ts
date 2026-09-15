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
  browser: { url: string; title: string };
} | {
  ok: false;
  error: { kind: "script_error" | "navigation_policy" | "invalid_result"; message: string };
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

export function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

export function parseConfiguration(value: unknown): BrowserConfiguration {
  if (!isRecord(value) || typeof value.initialURL !== "string" ||
    !Array.isArray(value.allowedOrigins) || value.allowedOrigins.some(item => typeof item !== "string") ||
    typeof value.artifactDirectory !== "string") {
    throw new Error("Invalid browser configuration.");
  }
  return value as unknown as BrowserConfiguration;
}

export function originOf(url: string): string {
  return new URL(url).origin;
}

export function isAllowedOrigin(url: string, allowedOrigins: string[]): boolean {
  return allowedOrigins.includes(originOf(url));
}
