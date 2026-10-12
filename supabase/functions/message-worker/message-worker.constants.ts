// §9.5 gives every function and worker its own secret key. §7.3: the three workers "set
// `verify_jwt` false and check their secret key in code, since that key is not a JWT", and
// §17.1 settles that the key they check is this one.
export const SECRET_KEY_NAME = "message-worker";

// §8.4 caps the moderation worker's batch at ten for Rekognition's 5/second. SES's default send
// rate is higher, but the two workers share the ops host's cron and the same 2-second CPU
// budget, so the batch is kept the same size rather than tuned against a quota §8.4 does not
// state. A batch that runs long is retried rather than lost (§8.4's 60-second window).
export const BATCH_SIZE = 10;

// §4.2 pins AWS to Mumbai, and the worker reads the region at boot like the moderation worker
// does, so a missing one fails the deploy rather than the first job.
export const AWS_REGION_VARIABLE = "AWS_REGION";

// §9.3: email goes out "from a SEVA domain with SPF, DKIM and DMARC", and §9.5's AWS key allows
// `ses:SendEmail` from that domain. The address itself is configuration, not a secret, but it
// lives beside the keys because §14.2 has to tick it.
export const EMAIL_FROM_VARIABLE = "SEVA_EMAIL_FROM";

// The SMS half reuses the sign-in hook's registered identity and configuration set, because
// §3.1 gives SEVA one End User Messaging setup and D16 one DLT-registered local route. What it
// cannot reuse is the template: §14.2 asks for "templates for sign-in codes **and
// cancellations**", and an Indian carrier rejects a message whose text and registered template
// id are not the pair.
export const ORIGINATION_IDENTITY_VARIABLE = "SEVA_SMS_ORIGINATION_IDENTITY";
export const CONFIGURATION_SET_VARIABLE = "SEVA_SMS_CONFIGURATION_SET";
export const DLT_ENTITY_ID_VARIABLE = "SEVA_SMS_DLT_ENTITY_ID";
export const DLT_TEMPLATE_ID_VARIABLE = "SEVA_SMS_TEMPLATE_ID_CANCELLATION";

export const MESSAGE_TYPE = "TRANSACTIONAL";

// **English only in v1, and this is the decision rather than an oversight.** `profile_private`
// carries a `locale`, and `O24` decided that §7.4's error copy is localised by the client from
// the code — which cannot apply to a message with no client in front of it. What settles it is
// the SMS half: D16 puts cancellations on a DLT-registered route, and an Indian carrier matches
// the text against the registered template, so one template is one language by construction.
// Adding more means a registered template and an SES template per language, which is §3.1's
// "Email templates" work and a DLT registration step (`O4`), not a code change. The claim
// therefore does not read `locale` at all, because nothing here could use it.
export const EMAIL_SUBJECT = "An activity you joined has been cancelled";

// §9.8 bounds what a template may contain as much as what a log line may: the Activity's own
// title, time and meeting point, and no other person's name. The organiser is not named —
// §9.6's reason, that a minor is "never listed as participants anywhere", applies to naming
// people in mail that leaves the system at all.
export const EMAIL_BODY =
  "{title} on {starts_at} at {location_label} has been cancelled by its organiser.\n\n" +
  "You do not need to do anything. Other activities near you are in the SEVA app.";

// The registered DLT text, which must match the template id above character for character.
export const SMS_BODY = "{#var#} has been cancelled. Check the SEVA app for other activities.";
export const SMS_PLACEHOLDER = "{#var#}";

// §12.5 reads these to count. Counts and a kind, never an address (§9.8).
export const LOG_LINES = {
  run: "message-worker run",
  failed: "message-worker job failed",
} as const;
