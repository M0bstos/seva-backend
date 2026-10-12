// §4.2 pins AWS to Mumbai and the worker reads its settings at boot, so they are set before the
// module is imported — the same shape the moderation worker's test uses. No test here reaches AWS
// or the database: §16's Rekognition-and-Guardrails-from-Mumbai spike is still open and there is
// no AWS account, so what is testable is everything up to the send.
Deno.env.set("SUPABASE_URL", "http://db.test");
Deno.env.set("SUPABASE_SECRET_KEYS", JSON.stringify({ "message-worker": "sb_secret_test" }));
Deno.env.set("AWS_REGION", "ap-south-1");
Deno.env.set("SEVA_EMAIL_FROM", "no-reply@seva.test");
Deno.env.set("SEVA_SMS_ORIGINATION_IDENTITY", "SEVAID");
Deno.env.set("SEVA_SMS_CONFIGURATION_SET", "seva-sms");
Deno.env.set("SEVA_SMS_DLT_ENTITY_ID", "entity-1");
Deno.env.set("SEVA_SMS_TEMPLATE_ID_CANCELLATION", "template-cancel");

const { app, authorised, cancellationMessage, filled } = await import("./index.ts");
const { assertEquals, assertStringIncludes } = await import("jsr:@std/assert@1.0.19");
const { EMAIL_BODY } = await import("./message-worker.constants.ts");

const JOB = {
  msg_id: 1,
  kind: "activity_cancelled" as const,
  user_id: "11111111-1111-1111-1111-111111111111",
  activity_id: "22222222-2222-2222-2222-222222222222",
  title: "Lake shore cleanup",
  starts_at: "2026-10-21T07:00:00+05:30",
  location_label: "East gate, Pashan Lake",
};

// §7.3: the workers "check their secret key in code, since that key is not a JWT".
Deno.test("only the worker's own secret key is authorised (§7.3, §9.5)", () => {
  assertEquals(authorised("Bearer sb_secret_test"), true);
  assertEquals(authorised("Bearer sb_secret_other"), false);
  assertEquals(authorised("Bearer "), false);
  assertEquals(authorised("sb_secret_test"), false);
  assertEquals(authorised(undefined), false);
  // A prefix must not pass: the comparison is length-checked before the constant-time compare.
  assertEquals(authorised("Bearer sb_secret_tes"), false);
});

Deno.test("a call with no key is UNAUTHENTICATED, not a 500 (§7.1, §7.4)", async () => {
  const response = await app.request("/message-worker", { method: "POST" });
  assertEquals(response.status, 401);
  assertEquals((await response.json()).error.code, "UNAUTHENTICATED");
});

Deno.test("an unknown path under the worker is §7.1's shape (§7.1)", async () => {
  const response = await app.request("/message-worker/x", { method: "POST" });
  assertEquals(response.status, 404);
  assertEquals((await response.json()).error.code, "NOT_FOUND");
});

// §17 O37: the workers mount no CORS, because their caller is the ops host's cron.
Deno.test("the worker answers no preflight, because cron is its caller (§17 O37)", async () => {
  Deno.env.set("SEVA_ALLOWED_ORIGINS", "https://seva.example");
  const response = await app.request("/message-worker", {
    method: "OPTIONS",
    headers: { Origin: "https://seva.example", "Access-Control-Request-Method": "POST" },
  });
  assertEquals(response.headers.get("access-control-allow-origin"), null);
  Deno.env.delete("SEVA_ALLOWED_ORIGINS");
});

// §9.8 bounds what a message carries as tightly as what a log line does.
Deno.test("the email body carries the Activity and nobody's name (§9.8, §9.6)", () => {
  const body = filled(EMAIL_BODY, JOB);
  assertStringIncludes(body, "Lake shore cleanup");
  assertStringIncludes(body, "East gate, Pashan Lake");
  assertStringIncludes(body, "2026-10-21T07:00:00+05:30");
  // No placeholder is left unfilled, which would send a template to a person.
  assertEquals(body.includes("{"), false);
  // The organiser is not named: §9.6's reason for keeping a minor off participant lists applies
  // to naming anybody in mail that leaves the system.
  assertEquals(body.includes(JOB.user_id), false);
});

// D16 puts cancellations on a DLT-registered local route, and an Indian carrier matches the text
// against the registered template id.
Deno.test("the SMS names the registered sender, set and DLT pair (§3.1, D16, O4)", () => {
  const message = cancellationMessage("919000000001", JOB.title);
  assertEquals(message.OriginationIdentity, "SEVAID");
  assertEquals(message.ConfigurationSetName, "seva-sms");
  assertEquals(message.MessageType, "TRANSACTIONAL");
  assertEquals(message.DestinationCountryParameters?.IN_ENTITY_ID, "entity-1");
  assertEquals(message.DestinationCountryParameters?.IN_TEMPLATE_ID, "template-cancel");
  assertStringIncludes(message.MessageBody ?? "", "Lake shore cleanup");
  assertEquals((message.MessageBody ?? "").includes("{#var#}"), false);
});

// §5.4 and §9.3 keep a phone number in E.164; Auth stores it without the `+`.
Deno.test("the destination is sent in E.164 whichever way Auth stored it (§9.3)", () => {
  assertEquals(
    cancellationMessage("919000000001", JOB.title).DestinationPhoneNumber,
    "+919000000001",
  );
  assertEquals(
    cancellationMessage("+919000000001", JOB.title).DestinationPhoneNumber,
    "+919000000001",
  );
});
