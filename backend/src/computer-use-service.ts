import {
  ComputerApprovalError,
  ComputerPolicyBlockedError,
  ComputerSessionNotFoundError,
  type ComputerCodePlan,
  type ComputerGuardrail,
  type ComputerRisk,
  type ComputerSession,
  type ComputerSessionRepository,
  type ComputerStep,
  type ComputerPlanner,
  hashBrowserState,
  hashComputerCode,
  newComputerSession,
} from "./computer-use.js";
import { randomUUID } from "node:crypto";
import { ProviderFailureError } from "./errors.js";

export interface StartComputerUseInput {
  instruction: string;
  initialURL: string;
  allowedOrigins: string[];
  currentURL?: string;
  currentTitle?: string;
}

export interface ComputerStepResponse {
  session: ComputerSession;
  step?: ComputerStep;
  done?: boolean;
  message?: string;
  guardrailReasons?: string[];
}

export interface SubmitComputerResultInput {
  sessionId: string;
  stepId: string;
  result: unknown;
  screenshot: Buffer;
  currentURL?: string;
  currentTitle?: string;
}

export interface ComputerUseServiceOptions {
  repository: ComputerSessionRepository;
  planner: ComputerPlanner;
  guardrail: ComputerGuardrail;
  maxIterations: number;
  maxTaskDurationMs: number;
  maxRegenerationsPerStep: number;
  maxScreenshotBytes: number;
  approvalTimeoutMs: number;
}

export class ComputerUseService {
  constructor(private readonly options: ComputerUseServiceOptions) {}

  async start(
    input: StartComputerUseInput,
    signal: AbortSignal,
  ): Promise<ComputerStepResponse> {
    if (!input.instruction.trim() || input.instruction.length > 20_000) {
      throw new ProviderFailureError();
    }
    const session = newComputerSession(
      input.instruction.trim(),
      input.initialURL,
      input.allowedOrigins,
      Date.now(),
      this.options.maxTaskDurationMs,
    );
    this.validateBrowserState(session, input.currentURL, input.currentTitle);
    await this.options.repository.createSession(session);
    const planned = await this.planWithGuardrail(
      session,
      await this.options.planner.start(session.instruction, signal),
      signal,
      input.currentURL,
      input.currentTitle,
    );
    if ("done" in planned) {
      await this.options.repository.updateSession(session.id, {
        status: "completed",
        responseId: planned.responseId,
      });
      return { session: { ...session, status: "completed", responseId: planned.responseId }, done: true, message: planned.message };
    }
    return this.persistPlan(session, planned.plan, planned.risk, planned.reasons, input.currentURL, input.currentTitle);
  }

  async approve(
    sessionId: string,
    stepId: string,
    codeHash: string,
    browserStateHash: string,
  ): Promise<ComputerStepResponse> {
    const session = await this.requireSession(sessionId);
    const step = await this.requireStep(sessionId, stepId);
    if (step.status !== "awaiting_approval") {
      throw new ComputerApprovalError("This step is not waiting for approval.");
    }
    if (step.codeHash !== codeHash) {
      throw new ComputerApprovalError("The approval does not match the generated code.");
    }
    if (step.browserStateHash !== browserStateHash) {
      throw new ComputerApprovalError("The approval does not match the current browser state.");
    }
    if (!step.approvalExpiresAt || step.approvalExpiresAt <= Date.now()) {
      throw new ComputerApprovalError("The approval request has expired.");
    }
    await this.options.repository.updateStep(sessionId, stepId, { status: "pending" });
    await this.options.repository.updateSession(sessionId, { status: "active" });
    return {
      session: { ...session, status: "active", currentStepId: stepId },
      step: { ...step, status: "pending" },
    };
  }

  async deny(sessionId: string, stepId: string): Promise<ComputerStepResponse> {
    const session = await this.requireSession(sessionId);
    const step = await this.requireStep(sessionId, stepId);
    if (step.status !== "awaiting_approval") {
      throw new ComputerApprovalError("This step is not waiting for approval.");
    }
    await this.options.repository.updateStep(sessionId, stepId, { status: "denied" });
    await this.options.repository.updateSession(sessionId, { status: "cancelled" });
    return {
      session: { ...session, status: "cancelled" },
      step: { ...step, status: "denied" },
    };
  }

  async submitResult(
    input: SubmitComputerResultInput,
    signal: AbortSignal,
  ): Promise<ComputerStepResponse> {
    if (input.screenshot.length > this.options.maxScreenshotBytes) {
      throw new ProviderFailureError();
    }
    const session = await this.requireSession(input.sessionId);
    this.validateBrowserState(session, input.currentURL, input.currentTitle);
    const step = await this.requireStep(input.sessionId, input.stepId);
    if (step.status !== "pending") {
      throw new ComputerApprovalError("This step is not ready for execution results.");
    }
    if (session.iterationCount >= this.options.maxIterations) {
      await this.options.repository.updateSession(session.id, { status: "failed" });
      throw new ComputerApprovalError("The computer-use task reached its iteration limit.");
    }

    await this.options.repository.updateStep(session.id, step.id, {
      status: "completed",
      result: input.result,
      currentURL: input.currentURL,
      currentTitle: input.currentTitle,
      screenshotBytes: input.screenshot.length,
    });
    await this.options.repository.updateSession(session.id, {
      iterationCount: session.iterationCount + 1,
    });

    const planned = await this.planWithGuardrail(
      session,
      await this.options.planner.continue(
        session.responseId ?? "",
        step.callId,
        input.result,
        input.screenshot,
        signal,
      ),
      signal,
      input.currentURL,
      input.currentTitle,
    );
    if ("done" in planned) {
      await this.options.repository.updateSession(session.id, {
        status: "completed",
        responseId: planned.responseId,
      });
      return {
        session: { ...session, status: "completed", responseId: planned.responseId },
        done: true,
        message: planned.message,
      };
    }
    return this.persistPlan(
      session,
      planned.plan,
      planned.risk,
      planned.reasons,
      input.currentURL,
      input.currentTitle,
      session.iterationCount + 1,
    );
  }

  async cancel(sessionId: string): Promise<void> {
    const session = await this.requireSession(sessionId);
    await this.options.repository.updateSession(session.id, { status: "cancelled" });
  }

  private async planWithGuardrail(
    session: ComputerSession,
    initial: ComputerCodePlan & { responseId: string } | { done: true; message: string; responseId: string },
    signal: AbortSignal,
    currentURL?: string,
    currentTitle?: string,
  ): Promise<
    | { done: true; message: string; responseId: string }
    | { plan: ComputerCodePlan & { responseId: string }; risk: ComputerRisk; reasons: string[] }
  > {
    let candidate = initial;
    for (let attempt = 0; attempt <= this.options.maxRegenerationsPerStep; attempt += 1) {
      if ("done" in candidate) {
        return candidate;
      }
      const evaluation = await this.options.guardrail.evaluate({
        instruction: session.instruction,
        code: candidate.code,
        summary: candidate.summary,
        currentURL,
        currentTitle,
        signal,
      });
      if (evaluation.risk !== "prohibited") {
        return { plan: candidate, risk: evaluation.risk, reasons: evaluation.reasons };
      }
      if (attempt === this.options.maxRegenerationsPerStep) {
        await this.options.repository.updateSession(session.id, { status: "failed" });
        throw new ComputerPolicyBlockedError();
      }
      await this.options.repository.updateSession(session.id, {
        regenerationCount: session.regenerationCount + 1,
      });
      candidate = await this.options.planner.continue(
        candidate.responseId,
        candidate.callId,
        { guardrail: "prohibited", reasons: evaluation.reasons },
        Buffer.alloc(0),
        signal,
      );
    }
    throw new ComputerPolicyBlockedError();
  }

  private async persistPlan(
    session: ComputerSession,
    plan: ComputerCodePlan & { responseId: string },
    risk: ComputerRisk,
    reasons: string[],
    currentURL?: string,
    currentTitle?: string,
    completedIterations = session.iterationCount,
  ): Promise<ComputerStepResponse> {
    if (completedIterations >= this.options.maxIterations) {
      await this.options.repository.updateSession(session.id, { status: "failed" });
      throw new ComputerApprovalError("The computer-use task reached its iteration limit.");
    }
    if (session.taskExpiresAt <= Date.now()) {
      await this.options.repository.updateSession(session.id, { status: "failed" });
      throw new ComputerApprovalError("The computer-use task exceeded its time limit.");
    }
    const now = Date.now();
    const step: ComputerStep = {
      id: randomUUID(),
      sessionId: session.id,
      callId: plan.callId,
      code: plan.code,
      codeHash: hashComputerCode(plan.code),
      browserStateHash: hashBrowserState(currentURL ?? session.initialURL, currentTitle ?? ""),
      summary: plan.summary,
      risk,
      status: risk === "needs_user_approval" ? "awaiting_approval" : "pending",
      createdAt: now,
      updatedAt: now,
      expiresAt: session.expiresAt,
      approvalExpiresAt: risk === "needs_user_approval" ? now + this.options.approvalTimeoutMs : undefined,
    };
    await this.options.repository.createStep(step);
    await this.options.repository.updateSession(session.id, {
      responseId: plan.responseId,
      callId: plan.callId,
      currentStepId: step.id,
      status: step.status === "awaiting_approval" ? "awaiting_approval" : "active",
    });
    return {
      session: {
        ...session,
        responseId: plan.responseId,
        callId: plan.callId,
        currentStepId: step.id,
        status: step.status === "awaiting_approval" ? "awaiting_approval" : "active",
      },
      step,
      guardrailReasons: reasons,
    };
  }

  private validateBrowserState(session: ComputerSession, currentURL?: string, currentTitle?: string): void {
    if (currentTitle && currentTitle.length > 10_000) {
      throw new ComputerApprovalError("The browser title is too large.");
    }
    if (!currentURL) return;
    try {
      const url = new URL(currentURL);
      if (!session.allowedOrigins.includes(url.origin)) throw new Error();
    } catch {
      throw new ComputerApprovalError("The browser reported a URL outside the allowed origins.");
    }
  }

  private async requireSession(id: string): Promise<ComputerSession> {
    const session = await this.options.repository.getSession(id);
    if (!session || session.expiresAt <= Date.now()) {
      throw new ComputerSessionNotFoundError();
    }
    if (session.taskExpiresAt <= Date.now()) {
      await this.options.repository.updateSession(id, { status: "failed" });
      throw new ComputerApprovalError("The computer-use task exceeded its time limit.");
    }
    if (["completed", "cancelled", "failed"].includes(session.status)) {
      throw new ComputerApprovalError("This computer-use session is no longer active.");
    }
    return session;
  }

  private async requireStep(sessionId: string, stepId: string): Promise<ComputerStep> {
    const step = await this.options.repository.getStep(sessionId, stepId);
    if (!step) {
      throw new ComputerSessionNotFoundError();
    }
    return step;
  }
}
