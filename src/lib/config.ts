// ─── Supabase ────────────────────────────────────────────────────────────────
// Project URL: safe to commit (not secret).
export const SUPABASE_URL = 'https://cmfliziflrbvoptfzhag.supabase.co';

// Anon key: find it in Supabase dashboard → Project Settings → API → anon/public.
// TODO: fill in your anon key before building.
export const SUPABASE_ANON_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImNtZmxpemlmbHJidm9wdGZ6aGFnIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NTg5NzczNzYsImV4cCI6MjA3NDU1MzM3Nn0.HsNJwDSkr-ZUoIZmKjoHEj3fVkYIPBPtDoZiQyYzqrc';

// ─── LiveKit ─────────────────────────────────────────────────────────────────
// The LiveKit server URL. The actual room token is issued by the claim_handoff
// edge function and returned in ClaimResponse.livekit_url, so this value is
// only used as a fallback. Keep it in sync with the edge function env var.
export const LIVEKIT_URL = 'wss://testproject-7v6kxfs5.livekit.cloud';
