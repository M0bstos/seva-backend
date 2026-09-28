import { assertEquals, assertNotEquals } from "jsr:@std/assert@1.0.19";
import { idempotencyKey, requestHash } from "./idempotency.ts";

function headers(value?: string): Headers {
  return new Headers(value === undefined ? {} : { "Idempotency-Key": value });
}

Deno.test("a create needs a UUID in the header (§7.1)", () => {
  const key = "3f2504e0-4f89-41d3-9a0c-0305e82c3301";
  assertEquals(idempotencyKey(headers(key)), key);
  assertEquals(idempotencyKey(headers(` ${key} `)), key);
  assertEquals(idempotencyKey(headers()), null);
  assertEquals(idempotencyKey(headers("")), null);
  assertEquals(idempotencyKey(headers("not-a-uuid")), null);
  // The cast is what the shape check protects, so a key that is nearly a UUID is out.
  assertEquals(idempotencyKey(headers("3f2504e0-4f89-41d3-9a0c-0305e82c330")), null);
});

Deno.test("any UUID version is accepted, not only v4", () => {
  const v7 = "01924ad0-0000-7000-8000-0123456789ab";
  assertEquals(idempotencyKey(headers(v7)), v7);
});

Deno.test("the hash is 64 hex characters, as the column checks (§5.2.1)", async () => {
  const hash = await requestHash({ title: "A morning at the river" });
  assertEquals(hash.length, 64);
  assertEquals(/^[0-9a-f]{64}$/.test(hash), true);
});

Deno.test("field order does not change the hash (§7.1.1)", async () => {
  const one = await requestHash({
    title: "A morning at the river",
    metrics: { waste_kg: 12, trees_planted: 3 },
    lon: 73.8567,
  });
  const other = await requestHash({
    lon: 73.8567,
    metrics: { trees_planted: 3, waste_kg: 12 },
    title: "A morning at the river",
  });
  assertEquals(one, other);
});

Deno.test("photo order does change it, because position is the order (§8.1)", async () => {
  const before = await requestHash({ photo_ids: ["a", "b"] });
  const after = await requestHash({ photo_ids: ["b", "a"] });
  assertNotEquals(before, after);
});

Deno.test("a changed value changes the hash, which is what §7.1.1 rejects on", async () => {
  const one = await requestHash({ title: "A morning at the river", metrics: { waste_kg: 12 } });
  const other = await requestHash({ title: "A morning at the river", metrics: { waste_kg: 13 } });
  assertNotEquals(one, other);
});

// §7.1.1 answers "same key, different hash" with 422, so two spellings of one request
// must not hash apart. A route normalises its optional fields to null before hashing,
// and this is the property that makes that necessary.
Deno.test("an absent field and an explicit null are two hashes, so routes normalise", async () => {
  const omitted = await requestHash({ title: "A morning at the river" });
  const explicit = await requestHash({ title: "A morning at the river", photo_ids: null });
  assertNotEquals(omitted, explicit);

  // Once a route has normalised, the two spellings agree — which is what it sends.
  const body: Record<string, unknown> = { title: "A morning at the river" };
  const normalised = await requestHash({
    title: body.title,
    photo_ids: body.photo_ids ?? null,
  });
  assertEquals(normalised, explicit);
});

// The last spelling in the family: an empty collection is the same request as leaving
// the field out, because both Postgres functions coalesce it to nothing. A route
// normalises it before hashing, so one key never holds two hashes for one call.
Deno.test("an empty collection hashes apart until a route normalises it (§7.1.1)", async () => {
  const omitted = await requestHash({ title: "A morning at the river" });
  const empty = await requestHash({ title: "A morning at the river", photo_ids: [] });
  assertNotEquals(omitted, empty);

  const normalised = await requestHash({ title: "A morning at the river", photo_ids: null });
  assertEquals(normalised, await requestHash({ title: "A morning at the river", photo_ids: null }));
  assertNotEquals(normalised, empty);
});
