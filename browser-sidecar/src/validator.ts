import { parse } from "acorn";

export const BROWSER_POLICY_VERSION = "browser-navigation-v1";

export type BrowserViolation = {
  category: string;
  message: string;
};

export type ValidationResult = {
  valid: boolean;
  violations: BrowserViolation[];
};

const locatorFactories = new Set(["locator", "getByRole", "getByText", "getByLabel"]);
const actionMethods = new Set(["click", "fill", "selectOption", "press"]);
const allowedChains = new Set([
  "page.goto",
  "page.mouse.wheel",
]);
const allowedNodeTypes = new Set([
  "Program",
  "ExpressionStatement",
  "AwaitExpression",
  "CallExpression",
  "MemberExpression",
  "Identifier",
  "Literal",
  "ObjectExpression",
  "Property",
]);

function violation(category: string, message: string): BrowserViolation {
  return { category, message };
}

function isString(node: any): node is { type: "Literal"; value: string } {
  return node?.type === "Literal" && typeof node.value === "string";
}

function memberChain(node: any): string[] | undefined {
  if (node?.type === "CallExpression") return memberChain(node.callee);
  const names: string[] = [];
  let current = node;
  while (current?.type === "MemberExpression") {
    if (current.computed || current.property?.type !== "Identifier") return undefined;
    names.unshift(current.property.name);
    current = current.object;
    if (current?.type === "CallExpression") current = current.callee;
  }
  if (current?.type !== "Identifier") return undefined;
  names.unshift(current.name);
  return names;
}

function isIPv4(hostname: string): boolean {
  const parts = hostname.split(".").map(Number);
  return parts.length === 4 && parts.every((part) => Number.isInteger(part) && part >= 0 && part <= 255);
}

function ipv4InRange(hostname: string, prefix: number[], mask: number): boolean {
  if (!isIPv4(hostname)) return false;
  const parts = hostname.split(".").map(Number);
  let value = 0;
  let target = 0;
  for (let index = 0; index < 4; index += 1) {
    value = (value << 8) | parts[index];
    target = (target << 8) | (prefix[index] ?? 0);
  }
  const bits = mask === 0 ? 0 : (0xffffffff << (32 - mask)) >>> 0;
  return ((value >>> 0) & bits) === ((target >>> 0) & bits);
}

function isBlockedHost(hostname: string): boolean {
  const host = hostname.toLowerCase().replace(/^\[|\]$/g, "").replace(/\.+$/, "");
  if (host === "localhost" || host.endsWith(".localhost") || host === "broadcasthost") return true;
  if (host.includes(":")) {
    const normalized = host.replace(/^0+:/, "::");
    if (normalized === "::1" || normalized === "0:0:0:0:0:0:0:1") return true;
    const groups = host.split(":");
    const firstGroup = Number.parseInt(groups[0] || "0", 16);
    if (Number.isInteger(firstGroup) && ((firstGroup >= 0xfc00 && firstGroup <= 0xfdff) || (firstGroup >= 0xfe80 && firstGroup <= 0xfebf))) return true;
    const mapped = host.match(/^::ffff:(.+)$/);
    if (mapped) {
      const mappedHost = mapped[1].includes(".")
        ? mapped[1]
        : (() => {
            const groups = mapped[1].split(":");
            if (groups.length !== 2) return mapped[1];
            const high = Number.parseInt(groups[0], 16);
            const low = Number.parseInt(groups[1], 16);
            return Number.isInteger(high) && Number.isInteger(low)
              ? `${high >>> 8}.${high & 255}.${low >>> 8}.${low & 255}`
              : mapped[1];
          })();
      if (isBlockedHost(mappedHost)) return true;
    }
    return false;
  }
  return [
    [[0, 0, 0, 0], 8],
    [[10, 0, 0, 0], 8],
    [[100, 64, 0, 0], 10],
    [[127, 0, 0, 0], 8],
    [[169, 254, 0, 0], 16],
    [[172, 16, 0, 0], 12],
    [[192, 0, 0, 0], 24],
    [[192, 168, 0, 0], 16],
    [[198, 18, 0, 0], 15],
    [[198, 51, 100, 0], 24],
    [[203, 0, 113, 0], 24],
    [[224, 0, 0, 0], 4],
  ].some(([prefix, mask]) => ipv4InRange(host, prefix as number[], mask as number));
}

function safeNavigationURL(node: any): boolean {
  if (!isString(node)) return false;
  try {
    const url = new URL(node.value);
    return (url.protocol === "http:" || url.protocol === "https:") && !isBlockedHost(url.hostname);
  } catch {
    return false;
  }
}

function safeSearchLocator(node: any): boolean {
  if (node?.type !== "CallExpression" || node.callee?.type !== "MemberExpression" || node.callee.computed) return false;
  const factory = node.callee.property?.name;
  if (factory === "getByRole" && node.callee.object?.type === "Identifier" && node.callee.object.name === "page") {
    const role = node.arguments?.[0];
    return isString(role) && ["searchbox", "combobox"].includes(role.value.toLowerCase());
  }
  if (factory === "locator" && node.callee.object?.type === "Identifier" && node.callee.object.name === "page") {
    const selector = node.arguments?.[0];
    return isString(selector) && /(?:^|\s|\])input\s*\[\s*type\s*=\s*["']search["']\s*\]|\[\s*role\s*=\s*["']searchbox["']\s*\]/i.test(selector.value);
  }
  return false;
}

function validateCall(node: any, violations: BrowserViolation[]): void {
  const chain = memberChain(node.callee);
  if (!chain || chain[0] !== "page" || chain.some((name) => !/^[A-Za-z_$][\w$]*$/.test(name))) {
    violations.push(violation("method", "Only approved single-page Playwright methods are allowed."));
    return;
  }

  const chainText = chain.join(".");
  const method = chain.at(-1);
  const isFactory = chain.length === 2 && locatorFactories.has(method ?? "");
  const isAction = chain.length === 3 && locatorFactories.has(chain[1]) && actionMethods.has(method ?? "");
  if (!allowedChains.has(chainText) && !isFactory && !isAction) {
    violations.push(violation("method", "Only approved single-page Playwright methods are allowed."));
    return;
  }

  if (chainText === "page.goto" && !safeNavigationURL(node.arguments?.[0])) {
    violations.push(violation("target", "Navigation targets must be literal public HTTP(S) URLs."));
  }
  if (chainText === "page.mouse.wheel" && node.arguments?.length !== 2) {
    violations.push(violation("arguments", "Scrolling requires exactly two numeric arguments."));
  }
  if (isFactory && (!isString(node.arguments?.[0]) || (method === "getByRole" && !["searchbox", "combobox"].includes(node.arguments[0].value.toLowerCase())))) {
    violations.push(violation("selector", "Only safe, literal search-oriented locators are allowed."));
  }
  if (isAction) {
    const locatorCall = node.callee.object;
    const safeSearchField = chain[1] === "getByRole"
      ? true
      : safeSearchLocator(locatorCall);
    if ((method === "fill" || method === "press") && (!safeSearchField || (method === "fill" && !isString(node.arguments?.[0])))) {
      violations.push(violation("sensitive_input", "Only literal values for search-oriented fields may be filled."));
    }
    if (method === "selectOption" && (!isString(node.arguments?.[0]) || !safeSearchLocator(locatorCall))) {
      violations.push(violation("sensitive_input", "Only safe search-oriented controls may be selected."));
    }
  }
}

export function validateBrowserCode(code: string, policyVersion: string): ValidationResult {
  const violations: BrowserViolation[] = [];
  if (policyVersion !== BROWSER_POLICY_VERSION) {
    violations.push(violation("policy_version", "The browser policy version is unsupported."));
  }
  if (code.length === 0 || code.length > 50_000) {
    return { valid: false, violations: [...violations, violation("size", "Code is empty or too large.")] };
  }

  let program: any;
  try {
    program = parse(code, { ecmaVersion: "latest", sourceType: "script", allowAwaitOutsideFunction: true });
  } catch {
    return { valid: false, violations: [...violations, violation("syntax", "The generated script is not valid JavaScript.")] };
  }

  const visit = (node: any, isRoot = false): void => {
    if (!node || typeof node !== "object") return;
    if (!allowedNodeTypes.has(node.type)) {
      violations.push(violation("unsupported_construct", `Unsupported JavaScript construct: ${node.type}.`));
      return;
    }
    if (node.type === "MemberExpression" && node.computed) {
      violations.push(violation("computed_access", "Computed property access is not allowed."));
      return;
    }
    if (node.type === "CallExpression") validateCall(node, violations);
    for (const [key, value] of Object.entries(node)) {
      if (key === "loc" || key === "start" || key === "end") continue;
      if (Array.isArray(value)) value.forEach((item) => visit(item));
      else if (value && typeof value === "object") visit(value);
    }
  };
  visit(program, true);
  return { valid: violations.length === 0, violations };
}
