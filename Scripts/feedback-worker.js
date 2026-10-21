/**
 * Manifield feedback collector — a Cloudflare Worker.
 *
 * Accepts the JSON a Manifield build POSTs from Help → "Report a Bug…" (see
 * Packages/ManifieldDiagnostics/Sources/ManifieldDiagnostics/FeedbackSender.swift) and
 * forwards it to wherever the maintainer reads reports.
 *
 * The endpoint address is public. Manifield is GPLv3, so the URL in FeedbackEndpoint.swift
 * is readable by anyone, and anyone can POST to it. Nothing here may depend on the address
 * being secret: the defence is the rate limit, the body cap, and the shape check below.
 *
 * ── Deploying ────────────────────────────────────────────────────────────────────────────
 *
 *   npm install -g wrangler && wrangler login
 *   wrangler kv namespace create FEEDBACK_RATE          # note the id it prints
 *   wrangler secret put FORWARD_WEBHOOK_URL             # Slack/Discord/whatever reads reports
 *   wrangler deploy
 *
 * wrangler.toml:
 *
 *   name = "manifield-feedback"
 *   main = "Scripts/feedback-worker.js"
 *   compatibility_date = "2026-01-01"
 *
 *   kv_namespaces = [{ binding = "FEEDBACK_RATE", id = "<the id from the command above>" }]
 *
 *   # The custom domain. manifield.net must already be a zone on this Cloudflare account;
 *   # Cloudflare issues the certificate and creates the DNS record itself. A custom domain
 *   # rather than the workers.dev name on purpose — the address is compiled into builds in
 *   # testers' hands, so it has to survive moving to a different Worker or a different host.
 *   [[routes]]
 *   pattern = "feedback.manifield.net"
 *   custom_domain = true
 *
 * After the first deploy, check it end to end:
 *
 *   curl -i -X POST https://feedback.manifield.net/report \
 *     -H 'content-type: application/json' \
 *     -d '{"schemaVersion":1,"id":"deadbeef0000","kind":"other","message":"hello"}'
 *
 * Until this is deployed the endpoint 404s, and the app's Save to File / Copy to Clipboard
 * fallback is what testers use. That is by design, not a gap: no report is ever held in a
 * retry queue the tester cannot see.
 */

/** Only this shape is understood. The app stamps it; see FeedbackReport.schemaVersion. */
const SUPPORTED_SCHEMA_VERSIONS = [1];

/** 1 MB. A report is a message plus a ~200 KB log tail and maybe a ~200 KB crash report. */
const MAX_BODY_BYTES = 1024 * 1024;

/** Discord's hard cap on a webhook message body. Exceed it and the POST is rejected. */
const DISCORD_CONTENT_LIMIT = 2000;

/** Per-IP window. Generous for a person, useless for a flood. */
const RATE_LIMIT_WINDOW_SECONDS = 600;
const RATE_LIMIT_MAX_REPORTS = 5;

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);

    if (request.method === "OPTIONS") return preflight();
    if (url.pathname === "/health") return text(200, "ok");
    if (url.pathname !== "/report") return json(404, { error: "not found" });
    if (request.method !== "POST") return json(405, { error: "use POST" });

    const contentType = request.headers.get("content-type") || "";
    if (!contentType.includes("application/json")) {
      return json(415, { error: "expected application/json" });
    }

    // Cheap rejection first: a declared length over the cap costs nothing to refuse.
    const declaredLength = Number(request.headers.get("content-length") || "0");
    if (declaredLength > MAX_BODY_BYTES) {
      return json(413, { error: "report too large" });
    }

    const ip = request.headers.get("cf-connecting-ip") || "unknown";
    const limit = await checkRateLimit(env, ip);
    if (!limit.allowed) {
      return json(429, { error: "too many reports from this address" }, {
        "retry-after": String(limit.retryAfterSeconds),
      });
    }

    // Content-Length can lie, so the body is read with its own ceiling rather than trusted.
    let raw;
    try {
      raw = await readCapped(request, MAX_BODY_BYTES);
    } catch (error) {
      return json(413, { error: String(error.message || error) });
    }

    let report;
    try {
      report = JSON.parse(raw);
    } catch {
      return json(400, { error: "body is not JSON" });
    }

    const problem = validate(report);
    if (problem) return json(400, { error: problem });

    // Accepted from the tester's point of view the moment it is well-formed. Forwarding is
    // this server's problem, and a webhook that is briefly down must not turn into an error
    // the tester sees and a report they think was lost.
    // The IP deliberately does NOT travel into `meta`. It is needed for the rate limit and
    // nowhere else, and everything downstream of here is durable: the Discord attachment keeps
    // whatever it is given for as long as the channel exists, and a failed forward logs it into
    // Cloudflare's retained Workers logs. Since the app tells the tester their report goes to
    // this host and nothing more, an IP arriving in a chat message is a promise broken by a
    // field nobody looked at twice.
    ctx.waitUntil(forward(env, report, { receivedAt: new Date().toISOString() }));
    return json(202, { ok: true, id: String(report.id || "") });
  },
};

/** Rejects anything that is not a report of a version this Worker understands. */
function validate(report) {
  if (typeof report !== "object" || report === null) return "expected a JSON object";
  if (!SUPPORTED_SCHEMA_VERSIONS.includes(report.schemaVersion)) {
    return `unsupported schemaVersion: ${JSON.stringify(report.schemaVersion)}`;
  }
  if (!["bug", "idea", "other"].includes(report.kind)) return "unknown kind";
  if (typeof report.message !== "string" || report.message.trim() === "") {
    return "message is required";
  }
  return null;
}

/**
 * A fixed window per IP, in KV.
 *
 * Deliberately simple: KV is eventually consistent, so a determined flood spread across
 * edge locations gets more through than the nominal limit. That is an acceptable trade for
 * an alpha with ten testers — the point is to stop a stray script, not a botnet. Swap in a
 * Durable Object or Cloudflare's rate-limiting binding if this ever needs to be exact.
 */
async function checkRateLimit(env, ip) {
  if (!env.FEEDBACK_RATE) return { allowed: true };
  const window = Math.floor(Date.now() / 1000 / RATE_LIMIT_WINDOW_SECONDS);
  const key = `rate:${window}:${ip}`;
  const seen = Number((await env.FEEDBACK_RATE.get(key)) || "0");
  if (seen >= RATE_LIMIT_MAX_REPORTS) {
    return {
      allowed: false,
      retryAfterSeconds: RATE_LIMIT_WINDOW_SECONDS - (Math.floor(Date.now() / 1000) % RATE_LIMIT_WINDOW_SECONDS),
    };
  }
  // The TTL is the cleanup: nothing accumulates, and no IP is stored beyond the window.
  await env.FEEDBACK_RATE.put(key, String(seen + 1), {
    expirationTtl: RATE_LIMIT_WINDOW_SECONDS * 2,
  });
  return { allowed: true };
}

/** Reads the body, refusing to buffer more than the cap whatever the headers claimed. */
async function readCapped(request, maxBytes) {
  const reader = request.body?.getReader();
  if (!reader) return "";
  const chunks = [];
  let total = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > maxBytes) {
      await reader.cancel();
      throw new Error("report too large");
    }
    chunks.push(value);
  }
  const joined = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    joined.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return new TextDecoder().decode(joined);
}

/**
 * Sends the report on.
 *
 * Discord and Slack disagree about the field naming a message — `content` against `text` —
 * and each ignores the other's. That disagreement is silent: given `text`, Discord rejects
 * the whole POST as an empty message. So the destination is detected from the URL rather
 * than assumed, and a rejection is logged rather than swallowed.
 *
 * Set FORWARD_EMAIL_TO with an Email Routing `send_email` binding instead if a mailbox
 * suits better.
 */
async function forward(env, report, meta) {
  const webhook = env.FORWARD_WEBHOOK_URL;
  if (!webhook) {
    // No destination configured: at least put it where `wrangler tail` can see it, so a
    // report arriving before the webhook is set up is not silently dropped.
    console.log(JSON.stringify({ meta, report }));
    return;
  }

  try {
    const response = isDiscord(webhook)
      ? await postToDiscord(webhook, report, meta)
      : await postToGenericWebhook(webhook, report, meta);

    if (!response.ok) {
      // Loudly, and with the report beside it. The tester has already been told the report
      // was accepted, so a refused webhook is otherwise invisible from both ends — this is
      // what `wrangler tail` shows you when nothing arrives in the channel.
      const detail = (await response.text().catch(() => "")).slice(0, 500);
      console.log(`forward failed: ${response.status} ${response.statusText} ${detail}`);
      console.log(JSON.stringify({ meta, report }));
    }
  } catch (error) {
    console.log(`forward threw: ${String((error && error.message) || error)}`);
    console.log(JSON.stringify({ meta, report }));
  }
}

function isDiscord(webhookUrl) {
  try {
    const host = new URL(webhookUrl).hostname;
    return host === "discord.com" || host === "discordapp.com" || host.endsWith(".discord.com");
  } catch {
    return false;
  }
}

/**
 * Discord renders `content`, embeds and attachments, and drops every field it does not
 * know — so the full report cannot ride along beside the summary the way a JSON webhook
 * allows. It goes as an attached file, which is also the only way a 200 KB log tail and a
 * crash report survive a 2000 character message limit.
 */
async function postToDiscord(webhookUrl, report, meta) {
  const payload = {
    username: "Manifield feedback",
    content: clamp(summarize(report, meta, "**"), DISCORD_CONTENT_LIMIT),
    // The message text comes from whoever POSTed it and this endpoint is public, so a
    // report is never allowed to ping anyone.
    allowed_mentions: { parse: [] },
  };

  const form = new FormData();
  form.append("payload_json", JSON.stringify(payload));
  form.append(
    "files[0]",
    new Blob([JSON.stringify({ meta, report }, null, 2)], { type: "application/json" }),
    `report-${safeFilePart(report.id)}.json`
  );

  // Deliberately no content-type header: fetch sets multipart/form-data and, crucially,
  // the boundary. Setting it by hand omits the boundary and Discord rejects the body.
  return fetch(webhookUrl, { method: "POST", body: form });
}

/** Slack and most other JSON webhooks: `text`, with the whole report beside it. */
async function postToGenericWebhook(webhookUrl, report, meta) {
  return fetch(webhookUrl, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ text: summarize(report, meta, "*"), report }),
  });
}

function clamp(value, limit) {
  if (value.length <= limit) return value;
  return `${value.slice(0, limit - 32)}\n… truncated; see the attachment`;
}

/** This becomes a filename in a chat client. Keep it boring. */
function safeFilePart(id) {
  return String(id || "unknown").replace(/[^A-Za-z0-9_-]/g, "").slice(0, 32) || "unknown";
}

/**
 * A one-glance summary for a chat webhook; the full report is attached (Discord) or rides
 * along beside it (JSON webhooks).
 *
 * `bold` differs by destination: Discord reads `*text*` as italics and wants `**text**`,
 * while Slack means bold by the single asterisk.
 */
function summarize(report, meta, bold) {
  const snapshot = report.snapshot || {};
  const lines = [
    `${bold}${report.kind}${bold} from Manifield ${snapshot.appVersion || "?"} (${snapshot.buildNumber || "?"})`,
    `id ${report.id} · ${meta.receivedAt}`,
    report.message.slice(0, 1500),
  ];
  // Worth saying first: a translocated app misbehaves in ways that look like half a dozen
  // unrelated bugs, and the fix is one sentence.
  if (snapshot.isTranslocated) {
    lines.splice(1, 0, `:warning: ${bold}running translocated${bold} — ask them to move it to /Applications and reopen`);
  }
  if (report.email) lines.push(`reply to: ${report.email}`);
  if (report.crashLog) lines.push("(crash report attached)");
  return lines.join("\n");
}

function json(status, body, extraHeaders) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json", ...corsHeaders(), ...(extraHeaders || {}) },
  });
}

function text(status, body) {
  return new Response(body, { status, headers: { "content-type": "text/plain", ...corsHeaders() } });
}

function preflight() {
  return new Response(null, { status: 204, headers: corsHeaders() });
}

function corsHeaders() {
  return {
    "access-control-allow-origin": "*",
    "access-control-allow-methods": "POST, OPTIONS",
    "access-control-allow-headers": "content-type",
  };
}
