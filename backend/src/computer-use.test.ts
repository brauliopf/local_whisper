import assert from "node:assert/strict";
import test from "node:test";
import {
  MemoryComputerSessionRepository,
  scanComputerCode,
  type ComputerGuardrail,
  type ComputerPlanner,
} from "./computer-use.js";
import { ComputerUseService } from "./computer-use-service.js";

const safeCode = `module.exports = async ({ page, screenshot }) => ({ type: "table", columns: ["Title"], rows: [[await page.title()]], notes: [] });`;

test("computer code scanner enforces the executor contract", () => {
  assert.deepEqual(scanComputerCode(safeCode), { safe: true, reasons: [] });
  assert.equal(scanComputerCode("module.exports = async ({ page }) => ({})").safe, false);
  assert.ok(scanComputerCode("module.exports = async ({ page, screenshot }) => process.env.SECRET").reasons.some((reason) => reason.startsWith("forbidden_identifier:process")));
  assert.ok(scanComputerCode("module.exports = async ({ page, screenshot }) => page.context().cookies()").reasons.includes("forbidden_property:context"));
});

test("computer-use service pauses risky steps for exact-code approval", async () => {
  const repository = new MemoryComputerSessionRepository();
  const planner: ComputerPlanner = {
    async start() {
      return { responseId: "response-1", callId: "call-1", code: safeCode, summary: "Submit the form" };
    },
    async continue() {
      return { done: true, responseId: "response-2", message: "Done" };
    },
  };
  const guardrail: ComputerGuardrail = {
    async evaluate() {
      return { risk: "needs_user_approval", reasons: ["needs_user_approval"] };
    },
  };
  const service = new ComputerUseService({
    repository,
    planner,
    guardrail,
    maxIterations: 20,
    maxTaskDurationMs: 600_000,
    maxRegenerationsPerStep: 3,
    maxScreenshotBytes: 4 * 1024 * 1024,
    approvalTimeoutMs: 60_000,
  });

  const response = await service.start({
    instruction: "Submit the form",
    initialURL: "https://example.com",
    allowedOrigins: ["https://example.com"],
  }, new AbortController().signal);
  assert.equal(response.session.status, "awaiting_approval");
  assert.equal(response.step?.status, "awaiting_approval");
  assert.equal(response.step?.codeHash.length, 64);
  assert.equal(response.step?.browserStateHash.length, 64);

  await assert.rejects(
    () => service.approve(response.session.id, response.step!.id, "wrong", response.step!.browserStateHash),
    /approval does not match/
  );
  const approved = await service.approve(
    response.session.id,
    response.step!.id,
    response.step!.codeHash,
    response.step!.browserStateHash,
  );
  assert.equal(approved.step?.status, "pending");
});
