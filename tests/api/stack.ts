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
