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
