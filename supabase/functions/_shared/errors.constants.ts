// §7.4. `retryable` says whether the identical request may succeed later with nothing
// changed by the caller — these four failed for a reason outside the request itself.
// §7.1 fixes ACTIVITY_FULL as false, so an answer about the world the caller has to
// accept is not retryable even though a place may later free up.
export const ERRORS = {
  VALIDATION_FAILED: { status: 400, retryable: false, message: "A field is missing or malformed." },
  UNAUTHENTICATED: { status: 401, retryable: false, message: "Sign in to continue." },
  ONBOARDING_REQUIRED: {
    status: 403,
    retryable: false,
    message: "Finish onboarding before writing.",
  },
  AGE_RESTRICTED: {
    status: 403,
    retryable: false,
    message: "Organising activities requires you to be 18 or older.",
  },
  FORBIDDEN: { status: 403, retryable: false, message: "You cannot do that." },
  NOT_FOUND: { status: 404, retryable: false, message: "Not found." },
  ACTIVITY_FULL: {
    status: 409,
    retryable: false,
    message: "This activity has reached its capacity.",
  },
  ACTIVITY_NOT_JOINABLE: {
    status: 409,
    retryable: false,
    message: "This activity cannot be joined.",
  },
  IDEMPOTENCY_KEY_REUSED: {
    status: 422,
    retryable: false,
    message: "This idempotency key was already used with a different body.",
  },
  EVIDENCE_REQUIRED: {
    status: 422,
    retryable: false,
    message: "Claiming impact needs at least one photo.",
  },
  METRIC_OUT_OF_RANGE: {
    status: 422,
    retryable: false,
    message: "A claimed value exceeds the maximum for one act.",
  },
  DAILY_LIMIT_REACHED: {
    status: 429,
    retryable: true,
    message: "You have reached today's limit. Try again tomorrow.",
  },
  RATE_LIMITED: { status: 429, retryable: true, message: "Too many requests. Slow down." },
  FEATURE_DISABLED: {
    status: 503,
    retryable: true,
    message: "This feature is temporarily switched off.",
  },
  INTERNAL: { status: 500, retryable: true, message: "Something went wrong." },
} as const;

export const RETRY_AFTER_HEADER = "Retry-After";
