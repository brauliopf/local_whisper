export interface TrackedPage {
  once(event: "close", listener: () => void): void;
  close(): Promise<void>;
}

export type PageRole = "primary" | "auxiliary" | "rejected";

/** Owns the primary page and the single optional user-controlled auxiliary page. */
export class BrowserPageTracker<T extends TrackedPage> {
  private primaryPage: T | undefined;
  private auxiliaryPage: T | undefined;
  private primaryCloseAttached = false;

  constructor(private readonly onPrimaryClosed: (page: T) => void) {}

  get primary(): T | undefined {
    return this.primaryPage;
  }

  get auxiliary(): T | undefined {
    return this.auxiliaryPage;
  }

  observe(page: T): PageRole {
    if (this.primaryPage === page) return "primary";
    if (this.auxiliaryPage === page) return "auxiliary";
    if (!this.primaryPage) {
      this.primaryPage = page;
      return "primary";
    }
    if (!this.auxiliaryPage) {
      this.auxiliaryPage = page;
      page.once("close", () => {
        if (this.auxiliaryPage === page) this.auxiliaryPage = undefined;
      });
      return "auxiliary";
    }
    void page.close().catch(() => undefined);
    return "rejected";
  }

  claimPrimary(page: T): void {
    if (this.primaryPage && this.primaryPage !== page) return;
    this.primaryPage = page;
    if (this.primaryCloseAttached) return;
    this.primaryCloseAttached = true;
    page.once("close", () => {
      if (this.primaryPage !== page) return;
      this.primaryPage = undefined;
      this.auxiliaryPage = undefined;
      this.onPrimaryClosed(page);
    });
  }

  clear(): void {
    this.primaryPage = undefined;
    this.auxiliaryPage = undefined;
    this.primaryCloseAttached = false;
  }
}
