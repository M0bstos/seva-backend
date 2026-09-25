import { LIMITS, type Window } from "./limits.constants.ts";

export type LimitName = keyof typeof LIMITS;

// §12.2 makes this the only place a limit is named. The counting happens inside the
// route's one Postgres call, so what this builds is that call's arguments rather than
// a round trip of its own.
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

// One client must map to one bucket, or §7.3's "per person or IP" cap counts nothing:
// an ordinary residential IPv6 allocation is a /64, so a caller who varies the low
// half gets a fresh budget every request, and `::ffff:203.0.113.7` is the same client
// as `203.0.113.7` by another spelling.
function normaliseAddress(ip: string): string {
  const address = ip.trim().toLowerCase().split("%")[0];

  const mapped = address.match(/^::ffff:(\d{1,3}(?:\.\d{1,3}){3})$/);
  if (mapped) return mapped[1];
  if (!address.includes(":")) return address;

  const groups = expandIpv6(address);
  return groups ? `${groups.slice(0, 4).join(":")}::/64` : address;
}

// Returns the eight groups of an IPv6 address, or null if it is not one this
// understands — an embedded IPv4 tail, say. A null falls back to the address as given,
// which over-counts rather than under-counts.
function expandIpv6(address: string): string[] | null {
  const halves = address.split("::");
  if (halves.length > 2) return null;

  const left = halves[0] ? halves[0].split(":") : [];
  const right = halves.length === 2 && halves[1] ? halves[1].split(":") : [];
  if (halves.length === 1) return left.length === 8 ? left : null;

  const gap = 8 - left.length - right.length;
  if (gap < 1) return null;
  return [...left, ...Array(gap).fill("0"), ...right];
}

// §17 O26: the routes §7.3 limits "per person or IP" have to count an anonymous
// caller without writing their address into the database. An HMAC of the address
// counts identically and cannot be reversed without a key that never enters Postgres,
// which is what keeps IP off §9.8's list in practice rather than only on paper.
//
// HMAC rather than a salted digest because the key is the thing being kept secret,
// and the salt is required rather than defaulted: a constant would make the hash a
// lookup table over the IPv4 space, which is worse than useless for looking safe.
export async function addressSubject(ip: string): Promise<string> {
  const salt = Deno.env.get("SEVA_RATE_LIMIT_SALT");
  if (!salt) throw new Error("SEVA_RATE_LIMIT_SALT is not set");

  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(salt),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const mac = await crypto.subtle.sign(
    "HMAC",
    key,
    new TextEncoder().encode(normaliseAddress(ip)),
  );
  return Array.from(new Uint8Array(mac), (b) => b.toString(16).padStart(2, "0")).join("");
}
