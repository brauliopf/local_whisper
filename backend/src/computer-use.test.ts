import assert from "node:assert/strict";
import { test } from "node:test";
import {
  ComputerApprovalError,
  MemoryComputerSessionRepository,
  type ComputerPlanner,
} from "./computer-use.js";
import { ComputerUseService } from "./computer-use-service.js";

const plan = { code: "module.exports = async () => ({ type: 'table' })", summary: "Inspect the page", callId: "call-1" };
const options = (planner: ComputerPlanner, risk: "safe" | "needs_user_approval" = "safe") => ({
  repository: new MemoryComputerSessionRepository(), planner,
  guardrail: { async evaluate() { return { risk, reasons: [] }; } },
  maxIterations: 3, maxTaskDurationMs: 60_000, maxRegenerationsPerStep: 1,
  maxScreenshotBytes: 100, approvalTimeoutMs: 10_000,
});

function planner(done = true): ComputerPlanner {
  return {
    async start() { return { ...plan, responseId: "response-1" }; },
    async continue() { return done ? { done: true, message: "Finished", responseId: "response-2" } : { ...plan, responseId: "response-2" }; },
  };
}

test("executes a safe step and completes after the result is submitted", async () => {
  const service = new ComputerUseService(options(planner()));
  const started = await service.start({ instruction: "Read the page", initialURL: "https://example.com", allowedOrigins: ["https://example.com"] }, new AbortController().signal);
  assert.equal(started.step?.status, "pending");
  const completed = await service.submitResult({ sessionId: started.session.id, stepId: started.step!.id, result: { ok: true }, screenshot: Buffer.from("png"), currentURL: "https://example.com", currentTitle: "Example" }, new AbortController().signal);
  assert.equal(completed.done, true);
  assert.equal(completed.session.status, "completed");
});

test("requires an exact code and browser-state binding for approval", async () => {
  const service = new ComputerUseService(options(planner(), "needs_user_approval"));
  const started = await service.start({ instruction: "Change the page", initialURL: "https://example.com", allowedOrigins: ["https://example.com"], currentURL: "https://example.com", currentTitle: "Example" }, new AbortController().signal);
  await assert.rejects(() => service.approve(started.session.id, started.step!.id, "wrong", started.step!.browserStateHash), ComputerApprovalError);
  const approved = await service.approve(started.session.id, started.step!.id, started.step!.codeHash, started.step!.browserStateHash);
  assert.equal(approved.step?.status, "pending");
});

test("rejects browser state outside the session origins", async () => {
  const service = new ComputerUseService(options(planner()));
  await assert.rejects(() => service.start({ instruction: "Read", initialURL: "https://example.com", allowedOrigins: ["https://example.com"], currentURL: "https://evil.example" }, new AbortController().signal), ComputerApprovalError);
});

test("allows any HTTP(S) browser state when the wildcard policy is selected", async () => {
  const service = new ComputerUseService(options(planner()));
  const started = await service.start({
    instruction: "Visit another site",
    initialURL: "https://example.com",
    allowedOrigins: ["*"],
    currentURL: "https://another.example/path",
    currentTitle: "Another site",
  }, new AbortController().signal);
  assert.equal(started.step?.status, "pending");
});
