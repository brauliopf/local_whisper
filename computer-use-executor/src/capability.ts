import type { Locator, Page } from "playwright";

export type ScreenshotArtifact = {
  id: string;
  mimeType: "image/png";
  label: string;
};

export type ScreenshotCapability = (label: string) => Promise<ScreenshotArtifact>;

export type LocatorCapability = {
  click(): Promise<void>;
  fill(value: string): Promise<void>;
  press(key: string): Promise<void>;
  check(): Promise<void>;
  uncheck(): Promise<void>;
  selectOption(value: string): Promise<void>;
  hover(): Promise<void>;
  focus(): Promise<void>;
  textContent(): Promise<string | null>;
  innerText(): Promise<string>;
  inputValue(): Promise<string>;
  isVisible(): Promise<boolean>;
  isEnabled(): Promise<boolean>;
  count(): Promise<number>;
  waitFor(): Promise<void>;
};

export type PageCapability = {
  goto(url: string): Promise<void>;
  reload(): Promise<void>;
  goBack(): Promise<void>;
  goForward(): Promise<void>;
  url(): string;
  title(): Promise<string>;
  locator(selector: string): LocatorCapability;
  getByRole(role: string, options?: { name?: string }): LocatorCapability;
  getByLabel(label: string): LocatorCapability;
  getByText(text: string): LocatorCapability;
  getByPlaceholder(text: string): LocatorCapability;
  waitForLoadState(state?: "domcontentloaded" | "load"): Promise<void>;
};

export class CapabilityError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "CapabilityError";
  }
}

export function createPageCapability(page: Page, allowedOrigins: string[]): PageCapability {
  const assertAllowedURL = (url: string): void => {
    let parsed: URL;
    try {
      parsed = new URL(url);
    } catch {
      throw new CapabilityError("Navigation URL is invalid.");
    }
    if (!allowedOrigins.includes(parsed.origin)) {
      throw new CapabilityError(`Navigation outside the allowed origins: ${parsed.origin}`);
    }
  };

  const assertCurrentURL = (): void => {
    const currentURL = page.url();
    if (currentURL && !allowedOrigins.includes(new URL(currentURL).origin)) {
      throw new CapabilityError(`Navigation outside the allowed origins: ${new URL(currentURL).origin}`);
    }
  };

  const navigate = async (operation: () => Promise<unknown>): Promise<void> => {
    await operation();
    assertCurrentURL();
  };

  const capability = Object.create(null) as PageCapability;
  Object.assign(capability, {
    goto: protectCapabilityFunction(async (url: string): Promise<void> => {
      assertAllowedURL(url);
      await navigate(() => page.goto(url));
    }),
    reload: protectCapabilityFunction(async (): Promise<void> => {
      await navigate(() => page.reload());
    }),
    goBack: protectCapabilityFunction(async (): Promise<void> => {
      await navigate(() => page.goBack());
    }),
    goForward: protectCapabilityFunction(async (): Promise<void> => {
      await navigate(() => page.goForward());
    }),
    url: protectCapabilityFunction((): string => page.url()),
    title: protectCapabilityFunction((): Promise<string> => page.title()),
    locator: protectCapabilityFunction((selector: string): LocatorCapability =>
      wrapLocator(page.locator(selector))),
    getByRole: protectCapabilityFunction((role: string, options?: { name?: string }): LocatorCapability =>
      wrapLocator(page.getByRole(role as Parameters<Page["getByRole"]>[0], options))),
    getByLabel: protectCapabilityFunction((label: string): LocatorCapability =>
      wrapLocator(page.getByLabel(label))),
    getByText: protectCapabilityFunction((text: string): LocatorCapability =>
      wrapLocator(page.getByText(text))),
    getByPlaceholder: protectCapabilityFunction((text: string): LocatorCapability =>
      wrapLocator(page.getByPlaceholder(text))),
    waitForLoadState: protectCapabilityFunction((state?: "domcontentloaded" | "load"): Promise<void> =>
      page.waitForLoadState(state)),
  });
  return Object.freeze(capability);
}

export function protectCapabilityFunction<T extends (...args: any[]) => any>(value: T): T {
  return new Proxy(value, {
    get(target, property, receiver) {
      if (property === "length" || property === "name") {
        return Reflect.get(target, property, receiver);
      }
      throw new CapabilityError("Function metadata is not exposed by the browser capability.");
    },
  });
}

function wrapLocator(locator: Locator): LocatorCapability {
  const capability = Object.create(null) as LocatorCapability;
  Object.assign(capability, {
    click: protectCapabilityFunction(async (): Promise<void> => locator.click()),
    fill: protectCapabilityFunction(async (value: string): Promise<void> => locator.fill(value)),
    press: protectCapabilityFunction(async (key: string): Promise<void> => locator.press(key)),
    check: protectCapabilityFunction(async (): Promise<void> => locator.check()),
    uncheck: protectCapabilityFunction(async (): Promise<void> => locator.uncheck()),
    selectOption: protectCapabilityFunction(async (value: string): Promise<void> => {
      await locator.selectOption(value);
    }),
    hover: protectCapabilityFunction(async (): Promise<void> => locator.hover()),
    focus: protectCapabilityFunction(async (): Promise<void> => locator.focus()),
    textContent: protectCapabilityFunction((): Promise<string | null> => locator.textContent()),
    innerText: protectCapabilityFunction((): Promise<string> => locator.innerText()),
    inputValue: protectCapabilityFunction((): Promise<string> => locator.inputValue()),
    isVisible: protectCapabilityFunction((): Promise<boolean> => locator.isVisible()),
    isEnabled: protectCapabilityFunction((): Promise<boolean> => locator.isEnabled()),
    count: protectCapabilityFunction((): Promise<number> => locator.count()),
    waitFor: protectCapabilityFunction(async (): Promise<void> => locator.waitFor()),
  });
  return Object.freeze(capability);
}
