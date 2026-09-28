import { assertEquals, assertThrows } from "jsr:@std/assert@1.0.19";
import { secretKeyClient } from "./db.ts";

function withEnv(env: Record<string, string | undefined>, run: () => void) {
  const before = {
    SUPABASE_URL: Deno.env.get("SUPABASE_URL"),
    SUPABASE_SECRET_KEYS: Deno.env.get("SUPABASE_SECRET_KEYS"),
  };
  for (const [k, v] of Object.entries(env)) {
    if (v === undefined) Deno.env.delete(k);
    else Deno.env.set(k, v);
  }
  try {
    run();
  } finally {
    for (const [k, v] of Object.entries(before)) {
      if (v === undefined) Deno.env.delete(k);
      else Deno.env.set(k, v);
    }
  }
}

const KEYS = JSON.stringify({ acts: "sb_secret_acts", feed: "sb_secret_feed" });

Deno.test("a function gets the one key it is named for (§9.5)", () => {
  withEnv({ SUPABASE_URL: "http://db.test", SUPABASE_SECRET_KEYS: KEYS }, () => {
    assertEquals(typeof secretKeyClient("acts").rpc, "function");
    assertEquals(typeof secretKeyClient("feed").rpc, "function");
  });
});

Deno.test("a key the dictionary does not hold fails at boot, not mid-request", () => {
  withEnv({ SUPABASE_URL: "http://db.test", SUPABASE_SECRET_KEYS: KEYS }, () => {
    assertThrows(
      () => secretKeyClient("uploads"),
      Error,
      "SUPABASE_SECRET_KEYS has no entry named uploads",
    );
  });
});

Deno.test("a missing injection is named, and the error never carries a key", () => {
  withEnv({ SUPABASE_URL: undefined, SUPABASE_SECRET_KEYS: KEYS }, () => {
    assertThrows(() => secretKeyClient("acts"), Error, "SUPABASE_URL is not set");
  });
  withEnv({ SUPABASE_URL: "http://db.test", SUPABASE_SECRET_KEYS: undefined }, () => {
    assertThrows(() => secretKeyClient("acts"), Error, "SUPABASE_SECRET_KEYS is not set");
  });
  withEnv({ SUPABASE_URL: "http://db.test", SUPABASE_SECRET_KEYS: KEYS }, () => {
    const thrown = assertThrows(() => secretKeyClient("nope")) as Error;
    assertEquals(thrown.message.includes("sb_secret_acts"), false);
  });
});

const LOCAL_ONLY = JSON.stringify({ default: "sb_secret_local" });

Deno.test("a local stack falls back to its one key, so the API tests can run", () => {
  // Measured: the local runtime injects {"default": …} and refuses a .env override
  // of a SUPABASE_ name, so without this no route runs outside a hosted project.
  for (const url of ["http://kong:8000", "http://127.0.0.1:54321", "http://localhost:54321"]) {
    withEnv({ SUPABASE_URL: url, SUPABASE_SECRET_KEYS: LOCAL_ONLY }, () => {
      assertEquals(typeof secretKeyClient("discover").rpc, "function");
    });
  }
});

Deno.test("a hosted project never falls back, so §9.5 keeps its one property", () => {
  // Revoking a leaked key has to stop that function. If the fallback were reachable
  // there, the function would keep serving on `default` and a rotation that removed
  // the old entry first would fail open instead of at boot.
  withEnv({
    SUPABASE_URL: "https://abcdefgh.supabase.co",
    SUPABASE_SECRET_KEYS: LOCAL_ONLY,
  }, () => {
    assertThrows(
      () => secretKeyClient("discover"),
      Error,
      "SUPABASE_SECRET_KEYS has no entry named discover",
    );
  });

  // And a key missing from a dictionary that has no `default` at all still fails.
  withEnv({ SUPABASE_URL: "https://abcdefgh.supabase.co", SUPABASE_SECRET_KEYS: KEYS }, () => {
    assertThrows(
      () => secretKeyClient("discover"),
      Error,
      "SUPABASE_SECRET_KEYS has no entry named discover",
    );
  });
});
