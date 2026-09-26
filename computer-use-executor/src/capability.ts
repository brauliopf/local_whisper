import type { Page } from "playwright";

const blockedProperties = new Set([
  "browser",
  "context",
  "cookies",
  "storageState",
  "addInitScript",
  "evaluate",
  "evaluateAll",
  "evaluateHandle",
  "screenshot",
  "route",
  "unroute",
  "on",
  "once",
  "addListener",
  "removeListener",
  "request",
  "page",
  "frame",
  "contentFrame",
  "workers",
  "serviceWorkers",
  "waitForRequest",
  "waitForResponse",
  "exposeFunction",
  "exposeBinding",
  "setContent",
  "close",
  "waitForEvent",
  "constructor",
  "prototype",
  "__proto__",
]);

const cache = new WeakMap<object, unknown>();

export function createPageCapability(page: Page, allowedOrigins: string[]): Page {
  return wrap(page, allowedOrigins) as Page;
}

function wrap(value: unknown, allowedOrigins: string[]): unknown {
  if (
    value === null ||
    typeof value !== "object" ||
    value instanceof Promise ||
    value instanceof Buffer
  ) {
    return value;
  }
  if (Array.isArray(value)) {
    return value.map(item => wrap(item, allowedOrigins));
  }
  const existing = cache.get(value);
  if (existing) return existing;
  const proxy = new Proxy(value as object, {
    get(target, property, receiver) {
      if (
        typeof property === "string" &&
        (blockedProperties.has(property) || property.startsWith("_"))
      ) {
        throw new Error(`The browser capability does not expose ${property}.`);
      }
      const propertyValue = Reflect.get(target, property, receiver);
      if (typeof propertyValue !== "function") {
        return wrap(propertyValue, allowedOrigins);
      }
      return (...args: unknown[]) => {
        if (property === "goto" && typeof args[0] === "string") {
          const targetURL = new URL(args[0]);
          if (!allowedOrigins.includes(targetURL.origin)) {
            throw new Error(`Navigation outside the allowed origins: ${targetURL.origin}`);
          }
        }
        const result = propertyValue.apply(target, args);
        if (result && typeof result.then === "function") {
          return result.then((resolved: unknown) => wrap(resolved, allowedOrigins));
        }
        return wrap(result, allowedOrigins);
      };
    },
  });
  cache.set(value, proxy);
  return proxy;
}
