import { parse } from "acorn";

export type BrowserViolation = {
  category: string;
  message: string;
};

export type ValidationResult = {
  valid: boolean;
  violations: BrowserViolation[];
};

const forbidden = /\b(?:browser|context|process|require|import|eval|Function|fetch|XMLHttpRequest|WebSocket|fs|child_process|page\.close|page\.evaluate|context\.close|browser\.close)\b/;
const allowedPageMethods = new Set(["goto", "locator", "getByRole", "getByText", "getByLabel", "click", "fill", "selectOption", "press", "wheel"]);
const allowedActions = new Set(["goto", "click", "fill", "selectOption", "press", "wheel"]);

function isString(node: any): node is { type: "Literal"; value: string } {
  return node?.type === "Literal" && typeof node.value === "string";
}

function memberChain(node: any): string[] | undefined {
  if (node?.type === "CallExpression") return memberChain(node.callee);
  const names: string[] = [];
  let current = node;
  while (current?.type === "MemberExpression" && !current.computed && current.property?.type === "Identifier") {
    names.unshift(current.property.name);
    current = current.object;
    if (current?.type === "CallExpression") current = current.callee;
  }
  if (current?.type !== "Identifier") return undefined;
  names.unshift(current.name);
  return names;
}

export function validateBrowserCode(code: string): ValidationResult {
  const violations: BrowserViolation[] = [];
  if (code.length === 0 || code.length > 50_000) {
    return { valid: false, violations: [{ category: "size", message: "Code is empty or too large." }] };
  }
  if (forbidden.test(code)) {
    violations.push({ category: "shutdown_or_runtime", message: "The script uses a forbidden browser, runtime, or shutdown API." });
  }

  let program: any;
  try {
    program = parse(code, { ecmaVersion: "latest", sourceType: "script", allowAwaitOutsideFunction: true });
  } catch {
    return { valid: false, violations: [{ category: "syntax", message: "The generated script is not valid JavaScript." }] };
  }

  const visit = (node: any): void => {
    if (!node || typeof node !== "object") return;
    if (["VariableDeclaration", "FunctionDeclaration", "FunctionExpression", "ArrowFunctionExpression", "WhileStatement", "ForStatement", "ForOfStatement", "ForInStatement", "UpdateExpression", "AssignmentExpression", "NewExpression", "TryStatement", "ThrowStatement"].includes(node.type)) {
      violations.push({ category: "unsupported_construct", message: `Unsupported JavaScript construct: ${node.type}.` });
    }
    if (node.type === "CallExpression") {
      const chain = memberChain(node.callee);
      const method = chain?.at(-1);
      if (!chain || chain[0] !== "page" || !method || !allowedPageMethods.has(method)) {
        violations.push({ category: "method", message: "Only approved single-page Playwright methods are allowed." });
      } else if (allowedActions.has(method)) {
        if (method === "goto") {
          const argument = node.arguments?.[0];
          if (!isString(argument) || !/^https?:\/\//i.test(argument.value)) {
            violations.push({ category: "target", message: "Navigation targets must be literal HTTP(S) URLs." });
          }
        }
        const selector = node.callee?.object?.type === "CallExpression" ? node.callee.object.arguments?.[0] : undefined;
        const selectorText = isString(selector) ? selector.value : "";
        if (method === "fill" && (!isString(node.arguments?.[1]) || /password|otp|token|secret|card|cvv|email|username/i.test(selectorText))) {
          violations.push({ category: "sensitive_input", message: "Sensitive or non-literal fields may not be filled." });
        }
      }
    }
    for (const [key, value] of Object.entries(node)) {
      if (key === "loc" || key === "start" || key === "end") continue;
      if (Array.isArray(value)) value.forEach(visit);
      else if (value && typeof value === "object") visit(value);
    }
  };
  visit(program);
  return { valid: violations.length === 0, violations };
}
