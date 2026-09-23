export class FixedWindowRateLimiter {
  private readonly timestamps: number[] = [];

  constructor(
    private readonly maxRequests: number,
    private readonly windowMs: number,
  ) {}

  retryAfterSeconds(now = Date.now()): number | undefined {
    this.removeExpired(now);
    if (this.timestamps.length < this.maxRequests) {
      return undefined;
    }
    const oldest = this.timestamps[0];
    return Math.max(1, Math.ceil((oldest + this.windowMs - now) / 1000));
  }

  allow(now = Date.now()): boolean {
    this.removeExpired(now);
    if (this.timestamps.length >= this.maxRequests) {
      return false;
    }
    this.timestamps.push(now);
    return true;
  }

  private removeExpired(now: number): void {
    const cutoff = now - this.windowMs;
    while (this.timestamps[0] !== undefined && this.timestamps[0] <= cutoff) {
      this.timestamps.shift();
    }
  }
}
