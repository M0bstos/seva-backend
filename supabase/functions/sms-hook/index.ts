import { Hono } from "npm:hono@4.13.9";
import {
  PinpointSMSVoiceV2Client,
  SendTextMessageCommand,
  type SendTextMessageCommandInput,
} from "npm:@aws-sdk/client-pinpoint-sms-voice-v2@3.1141.0";
import { timingSafeEqual } from "jsr:@std/crypto@1.1.0/timing-safe-equal";
import { decodeBase64 } from "jsr:@std/encoding@1.0.11/base64";
import { secretKeyClient } from "../_shared/db.ts";
import { limitArgs } from "../_shared/limits.ts";
import {
  AWS_REGION_VARIABLE,
  CONFIGURATION_SET_VARIABLE,
  DLT_ENTITY_ID_VARIABLE,
  DLT_TEMPLATE_ID_VARIABLE,
  HOOK_ERRORS,
  HOOK_SECRET_VARIABLE,
  INDIA_PHONE_PATTERN,
  LOG_LINES,
  MESSAGE_TYPE,
  ORIGINATION_IDENTITY_VARIABLE,
  ORIGINATION_SUBJECT,
  OTP_PLACEHOLDER,
  OTP_TEMPLATE,
  SECRET_KEY_NAME,
  SECRET_PREFIXES,
  SIGNATURE_HEADERS,
  SIGNATURE_SCHEME,
  TIMESTAMP_TOLERANCE_SECONDS,
} from "./sms-hook.constants.ts";

// §9.3's Send SMS hook, and `D16`'s sign-in path: Supabase Auth calls this instead of
// an SMS provider, and §4.1 gives it three checks — "Supabase signature check, +91
// numbers only, daily SMS cap" — in that order. It is the only §7.3 function that is
// not a route group, so it answers Auth's own error shape rather than §7.1's.
//
// `verify_jwt` is false (§7.3): Auth signs the call, and no token exists yet — the
// person is asking for the code that would get them one.
//
// Nothing here logs the number, the code or the payload (§9.8). The three lines it
// does emit carry no identifier at all, because what reads them is §12.5's counting
// alarm: 80% of the daily cap, and send errors above 5%.
const db = secretKeyClient(SECRET_KEY_NAME);
const aws = awsSettings();
const sms = new PinpointSMSVoiceV2Client({ region: aws.region });

export const app = new Hono().basePath("/sms-hook");

app.post("/", async (c) => {
  // The signature covers the body exactly as sent, so it is read as text and parsed
  // afterwards. Parsing first and re-serialising would change the bytes.
  const raw = await c.req.text();
  if (!await signedBySupabase(c.req.raw.headers, raw)) return hookError("unsigned");

  const payload = readPayload(raw);
  if (!payload) return hookError("invalid_payload");

  // §9.3 and `D16`: Indian numbers only, checked before anything is spent. An AWS
  // protect configuration blocks every other destination country as well, so this is
  // the cheap half of a control that does not depend on one check holding.
  const destination = indianNumber(payload.phone);
  if (!destination) return hookError("unsupported_number");

  // §9.3: "stops sending at a daily SMS cap", counted in Postgres (§12.5). The
  // subject is the project, not the caller: a per-number bucket is what §17.1
  // forbids, and a per-account one would not cap the bill.
  const permission = limitArgs("sms.send", ORIGINATION_SUBJECT, null);
  const { data, error } = await db.rpc("count_sms_send", permission);
  if (error) return hookError("failed");
  const answer = data as { error?: string; sent_today?: number };
  if (answer.error) {
    console.log(LOG_LINES.capped);
    return hookError("capped");
  }

  try {
    await sms.send(new SendTextMessageCommand(otpMessage(destination, payload.otp)));
  } catch {
    // The exception is not logged: AWS echoes the destination number back in a
    // validation error, which §9.8 keeps out of logs.
    console.log(LOG_LINES.failed);
    return hookError("failed");
  }

  // §12.5 alarms at "80% of the daily SMS cap", and the counter is unreachable from
  // anywhere but the call above (§9.4). So the count travels back with the permission
  // and is logged beside the cap it was measured against, which is what keeps the
  // threshold out of CloudWatch as a second copy of a number `_shared/limits.ts` owns.
  console.log(`${LOG_LINES.sent} ${answer.sent_today}/${permission.p_per_day}`);
  // Supabase Auth reads a 200 as sent and wants nothing in the body.
  return c.json({});
});

// The message as AWS receives it. Separated from the send so the DLT pair, the
// template and the E.164 destination can be asserted without an AWS account, which is
// the whole of what §8's "one API call" is here.
export function otpMessage(destination: string, otp: string): SendTextMessageCommandInput {
  return {
    DestinationPhoneNumber: destination,
    OriginationIdentity: aws.originationIdentity,
    ConfigurationSetName: aws.configurationSet,
    MessageType: MESSAGE_TYPE,
    MessageBody: OTP_TEMPLATE.replace(OTP_PLACEHOLDER, otp),
    // Indian carriers reject a message whose sender and text are not the registered
    // pair (§3.1). Both ids come from the DLT registration, `O4`.
    DestinationCountryParameters: {
      IN_ENTITY_ID: aws.dltEntityId,
      IN_TEMPLATE_ID: aws.dltTemplateId,
    },
  };
}

// Standard Webhooks, which is how Supabase Auth signs a hook call: a base64 HMAC of
// `<id>.<timestamp>.<body>` under the hook secret, in a header that may carry more
// than one signature so a secret can be rotated without dropping calls.
export async function signedBySupabase(headers: Headers, body: string): Promise<boolean> {
  const id = headers.get(SIGNATURE_HEADERS.id);
  const timestamp = headers.get(SIGNATURE_HEADERS.timestamp);
  const sent = headers.get(SIGNATURE_HEADERS.signature);
  if (!id || !timestamp || !sent) return false;
  if (!withinTolerance(timestamp)) return false;

  const expected = await sign(`${id}.${timestamp}.${body}`);
  return sent.split(" ").some((candidate) =>
    candidate.startsWith(SIGNATURE_SCHEME) &&
    matches(candidate.slice(SIGNATURE_SCHEME.length), expected)
  );
}

async function sign(content: string): Promise<Uint8Array> {
  const secret = Deno.env.get(HOOK_SECRET_VARIABLE);
  if (!secret) throw new Error(`${HOOK_SECRET_VARIABLE} is not set`);

  const prefix = SECRET_PREFIXES.find((p) => secret.startsWith(p));
  const key = await crypto.subtle.importKey(
    "raw",
    decodeBase64(prefix ? secret.slice(prefix.length) : secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  return new Uint8Array(
    await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(content)),
  );
}

// Compared as bytes and in constant time. A length check first because the comparison
// needs equal lengths, and because a signature that is not base64 at all decodes to
// something shorter rather than throwing.
function matches(candidate: string, expected: Uint8Array): boolean {
  let decoded: Uint8Array;
  try {
    decoded = decodeBase64(candidate);
  } catch {
    return false;
  }
  return decoded.length === expected.length && timingSafeEqual(decoded, expected);
}

// A replayed call would otherwise spend tomorrow's SMS budget on a code captured
// today, and the code itself is still valid for an hour (§9.3).
function withinTolerance(timestamp: string): boolean {
  const sent = Number(timestamp);
  if (!Number.isFinite(sent)) return false;
  return Math.abs(Date.now() / 1000 - sent) <= TIMESTAMP_TOLERANCE_SECONDS;
}

// The two fields §9.3 needs out of the hook payload. Anything else Auth sends —
// the rest of the user record — is not read, so it cannot be logged or forwarded.
export function readPayload(raw: string): { phone: string; otp: string } | null {
  try {
    const body = JSON.parse(raw) as { user?: { phone?: unknown }; sms?: { otp?: unknown } };
    const phone = body.user?.phone;
    const otp = body.sms?.otp;
    return typeof phone === "string" && typeof otp === "string" ? { phone, otp } : null;
  } catch {
    return null;
  }
}

// Auth stores a number without its `+`; SendTextMessage takes E.164, so it goes back
// on. The mobile range is 6–9, which is what an Indian mobile number starts with —
// a landline or a short code is not somewhere a sign-in code can arrive.
export function indianNumber(phone: string): string | null {
  const match = phone.trim().match(INDIA_PHONE_PATTERN);
  return match ? `+${match[1]}` : null;
}

// Read once at boot, so a function missing one of them fails loudly on deploy rather
// than after a caller has already spent a slice of the daily cap.
function awsSettings() {
  const read = (name: string) => {
    const value = Deno.env.get(name);
    if (!value) throw new Error(`${name} is not set`);
    return value;
  };
  return {
    region: read(AWS_REGION_VARIABLE),
    originationIdentity: read(ORIGINATION_IDENTITY_VARIABLE),
    configurationSet: read(CONFIGURATION_SET_VARIABLE),
    dltEntityId: read(DLT_ENTITY_ID_VARIABLE),
    dltTemplateId: read(DLT_TEMPLATE_ID_VARIABLE),
  };
}

function hookError(code: keyof typeof HOOK_ERRORS): Response {
  const known = HOOK_ERRORS[code];
  return Response.json({ error: known }, { status: known.http_code });
}

app.notFound(() => hookError("invalid_payload"));
app.onError(() => hookError("failed"));

if (import.meta.main) Deno.serve(app.fetch);
