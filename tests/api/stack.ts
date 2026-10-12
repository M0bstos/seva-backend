// §13.1's end-to-end tests run against the stack `supabase start` leaves running, so
// they take its URL and keys from the CLI rather than from a file. Nothing here is a
// secret: these are the local development keys, and the real ones live in function
// secrets (§9.5). An environment variable wins, so the same suite can be pointed at
// a staging project (§12.7).
type Stack = { url: string; publishableKey: string; secretKey: string };

let cached: Stack | null = null;

export async function stack(): Promise<Stack> {
  if (cached) return cached;

  const fromEnv = {
    url: Deno.env.get("SUPABASE_URL"),
    publishableKey: Deno.env.get("SUPABASE_PUBLISHABLE_KEY"),
    secretKey: Deno.env.get("SUPABASE_SECRET_KEY"),
  };
  if (fromEnv.url && fromEnv.publishableKey && fromEnv.secretKey) {
    cached = fromEnv as Stack;
    return cached;
  }

  const status = await new Deno.Command("supabase", {
    args: ["status", "-o", "json"],
    stdout: "piped",
    stderr: "null",
  }).output();
  if (!status.success) {
    throw new Error("the local stack is not running: `supabase start` first (§13.3)");
  }

  const printed = JSON.parse(new TextDecoder().decode(status.stdout));
  cached = {
    url: fromEnv.url ?? printed.API_URL,
    publishableKey: fromEnv.publishableKey ?? printed.PUBLISHABLE_KEY,
    secretKey: fromEnv.secretKey ?? printed.SECRET_KEY,
  };
  return cached;
}

// A confirmed account with a token, minted through the admin API. §9.3 signs people
// in by SMS code through the Send SMS hook, which no local stack has a provider for;
// what these tests need is a token this project signed, and this is the way to one
// that needs no inbox and no provider.
export async function signedIn(): Promise<{ token: string; userId: string }> {
  const { url, publishableKey, secretKey } = await stack();
  const email = `api-${crypto.randomUUID()}@seva.test`;
  const password = crypto.randomUUID();

  const created = await fetch(`${url}/auth/v1/admin/users`, {
    method: "POST",
    headers: {
      apikey: secretKey,
      Authorization: `Bearer ${secretKey}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({ email, password, email_confirm: true }),
  });
  const user = await created.json();

  const session = await fetch(`${url}/auth/v1/token?grant_type=password`, {
    method: "POST",
    headers: { apikey: publishableKey, "Content-Type": "application/json" },
    body: JSON.stringify({ email, password }),
  });
  const { access_token } = await session.json();
  return { token: access_token, userId: user.id };
}

// A signed-in account that has been through §7.3's `POST /account/onboarding`, which is what
// §5.4's gate wants before any write function will do anything. Before this route existed every
// end-to-end write stopped at that gate, so the suite could prove the chain reached Postgres and
// nothing past it.
//
// The date of birth is an adult's: §9.6 bars an under-18 from organising, and a suite that used a
// minor's date would fail `POST /activities` for a reason that has nothing to do with the route
// under test.
export async function onboarded(): Promise<{ token: string; userId: string }> {
  const account = await signedIn();
  const { status } = await callRoute("/account/onboarding", {
    method: "POST",
    token: account.token,
    body: {
      display_name: "API test",
      date_of_birth: "1995-04-04",
      terms_version: "2026-10-01",
      privacy_version: "2026-10-01",
    },
  });
  if (status !== 201) throw new Error(`onboarding answered ${status}`);
  return account;
}

// A read straight off the Data API as a signed-in person, for the end-to-end tests that need to see
// what a route wrote. §7.2 is what makes this possible without a secret key: "The Data API is for
// signed-in users only", and grants plus RLS decide what comes back.
export async function readTable(
  path: string,
  token: string,
): Promise<Record<string, unknown>[]> {
  const { url, publishableKey } = await stack();
  const response = await fetch(`${url}/rest/v1/${path}`, {
    headers: { apikey: publishableKey, Authorization: `Bearer ${token}` },
  });
  if (!response.ok) throw new Error(`the Data API answered ${response.status}`);
  return await response.json();
}

// **A signed URL from a local stack names a host only Docker can resolve, measured 6 October 2026.**
// Storage builds it from `SUPABASE_URL`, which the edge runtime sees as `http://kong:8000` — so the
// URL `POST /uploads` hands back is unusable from outside the container, and a `fetch` of it fails
// with a DNS error rather than an HTTP status. On a hosted project `SUPABASE_URL` is
// `https://<ref>.supabase.co` and the URL is right as issued, so this is the §17.1 local-versus-
// hosted trap again and not a route defect: nothing in the code chooses the host.
//
// The origin is rewritten here rather than in the test, so the next suite that uses a signed URL
// does not have to rediscover it.
export async function reachable(signedUrl: string): Promise<string> {
  const { url } = await stack();
  const issued = new URL(signedUrl);
  const local = new URL(url);
  issued.protocol = local.protocol;
  issued.host = local.host;
  return issued.toString();
}

// §7.1: every request carries the publishable key, a signed-in one carries the bearer
// token, and a function call carries the region header.
export async function callRoute(
  path: string,
  options: { token?: string; method?: string; body?: unknown; idempotencyKey?: string } = {},
): Promise<{ status: number; body: Record<string, unknown>; headers: Headers }> {
  const { url, publishableKey } = await stack();
  const headers: Record<string, string> = {
    apikey: publishableKey,
    "x-region": "ap-south-1",
  };
  if (options.token) headers.Authorization = `Bearer ${options.token}`;
  if (options.idempotencyKey) headers["Idempotency-Key"] = options.idempotencyKey;
  if (options.body !== undefined) headers["Content-Type"] = "application/json";

  const response = await fetch(`${url}/functions/v1${path}`, {
    method: options.method ?? "GET",
    headers,
    body: options.body === undefined ? undefined : JSON.stringify(options.body),
  });
  const text = await response.text();
  return {
    status: response.status,
    body: text ? JSON.parse(text) : {},
    headers: response.headers,
  };
}
