Deno.env.set("SUPABASE_URL", "http://db.test");
Deno.env.set("SUPABASE_SECRET_KEYS", JSON.stringify({ feed: "sb_secret_test" }));

const { app, readQuery } = await import("./index.ts");
const { assertEquals } = await import("jsr:@std/assert@1.0.19");

const NEARBY = "lon=73.8567&lat=18.5204";

Deno.test("Feed is signed in, so no session is UNAUTHENTICATED (§7.3)", async () => {
  const response = await app.request(`/feed?${NEARBY}`);
  assertEquals(response.status, 401);
  assertEquals((await response.json()).error.code, "UNAUTHENTICATED");
});

Deno.test("the token is checked before the query, per §13.4's order", async () => {
  // A request with no coordinates at all is still 401, not 400.
  const response = await app.request("/feed");
  assertEquals(response.status, 401);
});

Deno.test("the radius is an integer here, and a rung inside feed_acts (§17.1)", () => {
  const point = { lon: "73.8567", lat: "18.5204" };
  // `p_radius_km` is an `int`: a fractional value raises on the cast, and measured,
  // that raise happens before the limiter counts the request.
  assertEquals(readQuery({ ...point, radius_km: "3.5" }), "radius_km");
  assertEquals(readQuery({ ...point, radius_km: "abc" }), "radius_km");
  // Zero and negatives are values the column takes, and `feed_acts` snaps both to
  // its smallest rung — so refusing them here would be the same rule in two places.
  const zero = readQuery({ ...point, radius_km: "0" });
  assertEquals(typeof zero === "string" ? zero : zero.radiusKm, 0);
  // Which rung a well-formed number lands on is `feed_acts`' rule, so 2 km snaps to
  // `O30`'s smallest cell and 100 km to the widest rather than being refused here.
  const near = readQuery({ ...point, radius_km: "2" });
  assertEquals(typeof near === "string" ? near : near.radiusKm, 2);
  const far = readQuery({ ...point, radius_km: "100" });
  assertEquals(typeof far === "string" ? far : far.radiusKm, 100);
});

Deno.test("a coordinate is refused here, because PostGIS coerces it (§17.1)", () => {
  assertEquals(readQuery({ lat: "18.5204" }), "lon");
  assertEquals(readQuery({ lon: "73.8567" }), "lat");
  assertEquals(readQuery({ lon: "73.8567", lat: "95" }), "lat");
});

Deno.test("§7.1 caps a page at 50, and §5.3 fixes the categories", () => {
  const point = { lon: "73.8567", lat: "18.5204" };
  // §7.1 states the ceiling, so the route names the field for it.
  assertEquals(readQuery({ ...point, limit: "51" }), "limit");
  assertEquals(readQuery({ ...point, limit: "2.5" }), "limit");
  // It states no floor, and `feed_acts` clamps, so a page of zero is a page of one.
  const none = readQuery({ ...point, limit: "0" });
  assertEquals(typeof none === "string" ? none : none.limit, 0);
  assertEquals(readQuery({ ...point, category: "gardening" }), "category");
});

Deno.test("what is absent stays absent, for the function to default (§17.1)", () => {
  const asked = readQuery({ lon: "73.8567", lat: "18.5204" });
  assertEquals(typeof asked === "string" ? asked : asked.radiusKm, null);
  assertEquals(typeof asked === "string" ? asked : asked.limit, null);
  assertEquals(typeof asked === "string" ? asked : asked.cursor, null);
});

Deno.test("a path §7.3 does not give this function is a 404", async () => {
  assertEquals((await app.request("/feed/acts")).status, 404);
  assertEquals((await app.request(`/feed?${NEARBY}`, { method: "POST" })).status, 404);
});

Deno.test("a NUL in the cursor is refused here too (§9.8, §12.2)", () => {
  const point = { lon: "73.8567", lat: "18.5204" };
  assertEquals(readQuery({ ...point, cursor: "a\u0000b" }), "cursor");
  // An ordinary bad cursor still belongs to `private.decode_cursor`, which answers
  // VALIDATION_FAILED for it — the route does not second-guess the format.
  const passed = readQuery({ ...point, cursor: "notacursor" });
  assertEquals(typeof passed === "string" ? passed : passed.cursor, "notacursor");
});
