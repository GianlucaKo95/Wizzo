-- ════════════════════════════════════════════════════════════════
-- 023_apns_device_tokens.sql — APNs-Geräte-Tokens für die native
-- iOS-App ("Du bist dran")
--
-- Pendant zu push_subscriptions (008_push_subscriptions.sql), aber für
-- Apple Push statt Web Push: ein Gerätetoken statt Endpoint+Schlüssel.
-- Ein Token gehört physisch zu einem Geräte-/App-Install, nicht zu einem
-- bestimmten Account - meldet sich ein anderer Nutzer auf demselben Gerät
-- an, soll derselbe Token-Datensatz einfach den neuen Besitzer bekommen,
-- daher unique auf `device_token` allein (nicht (user_id, device_token)
-- wie bei push_subscriptions, wo ein Browser potenziell mehrere Endpoints
-- gleichzeitig haben kann).
--
-- Schreibzugriff läuft direkt vom Client (RLS: nur der eigene Nutzer),
-- exakt wie bei push_subscriptions - das tatsächliche Versenden läuft
-- ausschließlich server-seitig in der Edge Function (sendTurnPush in
-- index.ts), die diese Tabelle zusätzlich zu push_subscriptions abfragt.
--
-- Voraussetzung: 000_full_reset.sql wurde bereits ausgeführt.
-- ════════════════════════════════════════════════════════════════

create table public.apns_device_tokens (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references auth.users(id) on delete cascade,
  device_token  text not null,
  created_at    timestamptz not null default now(),
  unique (device_token)
);

alter table public.apns_device_tokens enable row level security;

create policy "apns_device_tokens_own" on public.apns_device_tokens
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

grant select, insert, update, delete on public.apns_device_tokens to authenticated;
