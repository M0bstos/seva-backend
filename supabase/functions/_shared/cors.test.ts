import { assertEquals } from "jsr:@std/assert@1.0.19";
import { Hono } from "npm:hono@4.13.9";
import { browserOrigins } from "./cors.ts";
import { ALLOWED_ORIGINS_VARIABLE } from "./cors.constants.ts";

// §17 `O37`. The four route groups a browser reaches mount this the same way, so one
// app standing in for them is the honest unit: what the middleware does is the thing
// under test, and `index.test.ts` for each route covers the mounting.
function app() {
  return new Hono()
    .basePath("/probe")
    .use("*", browserOrigins())
    .get("/", (c) => c.json({ ok: true }));
}

function origins(value: string) {
  if (value) Deno.env.set(ALLOWED_ORIGINS_VARIABLE, value);
  else Deno.env.delete(ALLOWED_ORIGINS_VARIABLE);
}

// Measured against the hosted staging project: a preflight reaches the function even
// with `verify_jwt = true` and no `Authorization`, and every function answered it with
// its own §7.1 `NOT_FOUND` — which is what `O37` found broken.
Deno.test("a preflight from an allowed origin is answered, not 404", async () => {
  origins("https://seva.gov.in");
  const response = await app().request("/probe", {
    method: "OPTIONS",
    headers: {
      Origin: "https://seva.gov.in",
      "Access-Control-Request-Method": "GET",
      "Access-Control-Request-Headers": "apikey,authorization",
    },
  });
  assertEquals(response.status, 204);
  assertEquals(response.headers.get("Access-Control-Allow-Origin"), "https://seva.gov.in");
});

// §7.1 puts `apikey` on every request and `Idempotency-Key` on every create, so a
// preflight that cannot carry them makes the route unusable from a browser.
Deno.test("§7.1's headers are all allowed, including the ones a create needs", async () => {
  origins("https://seva.gov.in");
  const response = await app().request("/probe", {
    method: "OPTIONS",
    headers: { Origin: "https://seva.gov.in", "Access-Control-Request-Method": "POST" },
  });
  const allowed = (response.headers.get("Access-Control-Allow-Headers") ?? "").toLowerCase();
  for (const header of ["apikey", "authorization", "content-type", "x-region", "idempotency-key"]) {
    assertEquals(allowed.includes(header), true, header);
  }
  const methods = response.headers.get("Access-Control-Allow-Methods") ?? "";
  assertEquals(methods.includes("PATCH"), true, "PATCH /acts/:id is a browser call too");
});

Deno.test("a real request from an allowed origin carries the header back", async () => {
  origins("https://seva.gov.in");
  const response = await app().request("/probe", {
    headers: { Origin: "https://seva.gov.in" },
  });
  assertEquals(response.status, 200);
  assertEquals(response.headers.get("Access-Control-Allow-Origin"), "https://seva.gov.in");
});

// The list is a list, not a wildcard: an origin outside it gets no header, so the
// browser blocks the response rather than the function having to refuse it.
Deno.test("an origin outside the list is not allowed", async () => {
  origins("https://seva.gov.in");
  const response = await app().request("/probe", {
    headers: { Origin: "https://not-seva.example" },
  });
  assertEquals(response.headers.get("Access-Control-Allow-Origin"), null);
});

Deno.test("several origins can be listed, which a staging build needs", async () => {
  origins("https://seva.gov.in, https://staging.seva.gov.in");
  for (const origin of ["https://seva.gov.in", "https://staging.seva.gov.in"]) {
    const response = await app().request("/probe", { headers: { Origin: origin } });
    assertEquals(response.headers.get("Access-Control-Allow-Origin"), origin, origin);
  }
});

// Unset is the state every deployment is in until §14.1's step is done, and it has to
// be the state the native client already works in.
Deno.test("no list set allows no origin, and serves a non-browser caller unchanged", async () => {
  origins("");
  const browser = await app().request("/probe", {
    headers: { Origin: "https://seva.gov.in" },
  });
  assertEquals(browser.headers.get("Access-Control-Allow-Origin"), null);

  const native = await app().request("/probe");
  assertEquals(native.status, 200);
  assertEquals(await native.json(), { ok: true });
});
