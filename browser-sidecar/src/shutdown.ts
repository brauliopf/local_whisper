const closePromises = new WeakMap<object, Promise<void>>();

async function closeOnce<T extends object>(browser: T, close: (browser: T) => Promise<void>): Promise<void> {
  const existing = closePromises.get(browser);
  if (existing) {
    await existing;
    return;
  }
  const closing = close(browser).catch(() => undefined);
  closePromises.set(browser, closing);
  await closing;
}

export async function awaitAndClose<T extends object>(
  pendingLaunch: Promise<T> | undefined,
  ownedBrowser: T | undefined,
  close: (browser: T) => Promise<void>,
): Promise<void> {
  const launchedBrowser = pendingLaunch ? await pendingLaunch.catch(() => undefined) : undefined;
  if (ownedBrowser !== undefined) await closeOnce(ownedBrowser, close);
  if (launchedBrowser !== undefined && launchedBrowser !== ownedBrowser) {
    await closeOnce(launchedBrowser, close);
  }
}
