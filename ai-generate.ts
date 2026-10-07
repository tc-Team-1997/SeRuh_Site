// ═══════════════════════════════════════════════════════════════
//  SeRuh — AI Quote Generation (Supabase Edge Function)
//
//  Deploy name: ai-generate
//  Secrets required (Edge Functions → Secrets):
//    GEMINI_API_KEY = <your Google AI Studio key>
//
//  The AI provider key lives ONLY here on the server.
//  The frontend never sees it.
//
//  Flow: identify caller (user or guest) → check daily limit from
//  ai_settings → build prompt (safety rules included) → call the
//  provider → validate output → log to ai_generations → respond.
// ═══════════════════════════════════════════════════════════════

import { createClient } from "npm:@supabase/supabase-js@2";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const MOODS = ["Happy","Sad","Romantic","Peaceful","Lonely","Hopeful","Nostalgic","Emotional","Confused","Grateful","Angry","Motivated"];
const STYLES = ["Short & Deep","Poetic","Romantic","Minimal","Emotional","Philosophical","Hopeful","Midnight"];
const LENGTHS: Record<string, string> = {
  "One Line": "exactly one line, at most 16 words",
  "Short": "1–2 lines, at most 28 words",
  "Medium": "2–4 short lines, at most 55 words",
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });

const GENTLE_FAIL = "SeRuh couldn't find the words this time. Please try again. ❤️";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: true, message: GENTLE_FAIL }, 405);

  const started = Date.now();
  try {
    const { feeling, mood, style, length, visitor_id } = await req.json();

    // ── identify caller ──────────────────────────────────────
    const url = Deno.env.get("SUPABASE_URL")!;
    const service = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
    let userId: string | null = null;
    const authHeader = req.headers.get("Authorization") ?? "";
    if (authHeader.startsWith("Bearer ")) {
      const anon = createClient(url, Deno.env.get("SUPABASE_ANON_KEY")!, {
        global: { headers: { Authorization: authHeader } },
      });
      const { data } = await anon.auth.getUser();
      userId = data?.user?.id ?? null;
    }
    const visitor = typeof visitor_id === "string" && /^[0-9a-f-]{36}$/i.test(visitor_id) ? visitor_id : null;
    if (!userId && !visitor) return json({ error: true, message: GENTLE_FAIL }, 400);

    // ── settings + validation ────────────────────────────────
    const { data: settings } = await service.from("ai_settings").select("*").eq("id", 1).single();
    const s = settings ?? { model: "gemini-3.8-flash", guest_daily_limit: 5, user_daily_limit: 25, max_input_length: 2000, max_output_words: 60, temperature: 0.9 };

    const text = String(feeling ?? "").trim();
    if (text.length < 3) return json({ error: true, message: "Tell SeRuh a little more about what you're feeling." }, 400);
    if (text.length > s.max_input_length) return json({ error: true, message: `A little shorter, maybe — ${s.max_input_length} characters at most.` }, 400);
    const vMood = MOODS.includes(mood) ? mood : null;
    const vStyle = STYLES.includes(style) ? style : "Short & Deep";
    const vLength = LENGTHS[length] ? length : "Short";

    // ── daily limit ──────────────────────────────────────────
    const since = new Date(Date.now() - 24 * 3600 * 1000).toISOString();
    let countQ = service.from("ai_generations").select("id", { count: "exact", head: true }).gte("created_at", since);
    countQ = userId ? countQ.eq("user_id", userId) : countQ.eq("visitor_id", visitor).is("user_id", null);
    const { count } = await countQ;
    const limit = userId ? s.user_daily_limit : s.guest_daily_limit;
    if ((count ?? 0) >= limit) {
      return json({
        limited: true,
        message: userId
          ? "You've reached today's limit. SeRuh will be ready for you again tomorrow. 🕊️"
          : "Today's free words are done. Create a free account for more — or come back tomorrow. 🕊️",
      }, 429);
    }

    // ── prompt ───────────────────────────────────────────────
    const system = [
      "You are SeRuh, a quiet, poetic companion that turns feelings into short original quotations.",
      "Rules you must always follow:",
      "- Write ONE completely original quotation. Never reuse or closely paraphrase any known quote, lyric, or line from books, films, or the internet.",
      "- Never attribute the quote to any real person and never invent an author name. The quote is unsigned.",
      "- Match the requested mood, style and length.",
      "- The voice: emotional, elegant, simple, human. Not dramatic, not clichéd, no hashtags, no emojis, no quotation marks around the output.",
      "- You are not a therapist: never diagnose, never give medical or crisis advice inside the quote.",
      "- Refuse gently when the input requests hateful, sexual, violent or harmful content, targets a person, or is not really a feeling (e.g. spam, code, homework). Also refuse to generate when the input suggests self-harm or a crisis — instead reply with a caring sentence acknowledging their feeling and gently suggesting they talk to someone they trust or a professional.",
      'Respond with ONLY this JSON: {"ok": true, "quote": "..."} when you generate, or {"ok": false, "message": "..."} when you must decline (message = your gentle response, max 50 words).',
    ].join("\n");

    const userPrompt = [
      `Feeling described: """${text}"""`,
      vMood ? `Mood: ${vMood}` : null,
      `Style: ${vStyle}`,
      `Length: ${LENGTHS[vLength]}`,
      `Hard cap: ${s.max_output_words} words.`,
      "Line breaks are allowed with \\n. Generate a fresh variation, not a repeat of anything you may have produced before.",
    ].filter(Boolean).join("\n");

    // ── provider call (Gemini) ───────────────────────────────
    const key = Deno.env.get("GEMINI_API_KEY");
    if (!key) throw new Error("GEMINI_API_KEY missing");
    // Both fallbacks must name a model Google still serves. A retired
    // id does not fail loudly — it 404s, which this function turns into
    // a gentle message, and the feature stays quietly dead. See
    // seruh-phase14-migration.sql.
    const model = s.model || "gemini-3.8-flash";
    const res = await fetch(
      `https://generativelanguage.googleapis.com/v1beta/models/${encodeURIComponent(model)}:generateContent?key=${key}`,
      {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          systemInstruction: { parts: [{ text: system }] },
          contents: [{ role: "user", parts: [{ text: userPrompt }] }],
          generationConfig: {
            temperature: Number(s.temperature ?? 0.9),
            // maxOutputTokens caps thinking AND output together, and every
            // current Gemini Flash model thinks by default. 400 was ample for
            // gemini-2.0-flash, which did not think at all; on 3.x the model
            // spends the whole budget reasoning and returns finishReason
            // MAX_TOKENS with no text — which this function could only report
            // as "couldn't find the words". A 60-word quote is roughly 90
            // tokens; the rest is headroom for the thinking that now happens
            // before any of it is written.
            maxOutputTokens: 4096,
            // Gemini 3 Flash defaults to thinkingLevel "medium", which for a
            // two-line poem meant 17s, 42s and once past 120s of reasoning
            // that never reached the quote. Raising maxOutputTokens alone
            // made it worse — more budget simply bought more thinking.
            //
            // "low" is the floor here: "minimal" is rejected on 3.x Flash and
            // thinking cannot be switched off at all. Gemini 3 takes
            // thinkingLevel; thinkingBudget is the 2.5 field and the API errors if
            // the two are mixed.
            thinkingConfig: { thinkingLevel: "low" },
            responseMimeType: "application/json",
          },
        }),
      },
    );

    if (!res.ok) {
      const errText = await res.text();
      console.error("provider error", res.status, errText.slice(0, 300));
      await service.from("ai_generations").insert({
        user_id: userId, visitor_id: visitor, input_text: text.slice(0, 1000),
        mood: vMood, style: vStyle, length: vLength,
        model, status: "FAILED", duration_ms: Date.now() - started,
      });
      return json({ error: true, message: GENTLE_FAIL }, 502);
    }

    const payload = await res.json();
    const raw = payload?.candidates?.[0]?.content?.parts?.[0]?.text ?? "";
    let parsed: { ok?: boolean; quote?: string; message?: string } = {};
    try { parsed = JSON.parse(raw) } catch { /* fall through */ }

    // ── declined by safety ───────────────────────────────────
    if (parsed.ok === false) {
      const message = String(parsed.message ?? "").slice(0, 400) ||
        "Some feelings need a person, not a quote. Be gentle with yourself today. ❤️";
      await service.from("ai_generations").insert({
        user_id: userId, visitor_id: visitor, input_text: text.slice(0, 1000),
        mood: vMood, style: vStyle, length: vLength,
        model, status: "BLOCKED", duration_ms: Date.now() - started,
      });
      return json({ blocked: true, message });
    }

    // ── validate output ──────────────────────────────────────
    let quote = String(parsed.quote ?? "").trim().replace(/^["“]+|["”]+$/g, "");
    const words = quote.split(/\s+/).filter(Boolean);
    if (words.length > s.max_output_words) quote = words.slice(0, s.max_output_words).join(" ") + "…";
    if (quote.length < 4) {
      // Say why. A truncated candidate and a genuinely blank answer both
      // arrive here as an empty quote; finishReason and the token counts
      // are what separate them, and without this line the cause is
      // invisible from the logs — which is how this stayed hidden.
      console.error("empty generation",
        payload?.candidates?.[0]?.finishReason ?? "no finishReason",
        JSON.stringify(payload?.usageMetadata ?? {}));
      await service.from("ai_generations").insert({
        user_id: userId, visitor_id: visitor, input_text: text.slice(0, 1000),
        mood: vMood, style: vStyle, length: vLength,
        model, status: "FAILED", duration_ms: Date.now() - started,
      });
      return json({ error: true, message: GENTLE_FAIL }, 502);
    }

    // ── persist + respond ────────────────────────────────────
    const { data: row } = await service.from("ai_generations").insert({
      user_id: userId, visitor_id: visitor, input_text: text.slice(0, 1000),
      mood: vMood, style: vStyle, length: vLength,
      generated_text: quote, model, status: "SUCCESS", duration_ms: Date.now() - started,
    }).select("id").single();

    return json({
      quote,
      generation_id: row?.id ?? null,
      remaining: Math.max(0, limit - (count ?? 0) - 1),
    });
  } catch (e) {
    console.error("ai-generate fatal", e?.message ?? e);
    return json({ error: true, message: GENTLE_FAIL }, 500);
  }
});
