# Supabase

`ai-generate` is an Edge Function. **Netlify does not deploy it** — merging a
pull request updates this repository and nothing else. It has to be sent to
Supabase separately, and forgetting that has already cost this project one
four-month outage and two misdiagnosed fixes.

## Deploying

    supabase link --project-ref stowxeobdtvhapkzsvaq   # once
    supabase functions deploy ai-generate

Without the CLI, paste `functions/ai-generate/index.ts` into
**Supabase → Edge Functions → ai-generate → Code** and press *Deploy updates*.
Paste the whole file; a partial paste is how a build ends up half-new.

## Checking what is actually running

The function reports its own input limit, so one call proves which build is
live without opening the dashboard:

    curl -s -X POST \
      https://stowxeobdtvhapkzsvaq.supabase.co/functions/v1/ai-generate \
      -H "apikey: $SERUH_ANON" -H "Authorization: Bearer $SERUH_ANON" \
      -H "Content-Type: application/json" \
      -d '{"feeling":"'"$(printf 'a%.0s' {1..9999})"'","visitor_id":"00000000-0000-4000-8000-000000000001"}'

The 400 it returns names the current `max_input_length`.

## What lives where

The model, the daily limits and the input cap are rows in `ai_settings`, not
code. Changing them needs no deploy — which is why a broken model is a
thirty-second fix once you know that is where it lives.

Secrets (`GEMINI_API_KEY`) are set under **Edge Functions → Secrets** and never
appear in this repository.
