import { Hono } from "npm:hono@4.13.9";
import { SendEmailCommand, SESv2Client } from "npm:@aws-sdk/client-sesv2@3.1141.0";
import {
  PinpointSMSVoiceV2Client,
  SendTextMessageCommand,
  type SendTextMessageCommandInput,
} from "npm:@aws-sdk/client-pinpoint-sms-voice-v2@3.1141.0";
import { timingSafeEqual } from "jsr:@std/crypto@1.1.0/timing-safe-equal";
import { secretKey, secretKeyClient } from "../_shared/db.ts";
import { fail } from "../_shared/errors.ts";
import {
  AWS_REGION_VARIABLE,
  BATCH_SIZE,
  CONFIGURATION_SET_VARIABLE,
  DLT_ENTITY_ID_VARIABLE,
  DLT_TEMPLATE_ID_VARIABLE,
  EMAIL_BODY,
  EMAIL_FROM_VARIABLE,
  EMAIL_SUBJECT,
  LOG_LINES,
  MESSAGE_TYPE,
  ORIGINATION_IDENTITY_VARIABLE,
  SECRET_KEY_NAME,
  SMS_BODY,
  SMS_PLACEHOLDER,
} from "./message-worker.constants.ts";

// §1.1's second worker, and §2.1's own sentence: an organiser "can cancel, which notifies every
// participant by email, or by SMS if they have no email". §5.4 adds the other producer — an
// account deletion cancels the person's future Activities and emails their participants.
//
// Cron calls it (§4.1), it claims a batch, and for each job it asks AWS to send one message.
// `verify_jwt` is false and the secret key is checked here, because §7.3 says that key is not a
// JWT.
//
// **The address comes from the Auth admin API, not from SQL.** §5.4 keeps the phone number and
// the email in Supabase Auth and permits one copy elsewhere — `private.retained_registrations`,
// which §11.6 compels. So this worker reads them over the admin API, which keeps them out of
// any Postgres function and leaves the definer-body lint's single exception at one.
//
// Nothing is logged but counts. §9.8 puts an email address and a phone number on the never-log
// list, and an AWS exception echoes the destination back — which is why the catch below logs a
// kind and never the error.
const db = secretKeyClient(SECRET_KEY_NAME);
const aws = awsSettings();
const ses = new SESv2Client({ region: aws.region });
const sms = new PinpointSMSVoiceV2Client({ region: aws.region });

type Job = {
  msg_id: number;
  kind: "activity_cancelled";
  user_id: string;
  activity_id: string;
  title: string;
  starts_at: string;
  location_label: string;
};

export const app = new Hono().basePath("/message-worker");

app.post("/", async (c) => {
  if (!authorised(c.req.header("Authorization"))) return fail("UNAUTHENTICATED");

  const { data, error } = await db.rpc("claim_message_jobs", { p_count: BATCH_SIZE });
  if (error) return fail("INTERNAL");

  const jobs = data as Job[];
  let sent = 0;
  let failed = 0;
  // A participant with neither an address nor a number is nobody this worker can reach. The job
  // is completed rather than retried: §8.4's retries are for a send that might work next time.
  let unreachable = 0;

  // Serially, like the moderation worker, for the reason §8.4 gives it: the ops host's cron
  // calls both and the batch is bounded by round trips rather than by CPU.
  for (const job of jobs) {
    try {
      const reached = await notify(job);
      if (reached) sent++;
      else unreachable++;
      await complete(job);
    } catch {
      // Not logged: an SES or End User Messaging validation error echoes the destination
      // address or number back, which §9.8 keeps out of logs. The kind is all §12.5 needs, and
      // leaving the job alone is what gives §8.4 its retry.
      console.log(`${LOG_LINES.failed} kind=${job.kind}`);
      failed++;
    }
  }

  console.log(
    `${LOG_LINES.run} claimed=${jobs.length} sent=${sent} unreachable=${unreachable} failed=${failed}`,
  );
  return Response.json({ claimed: jobs.length, sent, unreachable, failed });
});

// §2.1's "by email, or by SMS if they have no email", in that order. Returns false when the
// person has neither, which is a job to finish rather than retry.
async function notify(job: Job): Promise<boolean> {
  const { data, error } = await db.auth.admin.getUserById(job.user_id);
  // Not an error worth retrying if the account is gone — §5.4's deletion cascades the
  // participation away, so the claim would not have handed this out — but a transport failure
  // here should retry, and the two are indistinguishable from the result alone.
  if (error) throw new Error("the recipient could not be read");

  const email = data.user?.email;
  const phone = data.user?.phone;

  if (email) {
    await ses.send(
      new SendEmailCommand({
        FromEmailAddress: aws.emailFrom,
        Destination: { ToAddresses: [email] },
        Content: {
          Simple: {
            Subject: { Data: EMAIL_SUBJECT },
            Body: { Text: { Data: filled(EMAIL_BODY, job) } },
          },
        },
      }),
    );
    return true;
  }

  if (phone) {
    await sms.send(new SendTextMessageCommand(cancellationMessage(phone, job.title)));
    return true;
  }

  return false;
}

// Exported so the template and the registered DLT ids can be asserted without an AWS account,
// which is the whole of what this worker's "one API call" is testable as.
export function cancellationMessage(
  destination: string,
  title: string,
): SendTextMessageCommandInput {
  return {
    // §5.4 and §9.3 both keep a phone number in E.164; Auth stores it without the `+`, which
    // `SendTextMessage` requires.
    DestinationPhoneNumber: destination.startsWith("+") ? destination : `+${destination}`,
    OriginationIdentity: aws.originationIdentity,
    ConfigurationSetName: aws.configurationSet,
    MessageType: MESSAGE_TYPE,
    MessageBody: SMS_BODY.replace(SMS_PLACEHOLDER, title),
    // Indian carriers reject a message whose sender and text are not the registered pair
    // (§3.1). Both ids come from the DLT registration, `O4`.
    DestinationCountryParameters: {
      IN_ENTITY_ID: aws.dltEntityId,
      IN_TEMPLATE_ID: aws.dltTemplateId,
    },
  };
}

// Exported for the same reason: §9.8 bounds what a message may carry, so what the body
// interpolates is worth asserting directly. The Activity's own title, time and meeting point,
// and nobody's name.
export function filled(template: string, job: Job): string {
  return template
    .replaceAll("{title}", job.title)
    .replaceAll("{starts_at}", job.starts_at)
    .replaceAll("{location_label}", job.location_label);
}

// A completion the database refuses is this worker's bug rather than the queue's, so it raises
// and the job is left for §8.4's retry. NOT_FOUND is work another worker already did past the
// 60-second window, which is not a bug.
async function complete(job: Job) {
  const { data, error } = await db.rpc("complete_message_job", {
    p_msg_id: job.msg_id,
    p_kind: job.kind,
  });
  if (error) throw new Error("the message could not be completed");
  const answer = data as { error?: string } | null;
  if (answer?.error && answer.error !== "NOT_FOUND") {
    throw new Error("the completion was refused");
  }
}

// §7.3: the workers "check their secret key in code, since that key is not a JWT". Compared as
// bytes and in constant time, and not logged either way (§9.8).
export function authorised(authorization: string | undefined): boolean {
  const bearer = authorization?.match(/^Bearer (\S+)$/);
  if (!bearer) return false;

  const sent = new TextEncoder().encode(bearer[1]);
  const expected = new TextEncoder().encode(secretKey(SECRET_KEY_NAME));
  return sent.length === expected.length && timingSafeEqual(sent, expected);
}

// Read at boot, so a worker missing one fails on deploy rather than after it has claimed a batch
// and hidden it for 60 seconds — the shape §9.5 gives the guardrail identifiers.
function awsSettings() {
  const read = (name: string) => {
    const value = Deno.env.get(name);
    if (!value) throw new Error(`${name} is not set`);
    return value;
  };
  return {
    region: read(AWS_REGION_VARIABLE),
    emailFrom: read(EMAIL_FROM_VARIABLE),
    originationIdentity: read(ORIGINATION_IDENTITY_VARIABLE),
    configurationSet: read(CONFIGURATION_SET_VARIABLE),
    dltEntityId: read(DLT_ENTITY_ID_VARIABLE),
    dltTemplateId: read(DLT_TEMPLATE_ID_VARIABLE),
  };
}

app.notFound(() => fail("NOT_FOUND"));
app.onError(() => fail("INTERNAL"));

if (import.meta.main) Deno.serve(app.fetch);
