// §7.1 tells client developers to send a UUID v4, and this accepts any well-formed
// UUID rather than only that version. The column behind it is `uuid` (§5.2.1), so a
// v7 key is exactly as unique and as usable for the replay lookup; refusing one would
// turn a client's choice of UUID library into a 400 that buys nothing. What the shape
// check is for is the cast: an `Idempotency-Key` that is not a UUID would otherwise
// reach Postgres and raise, which §7.4 could only answer as a retryable INTERNAL.
export const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export const IDEMPOTENCY_KEY_HEADER = "Idempotency-Key";
