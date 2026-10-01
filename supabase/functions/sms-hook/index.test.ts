// Everything the client and the AWS settings are read from is set before the module
// is imported, because both are read at boot (§9.5) — a missing name is meant to fail
// the deploy, not the first caller.
Deno.env.set("SUPABASE_URL", "http://db.test");
Deno.env.set("SUPABASE_SECRET_KEYS", JSON.stringify({ "sms-hook": "sb_secret_test" }));
Deno.env.set("AWS_REGION", "ap-south-1");
Deno.env.set("SEVA_SMS_ORIGINATION_IDENTITY", "SEVAIN");
Deno.env.set("SEVA_SMS_CONFIGURATION_SET", "seva-sms");
Deno.env.set("SEVA_SMS_DLT_ENTITY_ID", "1234567890123456789");
Deno.env.set("SEVA_SMS_TEMPLATE_ID_OTP", "9876543210987654321");
Deno.env.set("SEVA_SEND_SMS_HOOK_SECRET", "v1,whsec_c2V2YS1sb2NhbC1ob29rLXNlY3JldA==");

const { app, indianNumber, otpMessage, readPayload, signedBySupabase } = await import(
  "./index.ts"
);
const { assertEquals, assertNotMatch } = await import("jsr:@std/assert@1.0.19");
const { encodeBase64 } = await import("jsr:@std/encoding@1.0.11/base64");

const OTP = "483920";
const PHONE = "919812345678";

function payload(overrides: Record<string, unknown> = {}) {
  return JSON.stringify({ user: { id: "u", phone: PHONE }, sms: { otp: OTP }, ...overrides });
}

// The same construction Supabase Auth uses: base64 HMAC-SHA256 over
// `<id>.<timestamp>.<body>` under the hook secret, prefixed `v1,`.
async function sign(body: string, timestamp: number, id = "msg_1") {
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode("seva-local-hook-secret"),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const mac = await crypto.subtle.sign(
    "HMAC",
    key,
    new TextEncoder().encode(`${id}.${timestamp}.${body}`),
  );
  return {
    "webhook-id": id,
    "webhook-timestamp": String(timestamp),
    "webhook-signature": `v1,${encodeBase64(new Uint8Array(mac))}`,
  };
}

function now() {
  return Math.floor(Date.now() / 1000);
}

Deno.test("a call with no signature headers is refused (§9.3)", async () => {
  const response = await app.request("/sms-hook", { method: "POST", body: payload() });
  assertEquals(response.status, 401);
  assertEquals((await response.json()).error.http_code, 401);
});

Deno.test("a signature made with another secret is refused", async () => {
  const body = payload();
  const headers = await sign(body, now());
  headers["webhook-signature"] = `v1,${encodeBase64(new Uint8Array(32))}`;
  const response = await app.request("/sms-hook", { method: "POST", headers, body });
  assertEquals(response.status, 401);
});

Deno.test("a signature over a different body is refused", async () => {
  const headers = await sign(payload(), now());
  const response = await app.request("/sms-hook", {
    method: "POST",
    headers,
    body: payload({ sms: { otp: "000000" } }),
  });
  assertEquals(response.status, 401);
});

Deno.test("a correctly signed call replayed an hour later is refused", async () => {
  const body = payload();
  const stale = now() - 3600;
  const response = await app.request("/sms-hook", {
    method: "POST",
    headers: await sign(body, stale),
    body,
  });
  assertEquals(response.status, 401);
});

Deno.test("the signature is verified over the exact bytes, and a second one is allowed", async () => {
  const body = payload();
  const headers = await sign(body, now());
  assertEquals(await signedBySupabase(new Headers(headers), body), true);

  // Standard Webhooks allows several signatures in one header so a secret can be
  // rotated without dropping calls; only one has to match.
  const rotated = new Headers(headers);
  rotated.set(
    "webhook-signature",
    `v1,${encodeBase64(new Uint8Array(32))} ${headers["webhook-signature"]}`,
  );
  assertEquals(await signedBySupabase(rotated, body), true);
});

Deno.test("a signature that is not base64 is refused rather than raising", async () => {
  const body = payload();
  const headers = new Headers(await sign(body, now()));
  headers.set("webhook-signature", "v1,not base64 at all");
  assertEquals(await signedBySupabase(headers, body), false);
});

Deno.test("a signed call for a number outside +91 is refused (§9.3, `D16`)", async () => {
  const body = payload({ user: { id: "u", phone: "14155550123" } });
  const response = await app.request("/sms-hook", {
    method: "POST",
    headers: await sign(body, now()),
    body,
  });
  assertEquals(response.status, 400);
  assertEquals((await response.json()).error.message, "Only Indian numbers are supported.");
});

Deno.test("only Indian mobile numbers are accepted, in E.164", () => {
  assertEquals(indianNumber("919812345678"), "+919812345678");
  assertEquals(indianNumber("+919812345678"), "+919812345678");
  // 6 to 9 is the Indian mobile range; a landline or a short code is not somewhere a
  // sign-in code can arrive.
  assertEquals(indianNumber("915512345678"), null);
  assertEquals(indianNumber("9198123456789"), null);
  assertEquals(indianNumber("91981234567"), null);
  assertEquals(indianNumber("14155550123"), null);
  assertEquals(indianNumber(""), null);
});

Deno.test("a payload missing either field it reads is refused, not sent", () => {
  assertEquals(readPayload(payload()), { phone: PHONE, otp: OTP });
  assertEquals(readPayload(JSON.stringify({ user: { phone: PHONE } })), null);
  assertEquals(readPayload(JSON.stringify({ sms: { otp: OTP } })), null);
  assertEquals(readPayload(JSON.stringify({ user: { phone: 91 }, sms: { otp: OTP } })), null);
  assertEquals(readPayload("not json"), null);
});

Deno.test("the message sent to AWS carries the DLT pair and the registered text (§3.1)", () => {
  const message = otpMessage("+919812345678", OTP);
  assertEquals(message.DestinationPhoneNumber, "+919812345678");
  assertEquals(message.OriginationIdentity, "SEVAIN");
  assertEquals(message.ConfigurationSetName, "seva-sms");
  assertEquals(message.MessageType, "TRANSACTIONAL");
  assertEquals(message.MessageBody, "483920 is your SEVA verification code. Do not share it.");
  assertEquals(message.DestinationCountryParameters, {
    IN_ENTITY_ID: "1234567890123456789",
    IN_TEMPLATE_ID: "9876543210987654321",
  });
});

Deno.test("no refusal the hook can answer repeats the number or the code (§9.8)", async () => {
  const bad = payload({ user: { id: "u", phone: "14155550123" } });
  const answers = [
    await app.request("/sms-hook", { method: "POST", body: payload() }),
    await app.request("/sms-hook", { method: "POST", headers: await sign(bad, now()), body: bad }),
    await app.request("/sms-hook/anything", { method: "POST" }),
  ];
  for (const answer of answers) {
    const text = await answer.text();
    assertNotMatch(text, /\d{6}/);
    assertNotMatch(text, /14155550123|919812345678/);
  }
});
