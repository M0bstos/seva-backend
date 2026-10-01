// §9.5 gives every function its own secret key, named in SUPABASE_SECRET_KEYS.
export const SECRET_KEY_NAME = "sms-hook";

// §9.5: "Proves a request came from Supabase Auth". Supabase hands the value out as
// `v1,whsec_<base64>`; the signing key is the base64 payload, so both prefixes are
// stripped before it is decoded.
export const HOOK_SECRET_VARIABLE = "SEVA_SEND_SMS_HOOK_SECRET";
export const SECRET_PREFIXES = ["v1,whsec_", "whsec_"] as const;

// Standard Webhooks, which is what Supabase Auth signs its hook calls with: three
// headers, and a signature over `<id>.<timestamp>.<body>` — the body exactly as sent,
// which is why this function reads text and parses afterwards.
export const SIGNATURE_HEADERS = {
  id: "webhook-id",
  timestamp: "webhook-timestamp",
  signature: "webhook-signature",
} as const;

export const SIGNATURE_SCHEME = "v1,";

// The spec recommends a tolerance and names no number. Five minutes each way is the
// window the reference implementations use: long enough for clock skew between the
// platform and this function, short enough that a captured call cannot be replayed
// into tomorrow's SMS budget.
export const TIMESTAMP_TOLERANCE_SECONDS = 300;

// §9.3 and `D16`: Indian numbers only. Auth stores a number without the leading `+`,
// so this matches the country code and the ten digits that follow it, and the value
// sent to AWS gets the `+` back because SendTextMessage takes E.164.
export const INDIA_PHONE_PATTERN = /^\+?(91[6-9]\d{9})$/;

// §3.1: "the SMS hook function and DLT-registered templates". Indian carriers reject
// a message whose text does not match the registered template exactly, so this string
// and the template registered under SEVA_SMS_TEMPLATE_ID_OTP have to be changed
// together. `{#var#}` is the DLT placeholder syntax; the code replaces the first one.
// The registration itself is §17's `O4`, which names the principal entity.
export const OTP_TEMPLATE = "{#var#} is your SEVA verification code. Do not share it.";
export const OTP_PLACEHOLDER = "{#var#}";

// §9.3 sends sign-in codes, which AWS prices and routes as time-critical.
export const MESSAGE_TYPE = "TRANSACTIONAL";

export const AWS_REGION_VARIABLE = "AWS_REGION";
export const ORIGINATION_IDENTITY_VARIABLE = "SEVA_SMS_ORIGINATION_IDENTITY";
export const CONFIGURATION_SET_VARIABLE = "SEVA_SMS_CONFIGURATION_SET";
export const DLT_ENTITY_ID_VARIABLE = "SEVA_SMS_DLT_ENTITY_ID";
export const DLT_TEMPLATE_ID_VARIABLE = "SEVA_SMS_TEMPLATE_ID_OTP";

// §12.5 alarms on "80% of the daily SMS cap, or send errors above 5%", from the log
// drain (`D12`). These three lines are what it reads, and they carry no identifier at
// all: §9.8 keeps the number and the code out, and neither an error rate nor a share
// of the cap needs one. The `sent` line is followed by `<count>/<cap>`, so the
// threshold is computed from what was logged rather than kept as a second copy of
// `_shared/limits.ts` in CloudWatch.
export const LOG_LINES = {
  sent: "sms-hook: sent",
  capped: "sms-hook: daily cap reached",
  failed: "sms-hook: send failed",
} as const;

// The Auth hook's own error shape, which is not §7.1's: the caller is Supabase Auth,
// not a client, and §7.1 governs what the §7.3 routes answer.
export const HOOK_ERRORS = {
  unsigned: { http_code: 401, message: "Signature missing or invalid." },
  invalid_payload: { http_code: 400, message: "The hook payload could not be read." },
  unsupported_number: {
    http_code: 400,
    message: "Only Indian numbers are supported.",
  },
  capped: { http_code: 429, message: "Daily SMS limit reached." },
  failed: { http_code: 500, message: "The code could not be sent." },
} as const;

// §12.2's bucket is `<route>:<subject>`, and this cap has no per-caller subject to
// name: §9.3 caps the project's spend, and §17.1 forbids keying it on the number.
export const ORIGINATION_SUBJECT = "all";
