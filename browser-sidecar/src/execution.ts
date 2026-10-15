import { createHash } from "node:crypto";
import vm from "node:vm";
import type { Page } from "playwright";
import { type PageSnapshot } from "./redaction.js";
import { validateBrowserCode } from "./validator.js";

export async function executeBrowserPlan(
  page: Page,
  snapshot: () => Promise<PageSnapshot | undefined>,
  code: string,
  expectedStateHash: string,
  expectedCodeHash: string,
  policyVersion: string,
  expiresAt: string,
): Promise<PageSnapshot | undefined> {
  const expiresAtDate = Date.parse(expiresAt);
  if (!Number.isFinite(expiresAtDate) || expiresAtDate <= Date.now()) throw new Error("expired browser plan");
  if (createHash("sha256").update(code).digest("hex") !== expectedCodeHash) throw new Error("code hash mismatch");
  const validation = validateBrowserCode(code, policyVersion);
  if (!validation.valid) throw new Error(`policy violation: ${validation.violations.map((item) => item.category).join(",")}`);
  const before = await snapshot();
  if (!before || before.stateHash !== expectedStateHash) throw new Error("stale browser state");
  await new vm.Script(`(async () => {\n${code}\n})()`).runInNewContext({ page }, { timeout: 30_000 });
  return snapshot();
}
