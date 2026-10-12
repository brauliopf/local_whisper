export interface RedactedControl {
  tag: string;
  type?: string;
  label?: string;
  name?: string;
  value: string;
}

const sensitivePattern = /password|passcode|otp|one[-_ ]?time|verification|token|secret|api[-_ ]?key|credit|card|cvv|cvc|security code|auth|username|user[-_ ]?name|email|e-mail/i;
const sensitiveAutocompletePattern = /^(?:current-password|new-password|one-time-code|cc-number|cc-exp|cc-exp-month|cc-exp-year|cc-csc|username|email)$/i;
const emailPattern = /\b[\w.+-]+@[\w.-]+\.[A-Za-z]{2,}\b/g;
const cardPattern = /\b(?:\d[ -]*?){13,19}\b/g;
const bearerPattern = /\bBearer\s+[A-Za-z0-9._~+/=-]+/gi;
const jwtPattern = /\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b/g;
const labeledCodePattern = /\b(?:otp|one[-_ ]?time|verification|security)(?:\s+(?:code|number))?\s*[:=-]?\s*\d{4,8}\b/gi;
const labeledIdentityPattern = /\b(?:username|user[-_ ]?name|email|e-mail)\s*[:=-]?\s*\S+/gi;
const labeledSecretPattern = /\b(?:password|passcode|secret|token|api[-_ ]?key|cvv|cvc|security code)\s*[:=-]?\s+\S+/gi;

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

export function redactControl(control: {
  tag: string;
  type?: string | null;
  name?: string | null;
  autocomplete?: string | null;
  label?: string | null;
  value?: string | null;
}): RedactedControl {
  const sensitive = isSensitiveControl(control);
  return {
    tag: control.tag,
    type: control.type ?? undefined,
    label: sensitive ? "[REDACTED]" : (control.label ? redactText(control.label) : undefined),
    name: sensitive ? "[REDACTED]" : (control.name ? redactText(control.name) : undefined),
    value: sensitive ? "[REDACTED]" : redactText(control.value ?? ""),
  };
}

export interface PageSnapshot {
  url: string;
  title: string;
  controls: RedactedControl[];
  stateHash: string;
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
