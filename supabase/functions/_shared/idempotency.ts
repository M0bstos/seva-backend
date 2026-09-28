import { IDEMPOTENCY_KEY_HEADER, UUID_PATTERN } from "./idempotency.constants.ts";

// §7.1.1: `acts`, `activities` and `reports` each store an `idempotency_key` beside a
// `request_hash` — "the SHA-256 hex of the **validated** input, serialised with sorted
// keys, computed in the Edge Function with Web Crypto". Three routes answering to one
// algorithm is why it lives here: a route that serialised differently would hash the
// same request two ways, and §7.1.1's "same key, different hash" would then reject a
// retry as `IDEMPOTENCY_KEY_REUSED`.

// null means the header is missing or not a UUID, which the route answers as
// VALIDATION_FAILED naming this header (§7.4).
export function idempotencyKey(headers: Headers): string | null {
  const key = headers.get(IDEMPOTENCY_KEY_HEADER)?.trim();
  return key && UUID_PATTERN.test(key) ? key : null;
}

// Sorted keys at every depth, so two requests that differ only in the order their
// fields were written hash the same. Arrays keep their order: `photo_ids` carries the
// before-and-after sequence §8.1 stores as `position`, so reordering it is a different
// request rather than the same one spelled differently.
export async function requestHash(input: Record<string, unknown>): Promise<string> {
  const bytes = new TextEncoder().encode(JSON.stringify(sortKeys(input)));
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return Array.from(new Uint8Array(digest), (b) => b.toString(16).padStart(2, "0")).join("");
}

// Callers hand this flat input. The recursion is one frame per nesting level and
// overflows the stack somewhere between 1,000 and 5,000 — measured — and it runs while
// a route builds its RPC arguments, so an overflow means the Postgres call is never
// made and the limiter never reached, which §12.2's D5 note refuses. `_shared/fields.ts`
// is where that is enforced today, because `metrics` is the only nested field any route
// accepts; a route that hashes a deeper one has to bound it there.
function sortKeys(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(sortKeys);
  if (value === null || typeof value !== "object") return value;

  const source = value as Record<string, unknown>;
  const sorted: Record<string, unknown> = {};
  for (const key of Object.keys(source).sort()) sorted[key] = sortKeys(source[key]);
  return sorted;
}
