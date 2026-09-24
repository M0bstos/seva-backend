import { LIMITS, type Window } from "./limits.constants.ts";

export type LimitName = keyof typeof LIMITS;

// §12.2 makes this the only place a limit is named. The counting happens inside the
// route's one Postgres call, so what this builds is that call's arguments rather than
// a round trip of its own.
//
// `subject` is the person, or the caller's IP on the routes §7.3 limits "per person
// or IP". `userId` is null for those, and is what the 72-hour halving reads.
export function limitArgs(name: LimitName, subject: string, userId: string | null) {
  const limit: Window = LIMITS[name];
  return {
    p_bucket: `${name}:${subject}`,
    p_user_id: userId,
    p_per_minute: limit.perMinute ?? null,
    p_per_hour: limit.perHour ?? null,
    p_per_day: limit.perDay ?? null,
  };
}
