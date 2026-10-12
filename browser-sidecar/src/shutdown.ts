export async function awaitAndClose<T>(
  pendingLaunch: Promise<T> | undefined,
  ownedBrowser: T | undefined,
  close: (browser: T) => Promise<void>,
): Promise<void> {
  const launchedBrowser = pendingLaunch ? await pendingLaunch.catch(() => undefined) : undefined;
  if (ownedBrowser !== undefined) await close(ownedBrowser);
  if (launchedBrowser !== undefined && launchedBrowser !== ownedBrowser) {
    await close(launchedBrowser);
  }
}
