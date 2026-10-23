import { createHash } from "node:crypto";

export interface SemanticNode {
  kind: string;
  role?: string;
  name?: string;
  label?: string;
  text?: string;
  href?: string;
  type?: string;
  autocomplete?: string;
  value?: string;
  checked?: boolean;
  selected?: boolean;
  disabled?: boolean;
  level?: number;
}

export interface PageSnapshot {
  url: string;
  title: string;
  nodes: SemanticNode[];
  stateHash: string;
  truncated?: boolean;
}

export const MAX_SNAPSHOT_BYTES = 64_000;
export const MAX_SEMANTIC_NODES = 500;
const MAX_FIELD_LENGTH = 500;

const sensitivePattern = /password|passcode|otp|one[-_ ]?time|verification|token|secret|api[-_ ]?key|credit|card|cvv|cvc|security code|auth|username|user[-_ ]?name|email|e-mail/i;
const sensitiveAutocompletePattern = /^(?:current-password|new-password|one-time-code|cc-number|cc-exp|cc-exp-month|cc-exp-year|cc-csc|username|email)$/i;
const emailPattern = /\b[\w.+-]+@[\w.-]+\.[A-Za-z]{2,}\b/g;
const cardPattern = /\b(?:\d[ -]*?){13,19}\b/g;
const bearerPattern = /\bBearer\s+[A-Za-z0-9._~+/=-]+/gi;
const jwtPattern = /\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b/g;
const labeledCodePattern = /\b(?:otp|one[-_ ]?time|verification|security)(?:\s+(?:code|number))?\s*[:=-]?\s*\d{4,8}\b/gi;
const labeledIdentityPattern = /\b(?:username|user[-_ ]?name|email|e-mail)\s*[:=-]?\s*\S+/gi;
const labeledSecretPattern = /\b(?:password|passcode|secret|token|api[-_ ]?key|cvv|cvc|security code)\s*[:=-]?\s*\S+/gi;

function limit(value: string | undefined): string | undefined {
  if (!value) return undefined;
  return value.length > MAX_FIELD_LENGTH ? `${value.slice(0, MAX_FIELD_LENGTH)}…` : value;
}

export function isSensitiveControl(control: {
  type?: string | null;
  name?: string | null;
  autocomplete?: string | null;
  label?: string | null;
}): boolean {
  const type = control.type?.toLowerCase() ?? "";
  if (["password", "hidden", "email"].includes(type)) return true;
  if (control.autocomplete && sensitiveAutocompletePattern.test(control.autocomplete)) return true;
  return [control.name, control.autocomplete, control.label]
    .filter((value): value is string => Boolean(value))
    .some((value) => sensitivePattern.test(value));
}

export function redactText(value: string): string {
  return value
    .replace(emailPattern, "[REDACTED_EMAIL]")
    .replace(cardPattern, "[REDACTED_PAYMENT]")
    .replace(bearerPattern, "Bearer [REDACTED_TOKEN]")
    .replace(jwtPattern, "[REDACTED_TOKEN]")
    .replace(labeledCodePattern, "[REDACTED_CODE]")
    .replace(labeledIdentityPattern, "[REDACTED_IDENTITY]")
    .replace(labeledSecretPattern, "[REDACTED_SECRET]");
}

export function redactSemanticNode(node: SemanticNode): SemanticNode {
  const sensitive = isSensitiveControl({
    type: node.type,
    name: node.name,
    autocomplete: node.autocomplete,
    label: node.label,
  });
  const redact = (value: string | undefined): string | undefined => limit(value ? redactText(value) : undefined);
  return {
    kind: node.kind,
    role: redact(node.role),
    name: sensitive ? "[REDACTED]" : redact(node.name),
    label: sensitive ? "[REDACTED]" : redact(node.label),
    text: sensitive ? "[REDACTED]" : redact(node.text),
    href: node.href ? sanitizeURL(node.href) : undefined,
    type: redact(node.type),
    autocomplete: sensitive ? "[REDACTED]" : redact(node.autocomplete),
    value: sensitive ? "[REDACTED]" : redact(node.value),
    checked: node.checked,
    selected: node.selected,
    disabled: node.disabled,
    level: node.level,
  };
}

export function redactPageSnapshot(input: Omit<PageSnapshot, "stateHash">): Omit<PageSnapshot, "stateHash"> {
  let nodes = input.nodes.slice(0, MAX_SEMANTIC_NODES).map(redactSemanticNode);
  let truncated = Boolean(input.truncated) || nodes.length < input.nodes.length;
  let result: Omit<PageSnapshot, "stateHash"> = {
    url: sanitizeURL(input.url),
    title: redactText(input.title).slice(0, MAX_FIELD_LENGTH),
    nodes,
    ...(truncated ? { truncated: true } : {}),
  };
  while (Buffer.byteLength(JSON.stringify(result), "utf8") > MAX_SNAPSHOT_BYTES && nodes.length > 0) {
    nodes = nodes.slice(0, -1);
    truncated = true;
    result = { ...result, nodes, truncated: true };
  }
  return result;
}

export function buildPageSnapshot(input: Omit<PageSnapshot, "stateHash">): PageSnapshot {
  const redacted = redactPageSnapshot(input);
  return {
    ...redacted,
    stateHash: createHash("sha256").update(JSON.stringify(redacted)).digest("hex"),
  };
}

export function sanitizeURL(value: string): string {
  try {
    const url = new URL(value);
    if (url.protocol === "about:") return value.split(/[?#]/, 1)[0] === "about:blank" ? "about:blank" : "[REDACTED_URL]";
    if (url.protocol !== "http:" && url.protocol !== "https:") return "[REDACTED_URL]";
    const path = url.pathname === "/" ? "/" : "/[REDACTED_PATH]";
    return `${url.origin}${path}${url.search ? "?[REDACTED_QUERY]" : ""}`;
  } catch {
    return "[REDACTED_URL]";
  }
}
