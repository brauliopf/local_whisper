export type BrowserRequest =
  | { id: string; type: "start"; profilePath: string }
  | { id: string; type: "stop" }
  | { id: string; type: "navigate"; url: string }
  | { id: string; type: "inspect" }
  | { id: string; type: "screenshot"; scope?: "viewport" | "full_page" }
  | { id: string; type: "execute"; action: BrowserAction }
  | { id: string; type: "shutdown" };

export type BrowserAction =
  | { type: "click"; target: string }
  | { type: "scroll"; direction: "up" | "down" }
  | { type: "read"; target?: string }
  | { type: "wait"; milliseconds: number };

export type BrowserResponse =
  | { id: string; type: "ready" }
  | { id: string; type: "state"; state: "stopped" | "starting" | "idle" | "failed"; message?: string }
  | { id: string; type: "result"; result: unknown }
  | { id: string; type: "error"; message: string };

export function isBrowserRequest(value: unknown): value is BrowserRequest {
  if (!value || typeof value !== "object") return false;
  const request = value as Record<string, unknown>;
  return typeof request.id === "string" && typeof request.type === "string";
}
