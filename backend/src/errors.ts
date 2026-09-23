export type ApiErrorCode =
  | "authentication_failed"
  | "invalid_input"
  | "unsupported_file"
  | "file_too_large"
  | "rate_limited"
  | "provider_timeout"
  | "provider_authentication"
  | "provider_failure"
  | "internal_error";

export class ApiError extends Error {
  constructor(
    readonly statusCode: number,
    readonly code: ApiErrorCode,
    readonly publicMessage: string,
    readonly retryAfterSeconds?: number,
  ) {
    super(publicMessage);
    this.name = "ApiError";
  }
}

export class ProviderTimeoutError extends Error {
  constructor() {
    super("The provider request timed out");
    this.name = "ProviderTimeoutError";
  }
}

export class ProviderAuthenticationError extends Error {
  constructor() {
    super("The provider rejected its credentials");
    this.name = "ProviderAuthenticationError";
  }
}

export class ProviderFailureError extends Error {
  constructor() {
    super("The provider request failed");
    this.name = "ProviderFailureError";
  }
}
