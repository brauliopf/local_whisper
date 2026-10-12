export interface RedactedControl {
  tag: string;
  type?: string;
  label?: string;
  name?: string;
  value: string;
}

const sensitivePattern = /password|passcode|otp|one[-_ ]?time|token|secret|api[-_ ]?key|credit|card|cvv|cvc|security code|auth|username|email|e-mail/i;
const emailPattern = /\b[\w.+-]+@[\w.-]+\.[A-Za-z]{2,}\b/g;
const cardPattern = /\b(?:\d[ -]*?){13,19}\b/g;
const bearerPattern = /\bBearer\s+[A-Za-z0-9._~+/=-]+/gi;
const jwtPattern = /\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b/g;

export function isSensitiveControl(control: {
  type?: string | null;
  name?: string | null;
  autocomplete?: string | null;
  label?: string | null;
}): boolean {
  const type = control.type?.toLowerCase() ?? "";
  if (["password", "hidden"].includes(type)) return true;
  return [control.name, control.autocomplete, control.label]
    .filter((value): value is string => Boolean(value))
    .some((value) => sensitivePattern.test(value));
}

export function redactText(value: string): string {
  return value
    .replace(emailPattern, "[REDACTED_EMAIL]")
    .replace(cardPattern, "[REDACTED_PAYMENT]")
    .replace(bearerPattern, "Bearer [REDACTED_TOKEN]")
    .replace(jwtPattern, "[REDACTED_TOKEN]");
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
    label: control.label ? redactText(control.label) : undefined,
    name: control.name ? redactText(control.name) : undefined,
    value: sensitive ? "[REDACTED]" : redactText(control.value ?? ""),
  };
}

export interface PageSnapshot {
  url: string;
  title: string;
  visibleText: string;
  controls: RedactedControl[];
}
