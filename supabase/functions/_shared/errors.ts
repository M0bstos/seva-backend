import { ERRORS, RETRY_AFTER_HEADER } from "./errors.constants.ts";

export type ErrorCode = keyof typeof ERRORS;

// §7.1 attaches Retry-After to the 429s, so the seconds are an argument a route
// cannot forget rather than an option it may leave out.
type ThrottledCode = "RATE_LIMITED" | "DAILY_LIMIT_REACHED";

export function fail(code: ThrottledCode, retryAfterSeconds: number): Response;
// §7.4: "A field is missing or malformed. `message` names it." The caller passes the
// field, never a sentence, so no request value can reach a client as free text (§9.8).
export function fail(code: "VALIDATION_FAILED", field: string): Response;
export function fail(code: Exclude<ErrorCode, ThrottledCode | "VALIDATION_FAILED">): Response;
export function fail(code: ErrorCode, detail?: string | number): Response {
  const known = ERRORS[code];
  const headers = new Headers();

  // Both branches key off the code, not off what was passed, so the overloads above
  // and the behaviour here cannot drift apart: a message handed to any other code is
  // ignored rather than echoed.
  if (code === "RATE_LIMITED" || code === "DAILY_LIMIT_REACHED") {
    const seconds = typeof detail === "number" ? detail : 1;
    headers.set(RETRY_AFTER_HEADER, String(Math.max(1, Math.ceil(seconds))));
  }

  const message = code === "VALIDATION_FAILED" && typeof detail === "string"
    ? `${detail} is missing or malformed.`
    : known.message;

  return Response.json(
    { error: { code, message, retryable: known.retryable } },
    { status: known.status, headers },
  );
}
