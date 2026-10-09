import OpenAI from "openai";
import { ProviderAuthenticationError, ProviderFailureError, ProviderTimeoutError } from "./errors.js";

export type BrowserPlan =
  | { type: "click"; target: string; requiresConfirmation: boolean; summary?: string }
  | { type: "scroll"; direction: "up" | "down"; requiresConfirmation: false }
  | { type: "read"; target?: string; requiresConfirmation: false }
  | { type: "wait"; milliseconds: number; requiresConfirmation: false };

export interface BrowserPlanner {
  plan(command: string, context: { title: string; text: string }, signal: AbortSignal): Promise<BrowserPlan>;
}

const instructions = [
  "Choose exactly one browser action from click, scroll, read, or wait.",
  "Do not navigate, enter credentials, enter PII, submit forms, or execute code.",
  "Return JSON only with the action fields and requiresConfirmation.",
  "Click actions require confirmation when they may cause an external side effect.",
].join(" ");

function parsePlan(value: unknown): BrowserPlan {
  if (!value || typeof value !== "object") throw new ProviderFailureError();
  const plan = value as Record<string, unknown>;
  if (plan.type === "click" && typeof plan.target === "string") {
    return {
      type: "click",
      target: plan.target,
      requiresConfirmation: plan.requiresConfirmation === true,
      ...(typeof plan.summary === "string" ? { summary: plan.summary } : {}),
    };
  }
  if (plan.type === "scroll" && (plan.direction === "up" || plan.direction === "down")) {
    return { type: "scroll", direction: plan.direction, requiresConfirmation: false };
  }
  if (plan.type === "read") {
    return {
      type: "read",
      ...(typeof plan.target === "string" ? { target: plan.target } : {}),
      requiresConfirmation: false,
    };
  }
  if (plan.type === "wait" && typeof plan.milliseconds === "number" && Number.isSafeInteger(plan.milliseconds) && plan.milliseconds > 0 && plan.milliseconds <= 30_000) {
    return { type: "wait", milliseconds: plan.milliseconds, requiresConfirmation: false };
  }
  throw new ProviderFailureError();
}

export class OpenAIBrowserPlanner implements BrowserPlanner {
  constructor(
    private readonly client: OpenAI,
    private readonly model: string,
  ) {}

  async plan(command: string, context: { title: string; text: string }, signal: AbortSignal): Promise<BrowserPlan> {
    let response: OpenAI.Responses.Response;
    try {
      response = await this.client.responses.create({
        model: this.model,
        instructions,
        input: JSON.stringify({ command, page: context }),
      }, { signal });
    } catch (error) {
      if (error instanceof Error && (error.name === "AbortError" || error.name === "APIConnectionTimeoutError")) {
        throw new ProviderTimeoutError();
      }
      if (typeof error === "object" && error !== null && "status" in error && error.status === 401) {
        throw new ProviderAuthenticationError();
      }
      throw new ProviderFailureError();
    }

    try {
      return parsePlan(JSON.parse(response.output_text ?? ""));
    } catch (error) {
      if (error instanceof ProviderFailureError) throw error;
      throw new ProviderFailureError();
    }
  }
}
