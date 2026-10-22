// @ts-nocheck
import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import webpush from "npm:web-push@3";
import { SignJWT, importPKCS8 } from "npm:jose@5";

import {
  SUITS, buildDeck, shuffle, trickWinner, trickWinnerWithoutBomb,
  calcScore, forbiddenDealerBid, aiBid, isAlwaysPlayable, aiChooseCard,
  suitDot, cardLabel, aiBidIndianPoker, aiWorstCard, aiChooseRainbowSuit,
} from "./logic.ts";


const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

// Lightweight per-user rate limit (per instance): 20 actions / 10s.
const rateMap = new Map<string, number[]>();
function rateLimited(userId: string): boolean {
  const now = Date.now();
  const hits = (rateMap.get(userId) ?? []).filter(t => now - t < 10_000);
  hits.push(now);
  rateMap.set(userId, hits);
  return hits.length > 20;
}

// Separate, stricter limit for sendFriendRequest attempts that didn't
// result in a new row (no such user, already friends/pending, self) - a
// burst of exactly those is what username enumeration looks like, even
// though each individual response is identical to a real send.
const friendFailMap = new Map<string, number[]>();
function friendLookupLocked(userId: string): boolean {
  const now = Date.now();
  const hits = (friendFailMap.get(userId) ?? []).filter(t => now - t < 60_000);
  return hits.length >= 4;
}
function recordFriendLookupFailure(userId: string) {
  const now = Date.now();
  const hits = (friendFailMap.get(userId) ?? []).filter(t => now - t < 60_000);
  hits.push(now);
  friendFailMap.set(userId, hits);
}

const DEBUG = Deno.env.get("WIZARD_DEBUG") === "1";
const dbg = (...a: unknown[]) => { if (DEBUG) console.log(...a); };

function addLog(room, msg) {
  room.log = [msg, ...room.log].slice(0, 30);
}


// ── Server-side game driver ─────────────────────────────────────
// Keeps the game moving without depending on any client being online.
// Client triggers remain as fallback; all paths are idempotent (ai_lock, phase guards).
let waitUntilWarned = false;
function schedule(task: () => Promise<unknown>, delayMs: number) {
  const p = (async () => {
    await new Promise(r => setTimeout(r, delayMs));
    try { await task(); } catch (e) { console.error("[schedule]", (e as Error).message); }
  })();
  const waitUntil = (globalThis as any).EdgeRuntime?.waitUntil;
  if (typeof waitUntil === "function") {
    waitUntil(p);
  } else if (!waitUntilWarned) {
    // Runtime doesn't expose EdgeRuntime.waitUntil (unexpected outside local dev).
    // Without it the instance may be frozen after the response is sent, silently
    // dropping the server-driven AI/clearTrick path back onto client polling only.
    // Logged once per instance so this is visible in production logs instead of
    // failing invisibly.
    waitUntilWarned = true;
    console.error("[schedule] EdgeRuntime.waitUntil unavailable — falling back to client-triggered scheduling only");
  }
}

function scheduleAITurn(supabase, roomId, delayMs = 1800) {
  schedule(async () => {
    const { data: r } = await supabase.from("rooms").select("*").eq("id", roomId).single();
    if (!r || r.phase !== "playing") return;
    const { data: ps } = await supabase.from("room_players").select("*").eq("room_id", roomId).order("player_index");
    if (!ps?.[r.current_player]?.is_ai || !ps[r.current_player]?.hand?.length) return;
    await aiPlayNext(supabase, roomId, { ...r, current_trick: r.current_trick ?? [] }, ps);
  }, delayMs);
}

function scheduleClearTrick(supabase, roomId, delayMs = 5000) {
  schedule(async () => {
    const { data: r } = await supabase.from("rooms").select("*").eq("id", roomId).single();
    if (!r || r.phase !== "trickEnd") return;
    await handleClearTrick(supabase, roomId, r);
  }, delayMs);
}

// Client calls "witchRevealDone" ~4s after showing the swap result (see App.tsx).
// Unlike trickEnd this had no server-side fallback at all - if every client
// disconnects right as phase becomes "witchReveal", the room was stuck there
// forever. Mirrors scheduleClearTrick/handleClearTrick.
function scheduleWitchRevealDone(supabase, roomId, delayMs = 6000) {
  schedule(async () => {
    const { data: r } = await supabase.from("rooms").select("*").eq("id", roomId).single();
    if (!r || r.phase !== "witchReveal") return;
    await handleWitchRevealDone(supabase, roomId, r);
  }, delayMs);
}

async function upd(promise, label) {
  const { error } = await promise;
  if (error) console.error(`[db:${label}]`, error.message);
  return { error };
}

// Reveals the card hidden under the Werewolf trump card the moment the
// Vampire is actually played (not at trick-end) - so any player still to
// act in this trick sees the same information a real reveal would give
// them immediately, instead of only finding out from the log afterwards.
// Persists the reveal to `rooms.original_trump_card` right away; advanceTrick
// picks it up from there once the trick resolves, instead of re-reading and
// re-popping the deck itself.
async function revealCardUnderWerewolf(supabase, roomId, room) {
  const { data: deckRow } = await supabase.from("room_decks").select("deck").eq("room_id", roomId).maybeSingle();
  const remaining = deckRow?.deck ?? [];
  const cardUnder = remaining.length > 0 ? remaining[remaining.length - 1] : null;
  if (!cardUnder) return null;
  addLog(room, `🧛 Vampir deckt Karte unter dem Werwolf auf: ${cardLabel(cardUnder)}`);
  room.original_trump_card = cardUnder;
  await upd(supabase.from("room_decks").upsert({ room_id: roomId, deck: remaining.slice(0, -1) }), "deck.vampireReveal");
  await upd(supabase.from("rooms").update({ original_trump_card: cardUnder, log: room.log }).eq("id", roomId), "log.vampireReveal");
  return cardUnder;
}

async function handleClearTrick(supabase, roomId, room) {
      if (room.phase !== "trickEnd") return json({ ok: true });

      // Load fresh state
      const { data: freshCR2 } = await supabase.from("rooms").select("*").eq("id", roomId).single();
      const { data: freshCP2 } = await supabase.from("room_players").select("*").eq("room_id", roomId).order("player_index");
      const fr = freshCR2 ?? room;
      const fp2 = freshCP2 ?? [];

      // Loose != null: treats undefined (missing DB column) as "no pending item"
      // Strict !== null would deadlock the game in trickEnd if a column is missing
      const hasPendingItems = fr.pending_rainbow9 != null ||
        fr.pending_rainbow9_deferred != null ||
        Array.isArray(fr.pending_rainbow7) ||
        fr.pending_witch != null;

      if (hasPendingItems) {
        // Pending actions still open - ensure we stay in trickEnd
        // so the pending action handlers can fire
        if (fr.phase !== "trickEnd") {
          await supabase.from("rooms").update({ phase: "trickEnd" }).eq("id", roomId);
        }
        return json({ ok: true });
      }

      // Check round over
      const totalTricks2 = fp2.reduce((sum, p) => sum + (p.tricks_won ?? 0), 0);
      const allEmpty2 = fp2.every(p => (p.hand ?? []).length === 0);
      const roundOver2 = allEmpty2 || totalTricks2 >= fr.round;

      dbg("[clearTrick] totalTricks:", totalTricks2, "round:", fr.round, "allEmpty:", allEmpty2, "roundOver:", roundOver2, "players tricks_won:", fp2.map(p => p.tricks_won));

      if (roundOver2) {
        // Atomically set phase to "scoring" first to prevent concurrent clearTrick calls
        // from both calling endRound and double-counting points.
        // A plain .update() doesn't error when its WHERE clause matches 0 rows, so both
        // racing calls would see no error and both proceed - .select() forces PostgREST
        // to return the affected rows, so an empty result reliably means we lost the race
        // (same pattern as the ai_lock check in aiPlayNext).
        const { data: lockRows, error: lockError } = await supabase.from("rooms")
          .update({ phase: "scoring" })
          .eq("id", roomId)
          .eq("phase", "trickEnd") // only update if still in trickEnd (optimistic lock)
          .select("id");
        if (lockError || !lockRows || lockRows.length === 0) return json({ ok: true }); // lost the race
        await endRound(supabase, roomId, fr, fp2);
      } else {
        // Just set phase to playing - client will trigger AI via triggerAI
        const nextPlayerIdx = fr.last_trick_winner ?? fr.current_player;
        await supabase.from("rooms").update({
          phase: "playing",
          current_player: nextPlayerIdx
        }).eq("id", roomId);
      scheduleAITurn(supabase, roomId);
      if (!fp2[nextPlayerIdx]?.is_ai) await notifyPlayerTurn(supabase, roomId, nextPlayerIdx);
      }
      return json({ ok: true });
}

async function handleWitchRevealDone(supabase, roomId, room) {
  if (room.phase !== "witchReveal") return json({ ok: true });

  const { data: wrPlayers } = await supabase.from("room_players").select("*").eq("room_id", roomId).order("player_index");
  const { data: wrRoom } = await supabase.from("rooms").select("*").eq("id", roomId).single();
  const fr = wrRoom ?? room;
  const fp = wrPlayers ?? [];

  const totalTWR = fp.reduce((s, p) => s + (p.tricks_won ?? 0), 0);
  const allEWR = fp.every(p => (p.hand ?? []).length === 0);
  if (allEWR || totalTWR >= fr.round) {
    // Same atomic optimistic lock as handleClearTrick - only one of two
    // concurrent calls (client trigger + server schedule) may proceed.
    const { data: lockRows, error: lockError } = await supabase.from("rooms")
      .update({ phase: "scoring", witch_swap: null })
      .eq("id", roomId)
      .eq("phase", "witchReveal")
      .select("id");
    if (lockError || !lockRows || lockRows.length === 0) return json({ ok: true }); // lost the race
    await endRound(supabase, roomId, { ...fr, witch_swap: null }, fp);
    return json({ ok: true });
  }

  await supabase.from("rooms").update({ phase: "playing", witch_swap: null }).eq("id", roomId);
  return json({ ok: true });
}

function json(data, status = 200) {
  return new Response(JSON.stringify(data), {
    status, headers: { ...corsHeaders, "Content-Type": "application/json" }
  });
}

// APNs provider token (ES256 JWT, signed with the Apple Push auth key -
// APNS_AUTH_KEY is the .p8 file's raw PEM content, APNS_KEY_ID/APNS_TEAM_ID
// come from the same Apple Developer "Keys" page). Apple's own docs say not
// to mint a fresh one per notification (repeated signing in a short window
// can trigger a rate limit) - cached module-scope for up to ~50 minutes
// (Apple rejects tokens older than 60), same "mutable state reused across
// invocations in a warm instance" pattern as rateMap/friendFailMap above.
let cachedApnsToken: { jwt: string; signedAt: number } | null = null;
async function getApnsProviderToken(): Promise<string | null> {
  const keyId = Deno.env.get("APNS_KEY_ID");
  const teamId = Deno.env.get("APNS_TEAM_ID");
  const authKey = Deno.env.get("APNS_AUTH_KEY");
  if (!keyId || !teamId || !authKey) return null; // not configured - silently skip

  if (cachedApnsToken && Date.now() - cachedApnsToken.signedAt < 50 * 60 * 1000) {
    return cachedApnsToken.jwt;
  }
  const privateKey = await importPKCS8(authKey, "ES256");
  const jwt = await new SignJWT({})
    .setProtectedHeader({ alg: "ES256", kid: keyId })
    .setIssuedAt()
    .setIssuer(teamId)
    .sign(privateKey);
  cachedApnsToken = { jwt, signedAt: Date.now() };
  return jwt;
}

// Sends one APNs push to one device token. `APNS_ENV` picks sandbox
// (Xcode/TestFlight-internal builds) vs production (TestFlight-external/App
// Store) - defaults to sandbox, since that's what a build run straight from
// Xcode during development uses. Dead tokens (BadDeviceToken/Unregistered -
// uninstalled, or a stale sandbox token hit against production and vice
// versa) get cleaned up, same as a dead Web Push subscription above.
async function sendApnsPush(supabase, deviceToken, title, body) {
  const jwt = await getApnsProviderToken();
  if (!jwt) return;
  const bundleId = "com.gianlucako95.wizzo"; // PRODUCT_BUNDLE_IDENTIFIER in project.yml, not secret
  const host = Deno.env.get("APNS_ENV") === "production" ? "api.push.apple.com" : "api.sandbox.push.apple.com";
  try {
    const res = await fetch(`https://${host}/3/device/${deviceToken}`, {
      method: "POST",
      headers: {
        authorization: `bearer ${jwt}`,
        "apns-topic": bundleId,
        "apns-push-type": "alert",
        "apns-priority": "10",
      },
      body: JSON.stringify({ aps: { alert: { title, body }, sound: "default" } }),
    });
    if (!res.ok) {
      const errBody = await res.json().catch(() => null);
      // 410 Unregistered is always a dead token; a 400 is only a dead token
      // for the specific "BadDeviceToken" reason - every other 400 reason
      // (BadTopic, PayloadTooLarge, ...) is a real config/payload problem on
      // THIS send, not evidence the token itself is bad, so only that one
      // reason should ever delete a row.
      if (res.status === 410 || (res.status === 400 && errBody?.reason === "BadDeviceToken")) {
        await upd(supabase.from("apns_device_tokens").delete().eq("device_token", deviceToken), "sendApnsPush.deadToken");
      } else {
        console.error("[sendApnsPush] push failed:", res.status, errBody);
      }
    }
  } catch (e) {
    console.error("[sendApnsPush] error:", e?.message ?? e);
  }
}

// Sends a push notification (Web Push and/or native APNs, whichever the
// player has registered) to one player, if they're human, have at least one
// registration, and aren't currently present in the room (room_players.
// connected, maintained by syncPresence from the client's realtime presence
// channel) - no point pushing "it's your turn" at someone who's already
// looking at the screen where that's obvious. Never throws - a push
// provider outage or missing VAPID/APNs config should never break the
// actual game action that triggered it.
async function sendTurnPush(supabase, roomId, playerIndex, title, body) {
  try {
    const { data: player } = await supabase.from("room_players")
      .select("user_id, is_ai, connected").eq("room_id", roomId).eq("player_index", playerIndex).maybeSingle();
    if (!player || player.is_ai || !player.user_id || player.connected) return;

    const { data: tokens } = await supabase.from("apns_device_tokens").select("device_token").eq("user_id", player.user_id);
    if (tokens && tokens.length > 0) {
      await Promise.all(tokens.map((t) => sendApnsPush(supabase, t.device_token, title, body)));
    }

    const vapidPublic = Deno.env.get("VAPID_PUBLIC_KEY");
    const vapidPrivate = Deno.env.get("VAPID_PRIVATE_KEY");
    const vapidSubject = Deno.env.get("VAPID_SUBJECT");
    if (!vapidPublic || !vapidPrivate || !vapidSubject) return; // not configured - silently skip

    const { data: subs } = await supabase.from("push_subscriptions").select("*").eq("user_id", player.user_id);
    if (!subs || subs.length === 0) return;

    webpush.setVapidDetails(vapidSubject, vapidPublic, vapidPrivate);
    const payload = JSON.stringify({ title, body });
    await Promise.all(subs.map(async (s) => {
      try {
        await webpush.sendNotification({ endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } }, payload);
      } catch (e) {
        // 404/410 = the subscription is dead (uninstalled, permission revoked,
        // browser data cleared) - clean it up instead of retrying it forever.
        if (e?.statusCode === 404 || e?.statusCode === 410) {
          await upd(supabase.from("push_subscriptions").delete().eq("id", s.id), "sendTurnPush.deadSub");
        } else {
          console.error("[sendTurnPush] push failed:", e?.message ?? e);
        }
      }
    }));
  } catch (e) {
    console.error("[sendTurnPush] error:", e?.message ?? e);
  }
}

// Wired into the chokepoints that cover normal turn progression
// (tickAIBids, advanceBidder, advanceTrick's mid-trick advance,
// handleClearTrick's new-trick resume). Trump/werewolf suit choice and
// witch swap don't trigger one yet.
function notifyPlayerTurn(supabase, roomId, playerIndex) {
  return sendTurnPush(supabase, roomId, playerIndex, "Du bist dran!", "Wizzo wartet auf deinen Zug.");
}

// Jongleur (7½): everyone in pending_rainbow7 needs to pick a card to pass
// on - notify each human in that list, not just one "current" player.
function notifyRainbow7Pass(supabase, roomId, playerIndex) {
  return sendTurnPush(supabase, roomId, playerIndex, "Karte weitergeben!", "Der Jongleur ist im Spiel - wähle eine Karte zum Weitergeben.");
}

// Wolke (9¾): the trick winner must adjust their prediction.
function notifyRainbow9Adjust(supabase, roomId, playerIndex) {
  return sendTurnPush(supabase, roomId, playerIndex, "Vorhersage anpassen!", "Die Wolke verlangt eine neue Vorhersage.");
}

// Hexe: the witch player must swap a hand card with one from the trick.
function notifyWitchSwap(supabase, roomId, playerIndex) {
  return sendTurnPush(supabase, roomId, playerIndex, "Karte tauschen!", "Die Hexe ist im Spiel - tausche eine Karte mit dem Stich.");
}

// Dealer must pick a trump suit (Zauberer/Drache/Vampir/Jongleur/Wolke as trump card).
function notifyChooseTrump(supabase, roomId, playerIndex) {
  return sendTurnPush(supabase, roomId, playerIndex, "Trumpf wählen!", "Du bist Dealer - wähle die Trumpffarbe.");
}

// Dealer must pick a suit for the werewolf (werewolf drawn as/in place of the trump card).
function notifyChooseWerewolf(supabase, roomId, playerIndex) {
  return sendTurnPush(supabase, roomId, playerIndex, "Stichfarbe wählen!", "Der Werwolf ist deine Trumpfkarte - wähle die Stichfarbe.");
}

async function tickAIBids(supabase, roomId, room, players) {
  // Always reload fresh players to get correct bid state
  const { data: freshBidPlayers } = await supabase.from("room_players").select("*").eq("room_id", roomId).order("player_index");
  const freshPlayers = freshBidPlayers ?? players;
  let current = room.current_player;
  const bids = freshPlayers.map(p => p.bid);
  // Use fresh players for AI bidding
  players = freshPlayers;
  const startBidder = (room.dealer + 1) % players.length;
  let iterations = 0;
  const isIndianPokerRound = room.round === 1;

  while (players[current]?.is_ai && iterations++ < players.length) {
    let bid = isIndianPokerRound
      ? aiBidIndianPoker(players, current, room.trump_suit, room.werewolf_suit)
      : aiBid(players[current].hand, room.trump_suit, room.werewolf_suit);
    const forbidden = forbiddenDealerBid(bids, room.dealer, room.round);
    if (room.dealer === current && forbidden !== null && bid === forbidden) {
      bid = bid === room.round ? 0 : bid + 1;
    }
    bids[current] = bid;
    players[current].bid = bid;
    addLog(room, `${players[current].ai_name} bietet: ${bid}`);
    await supabase.from("room_players").update({ bid }).eq("id", players[current].id);
    current = (current + 1) % players.length;
    if (current === startBidder && bids.every(b => b !== null)) break;
  }

  const allBid = bids.every(b => b !== null);
  const newPhase = allBid ? "playing" : "bidding";
  const newCurrent = allBid ? startBidder : current;
  await supabase.from("rooms").update({ phase: newPhase, current_player: newCurrent, log: room.log }).eq("id", roomId);
  if (!players[newCurrent]?.is_ai) await notifyPlayerTurn(supabase, roomId, newCurrent);

  dbg("[tickAIBids] allBid:", allBid, "newCurrent:", newCurrent, "is_ai:", players[newCurrent]?.is_ai);
  return json({ ok: true });
}

async function aiPlayNext(supabase, roomId, room, players) {
  const current = room.current_player;
  dbg("[aiPlayNext] called, current_player:", current, "phase:", room.phase);
  // Note: no blocking delay here - would cause timeout
  // Delay is handled client-side via triggerAI polling

  // Always load fresh players from DB to get correct hands
  const { data: freshPlayers, error: fpErr } = await supabase
    .from("room_players").select("*").eq("room_id", roomId).order("player_index");

  dbg("[aiPlayNext] freshPlayers loaded:", freshPlayers?.length, "error:", fpErr?.message);
  const allPlayers = freshPlayers ?? players;

  let currentPlayer = allPlayers[current];
  dbg("[aiPlayNext] currentPlayer:", currentPlayer?.ai_name, "is_ai:", currentPlayer?.is_ai, "hand length:", currentPlayer?.hand?.length);

  if (!currentPlayer?.is_ai) {
    dbg("[aiPlayNext] not AI, returning");
    return json({ ok: true });
  }

  // If hand is empty, wait and retry - DB write may not be committed yet
  if (!currentPlayer.hand || currentPlayer.hand.length === 0) {
    dbg("[aiPlayNext] empty hand, waiting 800ms and retrying...");
    await new Promise(r => setTimeout(r, 800));
    const { data: retryPlayers } = await supabase
      .from("room_players").select("*").eq("room_id", roomId).order("player_index");
    currentPlayer = (retryPlayers ?? allPlayers)[current];
    dbg("[aiPlayNext] after retry, hand length:", currentPlayer?.hand?.length);
    if (!currentPlayer?.hand || currentPlayer.hand.length === 0) {
      dbg("[aiPlayNext] still empty after retry!");
      return json({ ok: true });
    }
  }

  const card = aiChooseCard(currentPlayer.hand, room.current_trick ?? [], room.trump_suit, room.werewolf_suit, currentPlayer.bid, currentPlayer.tricks_won ?? 0);
  if (!card) {
    dbg("[aiPlayNext] aiChooseCard returned undefined! hand:", JSON.stringify(currentPlayer.hand));
    return json({ ok: true });
  }
  dbg("[aiPlayNext] AI plays:", cardLabel(card));
  const newHand = currentPlayer.hand.filter(c => c.id !== card.id);
  const expectedTrickLen = (room.current_trick ?? []).length;

  // Atomic guard: attempt to advance current_player away from itself as a lock.
  // Only one concurrent call can successfully claim the turn by using a WHERE
  // condition on current_player - the second call's update affects 0 rows.
  const lockToken = `locked-${Date.now()}-${Math.random()}`;
  const { data: lockResult, error: lockErr } = await supabase
    .from("rooms")
    .update({ ai_lock: lockToken })
    .eq("id", roomId)
    .eq("current_player", current)
    .select("ai_lock");
  if (lockErr) {
    // Column missing or DB error: proceed WITHOUT lock rather than deadlocking the game.
    // The trick-length + card-presence checks below still catch most races.
    dbg("[aiPlayNext] ai_lock unavailable (", lockErr.message, ") - proceeding without lock");
  } else if (!lockResult || lockResult.length === 0 || lockResult[0].ai_lock !== lockToken) {
    dbg("[aiPlayNext] could not acquire lock, concurrent call in progress, skipping");
    return json({ ok: true });
  }
  // Re-verify trick state and card presence after acquiring lock
  const { data: freshRoomCheck } = await supabase.from("rooms").select("current_trick, current_player").eq("id", roomId).single();
  const actualTrickLen = (freshRoomCheck?.current_trick ?? []).length;
  if (actualTrickLen !== expectedTrickLen || freshRoomCheck?.current_player !== current) {
    dbg("[aiPlayNext] trick state changed, skipping. expected:", expectedTrickLen, "actual:", actualTrickLen);
    return json({ ok: true });
  }
  const { data: verifyPlayer } = await supabase
    .from("room_players").select("hand").eq("id", currentPlayer.id).single();
  const dbHand = verifyPlayer?.hand ?? [];
  if (!dbHand.some((c: any) => c.id === card.id)) {
    dbg("[aiPlayNext] card already played by concurrent call, skipping");
    return json({ ok: true });
  }
  await upd(supabase.from("room_players").update({ hand: newHand }).eq("id", currentPlayer.id), "aiPlay.hand");

  // For wizardfool: AI decides wizard or fool based on whether it needs more tricks
  let playedCard = card;
  if (card.specialType === "wizardfool") {
    const needsTricks = (currentPlayer.tricks_won ?? 0) < (currentPlayer.bid ?? 0);
    const wizardInTrick = (room.current_trick ?? []).some(t => t.card.type === "wizard");
    const choice = (needsTricks && !wizardInTrick) ? "wizard" : "fool";
    playedCard = { ...card, type: choice };
    addLog(room, `${currentPlayer.ai_name}: Ron als ${choice === "wizard" ? "Zauberer" : "Narr"}`);
  } else if (card.specialType === "rainbow7" || card.specialType === "rainbow9") {
    const needsTricks = (currentPlayer.tricks_won ?? 0) < (currentPlayer.bid ?? 0);
    const suit = aiChooseRainbowSuit(room.current_trick ?? [], room.trump_suit, room.werewolf_suit, needsTricks);
    playedCard = { ...card, suit };
    addLog(room, `${currentPlayer.ai_name}: ${cardLabel(playedCard)}`);
  } else {
    addLog(room, `${currentPlayer.ai_name}: ${cardLabel(card)}`);
  }

  if (card.specialType === "vampire" && room.werewolf_suit) {
    await revealCardUnderWerewolf(supabase, roomId, room);
  }

  const newTrick = [...(room.current_trick ?? []), { card: playedCard, playerIndex: current }];
  // Let advanceTrick reload players fresh from DB - passing stale updPlayers
  // can cause empty-hand issues when DB writes from previous round haven't propagated
  return await advanceTrick(supabase, roomId, { ...room, current_trick: newTrick, current_player: current, log: room.log }, null);
}

async function advanceBidder(supabase, roomId, room, players, bids) {
  const startBidder = (room.dealer + 1) % players.length;
  const allBid = bids.every(b => b !== null);
  const next = (room.current_player + 1) % players.length;
  const newPhase = allBid ? "playing" : "bidding";
  const newCurrent = allBid ? startBidder : next;
  await supabase.from("rooms").update({ phase: newPhase, current_player: newCurrent, log: room.log }).eq("id", roomId);
  if (allBid && players[newCurrent]?.is_ai) scheduleAITurn(supabase, roomId);
  if (!allBid && players[newCurrent]?.is_ai) {
    return await tickAIBids(supabase, roomId, { ...room, phase: newPhase, current_player: newCurrent }, players);
  }
  if (!players[newCurrent]?.is_ai) await notifyPlayerTurn(supabase, roomId, newCurrent);
  return json({ ok: true });
}

async function endRound(supabase, roomId, room, players) {
  // Guard: only run if phase is trickEnd or scoring (not roundEnd/gameEnd/playing)
  // This prevents double scoring if endRound is called concurrently
  const validPhases = ["trickEnd", "scoring", "playing"];
  if (!validPhases.includes(room.phase)) {
    dbg("[endRound] skipping - phase is", room.phase, "(already processed)");
    return;
  }
  const results = players.map((p, i) => {
    const delta = calcScore(p.bid ?? 0, p.tricks_won);
    return { playerIndex: i, name: p.ai_name, bid: p.bid ?? 0, got: p.tricks_won, delta, totalScore: p.score + delta };
  });
  // Atomic: all scores + history in one transaction (RPC); falls back to
  // per-row writes if the RPC isn't deployed yet.
  const { error: rpcErr } = await supabase.rpc("apply_round_scores", {
    p_room_id: roomId, p_round: room.round, p_results: results,
  });
  if (rpcErr) {
    console.error("[endRound] RPC unavailable, falling back:", rpcErr.message);
    for (const r of results) {
      await upd(supabase.from("room_players").update({ score: r.totalScore }).eq("id", players[r.playerIndex].id), "endRound.score");
    }
    await upd(supabase.from("round_history").insert({ room_id: roomId, round: room.round, results }), "endRound.history");
  }

  if (room.round >= room.max_rounds) {
    await supabase.from("rooms").update({ phase: "gameEnd", log: room.log }).eq("id", roomId);
    // Save stats. tricks_bid/tricks_won must be each player's own bid/got
    // summed across every round of the game - results here only holds the
    // round that just finished, and summing across rr in that array sums
    // everyone's bid together instead of one player's own. Reconstruct the
    // real per-player totals from round_history, which by now already has
    // this round's row (apply_round_scores inserts it in the same
    // transaction as the score update, and the fallback path above inserts
    // it before this block runs).
    const { data: allRounds } = await supabase.from("round_history").select("results").eq("room_id", roomId);
    const totalsByPlayer = new Map();
    for (const rh of allRounds ?? []) {
      for (const entry of rh.results ?? []) {
        const t = totalsByPlayer.get(entry.playerIndex) ?? { bid: 0, got: 0, hit: 0, played: 0 };
        t.bid += entry.bid ?? 0;
        t.got += entry.got ?? 0;
        t.played += 1;
        if (entry.bid === entry.got) t.hit += 1;
        totalsByPlayer.set(entry.playerIndex, t);
      }
    }
    // Shared across every player's row for this game so their standings can
    // still be grouped together after room_id is cleared by room cleanup
    // (see 022_game_session_id.sql) - room_id alone doesn't survive that.
    const gameSessionId = crypto.randomUUID();
    for (const r of results) {
      const p = players[r.playerIndex];
      if (!p.is_ai && p.user_id) {
        const sorted = [...results].sort((a, b) => b.totalScore - a.totalScore);
        const placement = sorted.findIndex(s => s.playerIndex === r.playerIndex) + 1;
        const totals = totalsByPlayer.get(r.playerIndex) ?? { bid: r.bid, got: r.got, hit: r.bid === r.got ? 1 : 0, played: 1 };
        await supabase.from("game_stats").insert({
          room_id: roomId, game_session_id: gameSessionId, user_id: p.user_id, placement,
          final_score: r.totalScore, total_rounds: room.max_rounds,
          tricks_bid: totals.bid,
          tricks_won: totals.got,
          rounds_hit: totals.hit,
          rounds_played: totals.played,
        });
      }
    }
  } else {
    await supabase.from("rooms").update({ phase: "roundEnd", log: room.log }).eq("id", roomId);
  }
}

async function advanceTrick(supabase, roomId, room, players) {
  // Always reload fresh players to avoid stale hand data from previous rounds
  if (!players) {
    const { data: freshP } = await supabase.from("room_players").select("*").eq("room_id", roomId).order("player_index");
    players = freshP ?? [];
  }
  const trick = room.current_trick;

  if (trick.length < players.length) {
    const next = (room.current_player + 1) % players.length;
    // Atomic guard: only advance if current_player is still the value this
    // call expects. A duplicate playCard request (double-tap, client
    // network retry, multi-tab) that already advanced the turn through a
    // concurrent call loses this race and returns without appending a
    // second entry to current_trick - the actual corruption case that
    // motivated this guard.
    const { data: advanceClaim } = await supabase.from("rooms")
      .update({ current_trick: trick, current_player: next, log: room.log })
      .eq("id", roomId)
      .eq("current_player", room.current_player)
      .select("id");
    if (!advanceClaim || advanceClaim.length === 0) {
      return json({ ok: true }); // lost the race - already advanced by another call
    }
    if (players[next]?.is_ai) {
      scheduleAITurn(supabase, roomId); // server drives the next AI move
      return json({ ok: true });
    }
    await notifyPlayerTurn(supabase, roomId, next);
    return json({ ok: true });
  }

  // Explicitly save current trick state so realtime fires
  await supabase.from("rooms").update({ current_trick: trick, current_player: room.current_player }).eq("id", roomId);

  // Trick complete
  let trumpCardValue = room.werewolf_suit
    ? (room.original_trump_card?.value ?? 0)
    : (room.trump_card?.value ?? 0);

  // Special case: Vampir im Stich + Werwolf als aktiver Trumpf
  // → Karte unter dem Werwolf aufdecken; die neue Trumpffarbe gilt NUR FÜR DIESEN STICH.
  // Danach bleibt der Werwolf-Suit als Trumpf aktiv (werewolf_suit unverändert in DB).
  // Reveal itself already happened (and was logged) the moment the Vampire was
  // played - see revealCardUnderWerewolf() - so it's picked up from
  // room.original_trump_card here instead of being looked up/logged/popped again.
  const vampireInTrick = trick.some(t => t.card.specialType === "vampire");
  let trickTrumpSuit = room.trump_suit;
  let trickWerewolfSuit = room.werewolf_suit;
  let trickTrumpCard = room.trump_card;
  if (vampireInTrick && room.werewolf_suit) {
    const cardUnder = room.original_trump_card ?? null;
    if (cardUnder) {
      if (cardUnder.type === "number") {
        trickTrumpSuit = cardUnder.suit;
        trickWerewolfSuit = null;
        trickTrumpCard = cardUnder;
        trumpCardValue = cardUnder.value;
        addLog(room, `Trumpf für diesen Stich: ${suitDot(trickTrumpSuit)}`);
      } else if (cardUnder.type === "fool") {
        trickTrumpSuit = null;
        trickWerewolfSuit = null;
        trickTrumpCard = cardUnder;
        addLog(room, `Kein Trumpf in diesem Stich (Narr)`);
      } else if (cardUnder.type === "wizard" || cardUnder.specialType === "wizardfool") {
        trickTrumpSuit = SUITS[Math.floor(Math.random() * 4)];
        trickWerewolfSuit = null;
        trickTrumpCard = cardUnder;
        addLog(room, `Zauberer: Trumpf für diesen Stich ${suitDot(trickTrumpSuit)}`);
      } else if (cardUnder.specialType) {
        // Sonderkarte aufgedeckt → Vampir kopiert ALLE ihre Effekte (offiz. FAQ)
        // Die Vampir-Karte im Stich wird zur kopierten Sonderkarte, sodass
        // Drache/Fee/Bombe die Stichwertung und Hexe/Jongleur/Wolke die
        // Nach-Stich-Effekte automatisch auslösen.
        const vIdx = trick.findIndex(t => t.card.specialType === "vampire");
        if (vIdx >= 0) {
          trick[vIdx] = { ...trick[vIdx], card: { ...trick[vIdx].card, specialType: cardUnder.specialType, copiedByVampire: true } };
          addLog(room, `🧛 Vampir wirkt als ${cardLabel(cardUnder)}`);
        }
        // Trumpf-Semantik der kopierten Karte: Hexe/Jongleur → kein Trumpf in diesem Stich
        if (cardUnder.specialType === "witch" || cardUnder.specialType === "rainbow7") {
          trickTrumpSuit = null;
          trickWerewolfSuit = null;
        } else if (cardUnder.specialType === "rainbow9") {
          trickTrumpSuit = SUITS[Math.floor(Math.random() * 4)];
          trickWerewolfSuit = null;
          addLog(room, `Wolke: Trumpf für diesen Stich ${suitDot(trickTrumpSuit)}`);
        }
        // Drache/Fee/Bombe: Werwolf-Suit bleibt, Karte wirkt über specialType
      }
      await upd(supabase.from("rooms").update({ log: room.log }).eq("id", roomId), "log.vampire");
    }
    dbg("[vampire+werewolf] trick-only trump:", trickTrumpSuit, "werewolf_suit stays:", room.werewolf_suit);
  }

  const winnerIdx = trickWinner(trick, trickTrumpSuit, trickWerewolfSuit, trumpCardValue, trickTrumpCard);

  if (winnerIdx === -1) {
    // Check if it was a bomb or all-fools
    const hasBomb = trick.some(t => t.card.specialType === "bomb");
    const nextLeader = hasBomb
      ? trickWinnerWithoutBomb(trick, trickTrumpSuit, trickWerewolfSuit, trumpCardValue, trickTrumpCard)
      : trick[0].playerIndex; // all fools: first player leads next
    const msg = hasBomb ? "💥 Elderstab! Stich annulliert." : "🃏 Nur Narren – kein Stich!";
    addLog(room, msg);

    // Even with a bomb, Jongleur (7½) and Hexe still trigger (official FAQ)
    const bombHas7 = hasBomb && trick.some(t => t.card.specialType === "rainbow7");
    const bombHasWitch = hasBomb && trick.some(t => t.card.id === "witch" || t.card.specialType === "witch");
    // Bombed tricks never add to tricks_won, so comparing totalTricks to room.round
    // doesn't track physical tricks played when multiple bombs void tricks in the
    // same round - checking hand emptiness directly (like isLastTrick below) is robust
    // regardless of how many prior tricks were voided.
    const bombIsLastTrick = players.every(p => (p.hand ?? []).length === 0);

    const bombRainbow7Players = (bombHas7 && !bombIsLastTrick) ? players.map((_, i) => i) : null;
    const bombWitchPlayerIdx = trick.find(t => t.card.id === "witch" || t.card.specialType === "witch")?.playerIndex ?? null;
    const bombWitchHand = bombWitchPlayerIdx !== null ? players[bombWitchPlayerIdx]?.hand ?? [] : [];
    const bombPendingWitch = (bombHasWitch && !bombIsLastTrick && bombWitchHand.length > 0)
      ? bombWitchPlayerIdx
      : null;

    // Same atomic guard as the non-bomb winnerIdx branch: only resolve if
    // current_player is still what this call expects, so a duplicate
    // playCard request for the trick-completing (bombed) card can't
    // resolve the same trick twice.
    const { data: bombTrickClaim } = await supabase.from("rooms").update({
      current_trick: [], current_player: nextLeader,
      last_trick_winner: null, last_trick_cards: trick,
      phase: "trickEnd",
      pending_rainbow7: bombRainbow7Players,
      pending_witch: bombPendingWitch,
      pending_rainbow9: null, pending_rainbow9_deferred: null,
      log: room.log
    }).eq("id", roomId).eq("current_player", room.current_player).select("id");
    if (!bombTrickClaim || bombTrickClaim.length === 0) {
      return json({ ok: true }); // lost the race - already resolved by another call
    }
    if (bombRainbow7Players) {
      for (const idx of bombRainbow7Players) if (!players[idx]?.is_ai) await notifyRainbow7Pass(supabase, roomId, idx);
    }

    // If the witch player is an AI, auto-swap immediately
    if (bombPendingWitch !== null && players[bombPendingWitch]?.is_ai) {
      const witchAI = players[bombPendingWitch];
      const swappableTrick = trick.filter(t => t.card.specialType !== "witch" && t.card.id !== "witch");
      if (swappableTrick.length > 0 && witchAI.hand.length > 0) {
        // Pick the strongest trick card to take, give away the weakest hand card
        const takenEntry = swappableTrick.reduce((best, t) =>
          (t.card.value ?? 0) > (best.card.value ?? 0) ? t : best, swappableTrick[0]);
        const takenCard = takenEntry.card;
        const givenCard = witchAI.hand.reduce((worst, c) =>
          (c.value ?? 0) < (worst.value ?? 0) ? c : worst, witchAI.hand[0]);
        const newHand = witchAI.hand.filter(c => c.id !== givenCard.id);
        newHand.push(takenCard);
        await supabase.from("room_players").update({ hand: newHand }).eq("id", witchAI.id);
        addLog(room, `🧹 ${witchAI.ai_name} tauscht: gibt ${cardLabel(givenCard)} · nimmt ${cardLabel(takenCard)}`);
        await supabase.from("rooms").update({
          pending_witch: null,
          phase: "witchReveal",
          witch_swap: { playerName: witchAI.ai_name, gave: givenCard, took: takenCard },
          log: room.log
        }).eq("id", roomId);
        scheduleWitchRevealDone(supabase, roomId);
      } else {
        await supabase.from("rooms").update({ pending_witch: null }).eq("id", roomId);
      }
    } else if (bombPendingWitch !== null) {
      await notifyWitchSwap(supabase, roomId, bombPendingWitch);
    }

    return json({ ok: true });
  }

  // Atomic guard: claim exclusive rights to resolve this trick before
  // touching any player state. A duplicate playCard request for the trick-
  // completing card (double-tap, network retry, multi-tab) that loses this
  // race returns immediately below, instead of double-incrementing
  // tricks_won or double-writing current_trick/current_player.
  //
  // current_trick/last_trick_winner/last_trick_cards are written together
  // with phase right here, not split into a later "full update" - winnerIdx
  // and the completed trick are both already known at this point, nothing
  // about them depends on the tricks_won/isLastTrick lookups below. Writing
  // phase:"trickEnd" without them in the same statement (the previous
  // shape of this claim) left a real, guaranteed-to-happen gap where
  // realtime clients would see phase already flipped but last_trick_cards
  // still holding the *previous* trick - the client's
  // `phase==="trickEnd" ? (last_trick_cards ?? current_trick) : current_trick`
  // picks the stale-but-non-null last_trick_cards over the fresh
  // current_trick, so every single trick after the first in a round
  // visibly flashed the trick before it, until the later write caught up.
  // Only the pending_* follow-up fields (which genuinely need the fresh
  // DB read below) remain in the second write further down.
  const { data: trickClaim } = await supabase.from("rooms")
    .update({
      phase: "trickEnd", current_player: winnerIdx,
      current_trick: [], last_trick_winner: winnerIdx, last_trick_cards: trick,
    })
    .eq("id", roomId)
    .eq("current_player", room.current_player)
    .select("id");
  if (!trickClaim || trickClaim.length === 0) {
    return json({ ok: true }); // lost the race - already resolved by another call
  }

  // Load fresh tricks_won from DB to avoid stale local value from previous round
  const { data: freshWinner } = await supabase.from("room_players").select("tricks_won").eq("id", players[winnerIdx].id).single();
  const newTricksWon = (freshWinner?.tricks_won ?? 0) + 1;
  await supabase.from("room_players").update({ tricks_won: newTricksWon }).eq("id", players[winnerIdx].id);
  players[winnerIdx].tricks_won = newTricksWon;
  addLog(room, `✓ ${players[winnerIdx].ai_name} gewinnt den Stich!`);

  const has9 = trick.some(t => t.card.specialType === "rainbow9");
  const hasBomb = trick.some(t => t.card.specialType === "bomb");
  // Wolke + Bombe: Stichvorhersage ändert sich nicht (offiz. FAQ)
  const has9Active = has9 && !hasBomb;
  const has7 = trick.some(t => t.card.specialType === "rainbow7");
  const hasWitch = trick.some(t => t.card.id === "witch" || t.card.specialType === "witch");

  // Check if this is the last trick - if so, skip all pending actions.
  // Mirrors roundOver2's check in handleClearTrick: totalTricksAfter alone
  // undercounts once a bomb has voided a trick (nobody's tricks_won increases
  // for it), which would otherwise leave this the true last trick with
  // totalTricksAfter < room.round and incorrectly try to set up a card-pass/
  // witch-swap when no player has any cards left to give away.
  const totalTricksAfter = players.reduce((s, p) => s + (p.tricks_won ?? 0), 0);
  const allHandsEmptyNow = players.every(p => (p.hand ?? []).length === 0);
  const isLastTrick = allHandsEmptyNow || totalTricksAfter >= room.round;

  const rainbow7Players = (has7 && !isLastTrick) ? players.map((_, i) => i) : null;
  const witchPlayerIdx = trick.find(t => t.card.id === "witch" || t.card.specialType === "witch")?.playerIndex ?? null;
  const witchPlayerHand = witchPlayerIdx !== null ? players[witchPlayerIdx]?.hand ?? [] : [];
  const pendingWitch = (hasWitch && !isLastTrick && witchPlayerHand.length > 0)
    ? witchPlayerIdx
    : null;

  // Exclusivity, phase, and the trick display fields (current_trick/
  // last_trick_winner/last_trick_cards) were already written atomically in
  // the claim above - this only adds the pending_* follow-up fields, which
  // genuinely depend on the fresh tricks_won/isLastTrick computation above.
  await supabase.from("rooms").update({
    // If both Jongleur (7½) and Wolke (9¾) are in the trick,
    // Jongleur resolves first (official FAQ). Defer rainbow9 until after rainbow7 is done.
    // On the last trick there are no cards left to pass, so Jongleur's
    // effect never actually happens (rainbow7Players is null below too) -
    // Wolke must resolve immediately in that case instead of deferring to a
    // pass-completion event that can now never fire, which otherwise left
    // pending_rainbow9_deferred set forever with no way to clear it.
    pending_rainbow9: (has9Active && (!has7 || isLastTrick)) ? winnerIdx : null,
    pending_rainbow9_deferred: (has9Active && has7 && !isLastTrick) ? winnerIdx : null,
    pending_rainbow7: rainbow7Players,
    pending_witch: pendingWitch,
    log: room.log
  }).eq("id", roomId);
  scheduleClearTrick(supabase, roomId); // server clears the trick after display delay
  dbg("[advanceTrick] after trickEnd update, room.trump_suit:", room.trump_suit, "room.werewolf_suit:", room.werewolf_suit);
  if (rainbow7Players) {
    for (const idx of rainbow7Players) if (!players[idx]?.is_ai) await notifyRainbow7Pass(supabase, roomId, idx);
  }

  // If the witch player is an AI, auto-swap immediately
  if (pendingWitch !== null && players[pendingWitch]?.is_ai) {
    // Reload fresh player data to avoid stale hands from previous round
    const { data: freshWitchPlayers } = await supabase.from("room_players").select("*").eq("room_id", roomId).order("player_index");
    const witchAI = freshWitchPlayers?.[pendingWitch] ?? players[pendingWitch];
    const swappableTrick = trick.filter(t => t.card.specialType !== "witch" && t.card.id !== "witch");
    if (swappableTrick.length > 0 && witchAI.hand.length > 0) {
      const takenEntry = swappableTrick.reduce((best, t) =>
        (t.card.value ?? 0) > (best.card.value ?? 0) ? t : best, swappableTrick[0]);
      const takenCard = takenEntry.card;
      const givenCard = witchAI.hand.reduce((worst, c) =>
        (c.value ?? 0) < (worst.value ?? 0) ? c : worst, witchAI.hand[0]);
      const newHand = witchAI.hand.filter(c => c.id !== givenCard.id);
      newHand.push(takenCard);
      await supabase.from("room_players").update({ hand: newHand }).eq("id", witchAI.id);
      addLog(room, `🧹 ${witchAI.ai_name} tauscht: gibt ${cardLabel(givenCard)} · nimmt ${cardLabel(takenCard)}`);
      await supabase.from("rooms").update({
        pending_witch: null,
        phase: "witchReveal",
        witch_swap: { playerName: witchAI.ai_name, gave: givenCard, took: takenCard },
        log: room.log
      }).eq("id", roomId);
      scheduleWitchRevealDone(supabase, roomId);
    } else {
      await supabase.from("rooms").update({ pending_witch: null }).eq("id", roomId);
    }
  } else if (pendingWitch !== null) {
    await notifyWitchSwap(supabase, roomId, pendingWitch);
  }

  // Reload fresh room AND players to get correct state
  const { data: freshRoom2 } = await supabase.from("rooms").select("*").eq("id", roomId).single();
  const currentRound = freshRoom2?.round ?? room.round;
  const maxRounds = freshRoom2?.max_rounds ?? room.max_rounds;

  const { data: freshAfterTrick } = await supabase
    .from("room_players").select("*").eq("room_id", roomId).order("player_index");
  const updatedPlayers2 = freshAfterTrick ?? players;

  // Round ends when all hands are empty OR total tricks >= round number
  const totalTricksPlayed = updatedPlayers2.reduce((sum, p) => sum + (p.tricks_won ?? 0), 0);
  const allHandsEmpty = updatedPlayers2.every(p => (p.hand ?? []).length === 0);
  const roundOver = allHandsEmpty || totalTricksPlayed >= currentRound;
  dbg("[advanceTrick] totalTricksPlayed:", totalTricksPlayed, "currentRound:", currentRound, "allHandsEmpty:", allHandsEmpty, "roundOver:", roundOver);

  // If the 9¾ winner is an AI, resolve it automatically right away - but
  // only in the same cases pending_rainbow9 (not _deferred) was actually
  // set above, or this double-adjusts once passCard's deferred-resolution
  // block also runs for the same event.
  if (has9Active && (!has7 || isLastTrick) && updatedPlayers2[winnerIdx]?.is_ai) {
    const winnerPlayer = updatedPlayers2[winnerIdx];
    const tricksWon = winnerPlayer.tricks_won ?? 0;
    const currentBid = winnerPlayer.bid ?? 0;
    // If exactly on target, must go up; otherwise random direction (but never below 0)
    let adjust = 1;
    if (tricksWon !== currentBid) {
      adjust = (currentBid > 0 && Math.random() < 0.5) ? -1 : 1;
    }
    const newBid = Math.max(0, currentBid + adjust);
    await supabase.from("room_players").update({ bid: newBid }).eq("id", winnerPlayer.id);
    addLog(room, `${winnerPlayer.ai_name} ändert Vorhersage auf ${newBid}`);
    await supabase.from("rooms").update({ pending_rainbow9: null, log: room.log }).eq("id", roomId);
    updatedPlayers2[winnerIdx] = { ...winnerPlayer, bid: newBid };
  } else if (has9Active && (!has7 || isLastTrick) && !updatedPlayers2[winnerIdx]?.is_ai) {
    await notifyRainbow9Adjust(supabase, roomId, winnerIdx);
  }

  // Note: even if roundOver is true, we do NOT call endRound here.
  // We stay in "trickEnd" so the last trick remains visible for the same
  // duration as any other trick. The client's clearTrick (after its display
  // delay) will detect roundOver and call endRound at that point - unless
  // there's a pending human action (9¾/7½/Hexe), which must resolve first
  // (see rainbow9Adjust, passCard, witchRevealDone).

  return json({ ok: true });
}


async function dealRound(supabase, roomId, room, players) {
  const deck = shuffle(buildDeck(room.edition ?? "classic", room.round === 1));
  const hands = players.map(() => []);
  for (let i = 0; i < room.round; i++)
    for (let p = 0; p < players.length; p++)
      hands[p].push(deck.pop());

  const trumpCard = deck.pop() ?? null;
  const remainingDeck = [...deck];
  await upd(supabase.from("room_decks").upsert({ room_id: roomId, deck: remainingDeck }), "deck.deal");

  dbg("[dealRound] dealing", room.round, "cards to", players.length, "players, deck size:", deck.length + players.length * room.round + 1);
  // Atomic dealing via RPC (all hands in one transaction); per-row fallback if RPC missing.
  {
    const { error: dealRpcErr } = await supabase.rpc("deal_hands", {
      p_room_id: roomId,
      p_hands: players.map((p, i) => ({ playerIndex: p.player_index, hand: hands[i] })),
    });
    if (dealRpcErr) {
      console.error("[dealRound] RPC unavailable, falling back:", dealRpcErr.message);
      for (let i = 0; i < players.length; i++) {
        await upd(supabase.from("room_players").update({ hand: hands[i], bid: null, tricks_won: 0 }).eq("id", players[i].id), "deal.hand");
      }
    }
  }

  // Check if any player got werewolf in hand
  const dealtPlayers = players.map((p, i) => ({ ...p, hand: hands[i] }));
  const werewolfHolder = dealtPlayers.find(p => p.hand.some(c => c.specialType === "werewolf"));
  if (werewolfHolder && trumpCard?.specialType !== "werewolf" && trumpCard !== null) {
    const newHand = [...werewolfHolder.hand];
    const wi = newHand.findIndex(c => c.specialType === "werewolf");
    const werewolfCard = newHand[wi];
    newHand[wi] = trumpCard;
    await supabase.from("room_players").update({ hand: newHand, bid: null, tricks_won: 0 }).eq("id", werewolfHolder.id);
    addLog(room, `🐺 ${werewolfHolder.ai_name} hat den Werwolf – tauscht mit der Trumpfkarte!`);
    // Draw the card "under the werewolf" (next card from remaining deck) - vampire will copy this
    const cardUnderWerewolf = remainingDeck.length > 0 ? remainingDeck[remainingDeck.length - 1] : null;
    const wPhase = werewolfHolder.is_ai ? "bidding" : "choosingWerewolf";
    const wSuit = werewolfHolder.is_ai ? SUITS[Math.floor(Math.random() * 4)] : null;
    const wPlayer = werewolfHolder.is_ai ? (room.dealer + 1) % players.length : werewolfHolder.player_index;
    if (werewolfHolder.is_ai) addLog(room, `${werewolfHolder.ai_name} wählt Stichfarbe: ${suitDot(wSuit)}`);
    await supabase.from("rooms").update({
      round: room.round, max_rounds: room.max_rounds, dealer: room.dealer,
      trump_card: werewolfCard, trump_suit: null,
      original_trump_card: cardUnderWerewolf, // card under werewolf - vampire copies this
      phase: wPhase, current_player: wPlayer,
      werewolf_suit: wSuit,
      current_trick: [], last_trick_winner: null, last_trick_cards: null,
      pending_rainbow7: null, pending_rainbow9: null, pending_rainbow9_deferred: null, pending_witch: null, pending_vampire_reveal: null,
      log: room.log
    }).eq("id", roomId);
    if (wPhase === "bidding") {
      const updPlayers = dealtPlayers.map(p => p.player_index === werewolfHolder.player_index ? { ...p, hand: newHand } : p);
      return await tickAIBids(supabase, roomId, { ...room, phase: "bidding", current_player: wPlayer, werewolf_suit: wSuit }, updPlayers);
    }
    await notifyChooseWerewolf(supabase, roomId, wPlayer);
    return json({ ok: true });
  }

  const nextBidder = (room.dealer + 1) % players.length;
  let phase = "bidding";
  let currentPlayer = nextBidder;
  let trumpSuit = trumpCard?.suit ?? null;

  if (trumpCard?.type === "wizard" || trumpCard?.specialType === "wizardfool") {
    phase = "choosingTrump";
    currentPlayer = room.dealer;
    const label = trumpCard?.specialType === "wizardfool" ? "Zauberernarr (als Zauberer)" : "Zauberer";
    addLog(room, `Runde ${room.round} – ${label}: Dealer wählt Trumpf`);
    if (players[room.dealer].is_ai) {
      trumpSuit = SUITS[Math.floor(Math.random() * 4)];
      phase = "bidding";
      currentPlayer = nextBidder;
      addLog(room, `${players[room.dealer].ai_name} wählt Trumpf: ${suitDot(trumpSuit)}`);
    }
  } else if (trumpCard?.specialType === "werewolf") {
    phase = "choosingWerewolf";
    currentPlayer = room.dealer;
    addLog(room, `Runde ${room.round} – Werwolf: Dealer wählt Stichfarbe`);
    // Card under the werewolf = next card from remaining deck (for vampire to copy)
    const cardUnderWerwolf2 = remainingDeck.length > 0 ? remainingDeck[remainingDeck.length - 1] : null;
    if (players[room.dealer].is_ai) {
      const suit = SUITS[Math.floor(Math.random() * 4)];
      await supabase.from("rooms").update({
        round: room.round, max_rounds: room.max_rounds, dealer: room.dealer,
        trump_card: trumpCard, trump_suit: null, werewolf_suit: suit,
        original_trump_card: cardUnderWerwolf2,
        phase: "bidding", current_player: nextBidder,
        current_trick: [], last_trick_winner: null, last_trick_cards: null,
        pending_rainbow7: null, pending_rainbow9: null, pending_rainbow9_deferred: null, pending_witch: null, pending_vampire_reveal: null,
        log: room.log
      }).eq("id", roomId);
      return await tickAIBids(supabase, roomId, { ...room, phase: "bidding", current_player: nextBidder, werewolf_suit: suit }, dealtPlayers);
    }
  } else if (trumpCard?.specialType === "dragon") {
    // Offiz. FAQ: Drache als Trumpfkarte → Dealer bestimmt eine Trumpffarbe
    // (wie beim Zauberer). Zuvor fiel dies durch den generischen Fallback
    // fälschlich auf "kein Trumpf" (dragon.suit ist null), da kein eigener
    // Zweig existierte.
    phase = "choosingTrump";
    currentPlayer = room.dealer;
    addLog(room, `Runde ${room.round} – Drache als Trumpf: Dealer wählt Trumpffarbe`);
    if (players[room.dealer].is_ai) {
      trumpSuit = SUITS[Math.floor(Math.random() * 4)];
      phase = "bidding";
      currentPlayer = nextBidder;
      addLog(room, `${players[room.dealer].ai_name} wählt Trumpf: ${suitDot(trumpSuit)}`);
    }
  } else if (trumpCard?.specialType === "vampire") {
    // Offiz. FAQ: "Deckst du bei der Bestimmung der Trumpffarbe den Vampir auf,
    // bestimmst du eine Trumpffarbe." → Dealer wählt, wie beim Zauberer.
    phase = "choosingTrump";
    currentPlayer = room.dealer;
    addLog(room, `Runde ${room.round} – Vampir als Trumpf: Dealer wählt Trumpffarbe`);
    if (players[room.dealer].is_ai) {
      trumpSuit = SUITS[Math.floor(Math.random() * 4)];
      phase = "bidding";
      currentPlayer = nextBidder;
      addLog(room, `${players[room.dealer].ai_name} wählt Trumpf: ${suitDot(trumpSuit)}`);
    }
  } else if (trumpCard?.specialType === "witch") {
    // Hexe als Trumpfkarte → kein Trumpf (offiz. FAQ)
    addLog(room, `Runde ${room.round} – Hexe als Trumpf: Kein Trumpf`);
    // phase stays "bidding", trumpSuit stays null
  } else if (trumpCard?.specialType === "rainbow7") {
    // Jongleur als Trumpfkarte → Dealer wählt Trumpffarbe (offiz. FAQ - anders
    // als die Hexe, mit der er zuvor fälschlich zusammengefasst war)
    phase = "choosingTrump";
    currentPlayer = room.dealer;
    addLog(room, `Runde ${room.round} – Jongleur als Trumpf: Dealer wählt Trumpffarbe`);
    if (players[room.dealer].is_ai) {
      trumpSuit = SUITS[Math.floor(Math.random() * 4)];
      phase = "bidding";
      currentPlayer = nextBidder;
      addLog(room, `${players[room.dealer].ai_name} wählt Trumpf: ${suitDot(trumpSuit)}`);
    }
  } else if (trumpCard?.specialType === "rainbow9") {
    // Wolke als Trumpfkarte → Dealer wählt Trumpffarbe (offiz. FAQ)
    phase = "choosingTrump";
    currentPlayer = room.dealer;
    addLog(room, `Runde ${room.round} – Wolke als Trumpf: Dealer wählt Trumpffarbe`);
    if (players[room.dealer].is_ai) {
      trumpSuit = SUITS[Math.floor(Math.random() * 4)];
      phase = "bidding";
      currentPlayer = nextBidder;
      addLog(room, `${players[room.dealer].ai_name} wählt Trumpf: ${suitDot(trumpSuit)}`);
    }
  } else {
    addLog(room, `Runde ${room.round} – Trumpf: ${trumpCard ? (trumpCard.type === "fool" ? "Kein Trumpf" : suitDot(trumpCard.suit)) : "–"}`);
  }

  await supabase.from("rooms").update({
    round: room.round, max_rounds: room.max_rounds, dealer: room.dealer,
    trump_card: trumpCard, trump_suit: trumpSuit,
    original_trump_card: null,
    phase, current_player: currentPlayer,
    current_trick: [], last_trick_winner: null, last_trick_cards: null,
    werewolf_suit: null, pending_rainbow7: null, pending_rainbow9: null, pending_rainbow9_deferred: null, pending_witch: null, pending_vampire_reveal: null,
    log: room.log
  }).eq("id", roomId);

  if (phase === "bidding") {
    return await tickAIBids(supabase, roomId, { ...room, phase, current_player: currentPlayer, trump_suit: trumpSuit, werewolf_suit: null }, dealtPlayers);
  }
  if (phase === "choosingTrump") await notifyChooseTrump(supabase, roomId, currentPlayer);
  if (phase === "choosingWerewolf") await notifyChooseWerewolf(supabase, roomId, currentPlayer);
  return json({ ok: true });
}

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: corsHeaders });

  const supabase = createClient(
    Deno.env.get("SUPABASE_URL"),
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")
  );

  const authHeader = req.headers.get("Authorization");
  if (!authHeader) return new Response("Unauthorized", { status: 401, headers: corsHeaders });

  const anonClient = createClient(
    Deno.env.get("SUPABASE_URL"),
    Deno.env.get("SUPABASE_ANON_KEY"),
    { global: { headers: { Authorization: authHeader } } }
  );
  const { data: { user }, error: authErr } = await anonClient.auth.getUser();
  if (authErr || !user) return new Response("Unauthorized", { status: 401, headers: corsHeaders });

  let body;
  try {
    body = await req.json();
  } catch(e) {
    return new Response("Invalid JSON", { status: 400, headers: corsHeaders });
  }
  const { action, roomId } = body;

  if (rateLimited(user.id)) return json({ error: "Zu viele Anfragen" }, 429);

  // createRoom/joinRoom/finishManualGame/sendFriendRequest don't operate on
  // an existing roomId (createRoom makes one, joinRoom resolves the room
  // from a room code, finishManualGame operates on a manual_games row,
  // sendFriendRequest doesn't touch a room at all) - skip the lookup.
  if (action === "createRoom" || action === "joinRoom" || action === "finishManualGame" || action === "sendFriendRequest") {
    switch (action) {
      case "sendFriendRequest": {
        // profiles.username is openly readable (needed for the game itself -
        // showing names at the table, etc.), so a client-side substring
        // search or any response here that differs based on whether the
        // username exists, is already a friend, or is the caller themself
        // would let anyone enumerate real accounts. Every outcome below
        // returns the exact same { ok: true } - only whether a row actually
        // got inserted differs, invisibly to the caller.
        const targetUsername = (body.username ?? "").toString().trim().slice(0, 32);
        if (!targetUsername) return json({ error: "Bitte einen Usernamen eingeben" }, 400);
        if (friendLookupLocked(user.id)) {
          return json({ error: "Zu viele erfolglose Anfragen - bitte kurz warten" }, 429);
        }
        const { data: target } = await supabase.from("profiles").select("id").ilike("username", targetUsername).maybeSingle();
        let sent = false;
        if (target && target.id !== user.id) {
          const { error: insErr } = await supabase.from("friends").insert({ requester_id: user.id, addressee_id: target.id, status: "pending" });
          sent = !insErr;
        }
        if (!sent) recordFriendLookupFailure(user.id);
        return json({ ok: true });
      }
      case "finishManualGame": {
        // Manual (paper-replacement) games are otherwise entirely client-
        // written (see 010_manual_games.sql) - RLS already restricts every
        // manual_* table to the host. This one step needs the service role
        // because game_stats' insert policy is service_role-only (same
        // protection online games get), so it's the one thing routed
        // through the edge function instead of a direct client write.
        const manualGameId = body.manualGameId;
        const { data: mg } = await supabase.from("manual_games").select("*").eq("id", manualGameId).maybeSingle();
        if (!mg) return json({ error: "Spiel nicht gefunden" }, 404);
        if (mg.host_id !== user.id) return json({ error: "Nur der Ersteller kann abschließen" }, 403);
        if (mg.finished_at) return json({ ok: true }); // already finished - idempotent

        const { data: mgPlayers } = await supabase.from("manual_game_players").select("*").eq("manual_game_id", manualGameId).order("player_index");
        const { data: mgRounds } = await supabase.from("manual_game_rounds").select("*").eq("manual_game_id", manualGameId).order("round");
        if (!mgPlayers || mgPlayers.length === 0) return json({ error: "Keine Spieler erfasst" }, 400);
        if (!mgRounds || mgRounds.length === 0) return json({ error: "Keine Runden erfasst" }, 400);

        const totals = mgPlayers.map(p => {
          let score = 0, bidSum = 0, gotSum = 0, hitSum = 0, playedSum = 0;
          for (const r of mgRounds) {
            const entry = (r.results ?? []).find((e: any) => e.playerIndex === p.player_index);
            if (entry) {
              score += entry.delta ?? 0; bidSum += entry.bid ?? 0; gotSum += entry.got ?? 0;
              playedSum += 1;
              if (entry.bid === entry.got) hitSum += 1;
            }
          }
          return { playerIndex: p.player_index, userId: p.user_id, score, bidSum, gotSum, hitSum, playedSum };
        });
        const sorted = [...totals].sort((a, b) => b.score - a.score);
        for (const t of totals) {
          if (!t.userId) continue; // guest, no account to attribute stats to
          const placement = sorted.findIndex(s => s.playerIndex === t.playerIndex) + 1;
          await upd(supabase.from("game_stats").insert({
            room_id: null, manual_game_id: manualGameId, user_id: t.userId, placement, final_score: t.score,
            total_rounds: mgRounds.length, tricks_bid: t.bidSum, tricks_won: t.gotSum,
            rounds_hit: t.hitSum, rounds_played: t.playedSum,
          }), "finishManualGame.stats");
        }
        await upd(supabase.from("manual_games").update({ finished_at: new Date().toISOString() }).eq("id", manualGameId), "finishManualGame.finish");
        return json({ ok: true });
      }
      case "createRoom": {
        const code = Array.from({ length: 5 }, () => "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"[Math.floor(Math.random() * 32)]).join("");
        const uname = (body.username ?? "Spieler").toString().slice(0, 24);
        const plannedTotal = Number(body.totalPlayers);
        const { data: newRoom, error: crErr } = await supabase.from("rooms")
          .insert({ code, host_id: user.id, phase: "lobby", round: 0, max_rounds: 0, dealer: 0, current_player: 0, log: [], edition: body.edition === "anniversary" ? "anniversary" : "classic", planned_total: Number.isInteger(plannedTotal) ? plannedTotal : null })
          .select("id, code").single();
        if (crErr || !newRoom) return json({ error: "Raum konnte nicht erstellt werden" }, 500);
        await upd(supabase.from("room_players").insert({ room_id: newRoom.id, user_id: user.id, player_index: 0, is_ai: false, ai_name: uname, hand: [], score: 0, tricks_won: 0, connected: true }), "createRoom.player");
        return json({ ok: true, roomId: newRoom.id, code: newRoom.code });
      }
      case "joinRoom": {
        const jcode = (body.code ?? "").toString().toUpperCase().slice(0, 8);
        const { data: jRoom } = await supabase.from("rooms").select("id, phase").eq("code", jcode).single();
        if (!jRoom) return json({ error: "Raum nicht gefunden" }, 404);
        const { data: existing } = await supabase.from("room_players").select("player_index, user_id").eq("room_id", jRoom.id);
        // Reconnect: an existing player must always be able to get back in,
        // even mid-game - only block genuinely NEW joins once the game has
        // started (checked below).
        if (existing?.some(p => p.user_id === user.id)) return json({ ok: true, roomId: jRoom.id });
        if (jRoom.phase !== "lobby") return json({ error: "Spiel läuft bereits" }, 400);
        if ((existing?.length ?? 0) >= 6) return json({ error: "Raum ist voll" }, 400);
        const uname2 = (body.username ?? "Spieler").toString().slice(0, 24);
        await upd(supabase.from("room_players").insert({ room_id: jRoom.id, user_id: user.id, player_index: existing?.length ?? 0, is_ai: false, ai_name: uname2, hand: [], score: 0, tricks_won: 0, connected: true }), "joinRoom.player");
        // Touch rooms so lobby clients get a realtime event and reload the player list
        await upd(supabase.from("rooms").update({ log: [`${uname2} ist beigetreten`] }).eq("id", jRoom.id), "joinRoom.touch");
        return json({ ok: true, roomId: jRoom.id });
      }
    }
  }

  const { data: roomRow } = await supabase.from("rooms").select("*").eq("id", roomId).single();
  if (!roomRow) return json({ error: "Raum nicht gefunden" }, 404);
  const room = roomRow;

  const { data: playerRows } = await supabase.from("room_players").select("*").eq("room_id", roomId).order("player_index");
  const players = playerRows ?? [];
  const callerPlayer = players.find(p => p.user_id === user.id);
  const callerIdx = callerPlayer?.player_index ?? -1;

  switch (action) {

    case "leaveRoom": {
      // Only meaningful pre-start: mid-game, player_index positions are load
      // -bearing for hands/dealer rotation/etc, so we don't remove a row
      // there - the player just navigates away client-side and can always
      // rejoin (joinRoom already lets an existing member back in at any
      // phase). A lobby they've actually walked away from should stop
      // showing up as "reconnect" though, so this cleans that case up
      // immediately instead of waiting on the inactivity reaper.
      if (callerIdx < 0) return json({ error: "Nicht in diesem Raum" }, 400);
      if (room.phase !== "lobby") {
        // Exception: if every other seat is AI, no other human's game state
        // depends on this player_index anymore, so there's nothing left to
        // protect by keeping the room around - let them dismiss it instead
        // of waiting on the inactivity reaper.
        const hasOtherHuman = players.some((p, i) => i !== callerIdx && !p.is_ai);
        if (hasOtherHuman) return json({ error: "Laufendes Spiel kann nicht so verlassen werden" }, 400);
        await upd(supabase.from("rooms").delete().eq("id", roomId), "leaveRoom.soloAiRoom");
        return json({ ok: true });
      }
      await upd(supabase.from("room_players").delete().eq("room_id", roomId).eq("user_id", user.id), "leaveRoom.player");
      const { data: remaining } = await supabase.from("room_players").select("id").eq("room_id", roomId);
      if (!remaining || remaining.length === 0) {
        await upd(supabase.from("rooms").delete().eq("id", roomId), "leaveRoom.emptyRoom");
      }
      return json({ ok: true });
    }

    case "spectateRoom": {
      // Re-validates server-side what the discovery UI (friends_active_rooms)
      // already filtered client-side - never trust the client to have
      // actually enforced "must have a friend in this room" itself.
      if (callerIdx >= 0) return json({ error: "Du bist bereits Spieler in diesem Raum" }, 400);
      const { data: friendRows } = await supabase.from("friends").select("requester_id, addressee_id")
        .eq("status", "accepted").or(`requester_id.eq.${user.id},addressee_id.eq.${user.id}`);
      const friendIds = new Set((friendRows ?? []).map(f => f.requester_id === user.id ? f.addressee_id : f.requester_id));
      const hasFriendInRoom = players.some(p => !p.is_ai && friendIds.has(p.user_id));
      if (!hasFriendInRoom) return json({ error: "Kein Freund in diesem Raum" }, 403);
      await upd(supabase.from("room_spectators").upsert({ room_id: roomId, user_id: user.id }, { onConflict: "room_id,user_id" }), "spectateRoom.insert");
      return json({ ok: true, roomId });
    }

    case "leaveSpectating": {
      await upd(supabase.from("room_spectators").delete().eq("room_id", roomId).eq("user_id", user.id), "leaveSpectating.delete");
      return json({ ok: true });
    }

    case "syncPresence": {
      // Reports which human players currently have this room open, driven by
      // the client's realtime presence channel. `room_players.connected` is
      // the persisted mirror of that - Postgres has no visibility into the
      // Realtime server's in-memory presence state on its own, so this is
      // what lets cleanup_stale_rooms() (006_room_presence_cleanup.sql)
      // tell "everyone left mid-game" apart from "someone's still thinking".
      if (callerIdx < 0) return json({ error: "Nicht in diesem Raum" }, 400);
      const present = new Set((Array.isArray(body.presentUserIds) ? body.presentUserIds : []).map(String));
      // Whoever is calling this is, by definition, present right now - forces
      // this regardless of what the client's presence snapshot says. Without
      // this, the very first "sync" event on a fresh channel subscription
      // fires before track() has run (empty presence state), and if that
      // request happens to land after the later, correct one, the caller
      // ends up marked disconnected in their own room.
      present.add(user.id);
      const humans = players.filter(p => !p.is_ai);
      await Promise.all(humans
        .filter(p => p.connected !== present.has(p.user_id))
        .map(p => upd(supabase.from("room_players").update({ connected: present.has(p.user_id) }).eq("id", p.id), "syncPresence.player")));
      return json({ ok: true });
    }

    case "getIceServers": {
      // Mints short-lived TURN credentials for the self-hosted coturn add-on
      // (the "TURN REST API" convention coturn's --use-auth-secret expects:
      // username = "<expiry-unix-ts>:<anything>", password = base64(HMAC-SHA1
      // (sharedSecret, username))). The long-lived secret never leaves the
      // server - only these expiring username/password pairs do.
      if (callerIdx < 0) {
        const { data: specRow } = await supabase.from("room_spectators").select("id").eq("room_id", roomId).eq("user_id", user.id).maybeSingle();
        if (!specRow) return json({ error: "Nicht in diesem Raum" }, 400);
      }
      const turnSecret = Deno.env.get("TURN_SHARED_SECRET");
      const turnHost = Deno.env.get("TURN_HOST");
      const iceServers: any[] = [{ urls: "stun:stun.l.google.com:19302" }];
      if (turnSecret && turnHost) {
        const ttlSeconds = 3600;
        const username = `${Math.floor(Date.now() / 1000) + ttlSeconds}:${user.id}`;
        const key = await crypto.subtle.importKey(
          "raw", new TextEncoder().encode(turnSecret), { name: "HMAC", hash: "SHA-1" }, false, ["sign"]
        );
        const sig = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(username));
        const credential = btoa(String.fromCharCode(...new Uint8Array(sig)));
        iceServers.push({
          urls: [`turn:${turnHost}:3478?transport=udp`, `turn:${turnHost}:3478?transport=tcp`],
          username, credential,
        });
      }
      return json({ iceServers });
    }

    case "clearTrick": return await handleClearTrick(supabase, roomId, room);

    case "witchRevealDone": return await handleWitchRevealDone(supabase, roomId, room);

    case "triggerAI": {
      // Reload fresh room state - the room loaded at handler start may be stale
      const { data: freshRoom2 } = await supabase.from("rooms").select("*").eq("id", roomId).single();
      const currentRoom = freshRoom2 ?? room;
      if (currentRoom.phase !== "playing") return json({ ok: true });
      const { data: freshP } = await supabase.from("room_players").select("*").eq("room_id", roomId).order("player_index");
      const fp = freshP ?? players;
      dbg("[triggerAI] current_player:", currentRoom.current_player, "is_ai:", fp[currentRoom.current_player]?.is_ai, "hand:", fp[currentRoom.current_player]?.hand?.length);
      if (!fp[currentRoom.current_player]?.is_ai) return json({ ok: true });
      if (!fp[currentRoom.current_player]?.hand?.length) {
        dbg("[triggerAI] hand already empty - concurrent call, skipping");
        return json({ ok: true });
      }
      return await aiPlayNext(supabase, roomId, { ...currentRoom, current_trick: currentRoom.current_trick ?? [] }, fp);
    }

    case "startGame": {
      if (callerIdx !== 0) return json({ error: "Nur der Host kann starten" }, 403);
      const aiCount = Number(body.aiCount ?? 0);
      if (!Number.isInteger(aiCount) || aiCount < 0) return json({ error: "Ungültige KI-Anzahl" }, 400);
      const aiInserts = [];
      for (let i = players.length; i < Math.min(6, players.length + aiCount); i++) {
        aiInserts.push({ room_id: roomId, player_index: i, is_ai: true, ai_name: `KI ${i - players.length + 1}`, hand: [], score: 0, tricks_won: 0, connected: true });
      }
      let insertedAI = [];
      if (aiInserts.length > 0) {
        const { data: aiData } = await supabase.from("room_players").insert(aiInserts).select();
        insertedAI = aiData ?? [];
        dbg("[startGame] inserted AI players:", insertedAI.length, insertedAI.map(p => p.id));
      }
      // Reload ALL players from DB to get correct IDs
      const { data: freshAllPlayers } = await supabase.from("room_players").select("*").eq("room_id", roomId).order("player_index");
      const allPlayers = freshAllPlayers ?? [...players, ...insertedAI];
      dbg("[startGame] allPlayers:", allPlayers.length, allPlayers.map(p => ({ id: p.id, name: p.ai_name })));
      const maxRounds = Math.floor(60 / allPlayers.length);
      const edition = body.edition ?? room.edition ?? "classic";
      addLog(room, `Spiel gestartet mit ${allPlayers.length} Spielern (${edition === "anniversary" ? "30 Jahre Edition" : "Classic"})`);
      await supabase.from("rooms").update({ max_rounds: maxRounds, round: 1, dealer: 0, edition, log: room.log }).eq("id", roomId);
      return await dealRound(supabase, roomId, { ...room, round: 1, max_rounds: maxRounds, dealer: 0, log: room.log }, allPlayers);
    }

    case "chooseTrump": {
      if (room.phase !== "choosingTrump") return json({ error: "Falscher Status" }, 400);
      if (room.current_player !== callerIdx) return json({ error: "Nicht dein Zug" }, 403);
      if (!SUITS.includes(body.suit)) return json({ error: "Ungültige Farbe" }, 400);
      addLog(room, `Trumpf gewählt: ${suitDot(body.suit)}`);
      const nextBidder = (room.dealer + 1) % players.length;
      await supabase.from("rooms").update({ trump_suit: body.suit, phase: "bidding", current_player: nextBidder, log: room.log }).eq("id", roomId);
      return await tickAIBids(supabase, roomId, { ...room, trump_suit: body.suit, phase: "bidding", current_player: nextBidder, log: room.log }, players);
    }

    case "chooseWerewolf": {
      if (room.phase !== "choosingWerewolf") return json({ error: "Falscher Status" }, 400);
      if (room.current_player !== callerIdx) return json({ error: "Nicht dein Zug" }, 403);
      if (!SUITS.includes(body.suit)) return json({ error: "Ungültige Farbe" }, 400);
      addLog(room, `🐺 Stichfarbe gewählt: ${suitDot(body.suit)}`);
      const nextBidder = (room.dealer + 1) % players.length;
      await supabase.from("rooms").update({ werewolf_suit: body.suit, phase: "bidding", current_player: nextBidder, log: room.log }).eq("id", roomId);
      return await tickAIBids(supabase, roomId, { ...room, werewolf_suit: body.suit, phase: "bidding", current_player: nextBidder, log: room.log }, players);
    }

    case "bid": {
      if (room.phase !== "bidding") return json({ error: "Falscher Status" }, 400);
      if (room.current_player !== callerIdx) return json({ error: "Nicht dein Zug" }, 403);
      const bid = Number(body.bid);
      if (!Number.isInteger(bid) || bid < 0 || bid > room.round) return json({ error: "Ungültiges Gebot" }, 400);
      const forbidden = forbiddenDealerBid(players.map(p => p.bid), room.dealer, room.round);
      if (room.dealer === callerIdx && forbidden !== null && bid === forbidden)
        return json({ error: `Stichzwang: ${forbidden} ist verboten!` }, 400);
      callerPlayer.bid = bid;
      await supabase.from("room_players").update({ bid }).eq("id", callerPlayer.id);
      addLog(room, `${callerPlayer.ai_name} bietet: ${bid}`);
      const bids = players.map((p, i) => i === callerIdx ? bid : p.bid);
      return await advanceBidder(supabase, roomId, room, players.map((p, i) => i === callerIdx ? { ...p, bid } : p), bids);
    }

    case "playCard": {
      if (room.phase !== "playing") return json({ error: "Falscher Status" }, 400);
      if (room.current_player !== callerIdx) return json({ error: "Nicht dein Zug" }, 403);
      const hand = callerPlayer.hand;
      const card = hand.find(c => c.id === body.cardId);
      if (!card) return json({ error: "Karte nicht gefunden" }, 400);
      // Ensure player has bid before playing
      if (callerPlayer.bid === null || callerPlayer.bid === undefined) {
        return json({ error: "Du musst erst bieten!" }, 400);
      }

      // Validate follow suit
      // The FIRST non-passive card in the trick establishes the led suit.
      // Fool is passive → if fool leads, the next number/rainbow card sets the suit.
      // Wizard leads → no suit at all (everyone free).
      const isPassiveCard = (c) => !c || c.type === "fool" ||
        ((c.specialType === "rainbow7" || c.specialType === "rainbow9") && !c.suit) ||
        (c.specialType === "vampire" && !(room.werewolf_suit ?? room.trump_suit)) ||
        ["witch","fairy","werewolf","wizardfool","bomb"].includes(c.specialType ?? "");
      const leadCard = room.current_trick.find(t => !isPassiveCard(t.card))?.card ?? null;
      const effectiveLedSuit = !leadCard ? null :
        leadCard.specialType === "vampire"
          ? (room.werewolf_suit ?? room.trump_suit)
          : (leadCard.suit ?? null);
      // Vampire is never forced as a follow-suit card (official FAQ rule)
      if (!isAlwaysPlayable(card) && effectiveLedSuit) {
        const canFollow = hand.some(c => c.suit === effectiveLedSuit && !isAlwaysPlayable(c));
        if (canFollow && card.suit !== effectiveLedSuit)
          return json({ error: `Du musst ${effectiveLedSuit} bekennen!` }, 400);
      }

      const isWitch = card.specialType === "witch";
      const isRainbowChoice = (card.specialType === "rainbow7" || card.specialType === "rainbow9") && body.suit;
      if (isRainbowChoice && !SUITS.includes(body.suit)) return json({ error: "Ungültige Farbe" }, 400);
      const newHand = hand.filter(c => c.id !== card.id);
      // Atomic guard: only remove the card if it's still actually in the DB
      // hand at write time - a duplicate playCard request for the same card
      // (double-tap, client network retry, multi-tab) finds it already gone
      // and bails out instead of playing it a second time.
      // supabase-js's .contains(column, value) only JSON.stringifies `value`
      // when it's a plain object or a string - for an Array it instead joins
      // elements with "," inside Postgres array-literal braces (correct for
      // native array columns like text[], but for a jsonb array of card
      // OBJECTS it calls the default Object.toString() on each element,
      // producing the literal string "[object Object]"). That made every
      // single call here send `hand=cs.{[object Object]}`, which Postgres
      // rejects with "invalid input syntax for type json" - passing an
      // already-serialized JSON string instead hits .contains()'s string
      // branch, which appends it verbatim and works correctly.
      const { data: handClaim, error: handClaimErr } = await supabase
        .from("room_players").update({ hand: newHand }).eq("id", callerPlayer.id)
        .contains("hand", JSON.stringify([{ id: card.id }])).select("id");
      if (handClaimErr) {
        // Used to log-and-continue into advanceTrick() below, which appended
        // the card to current_trick regardless - the card visibly played
        // (on the table, turn advanced) while the hand write silently never
        // happened, permanently leaving it stuck in the hand with no error
        // shown anywhere. Fail the whole action instead: better a visible
        // error the player can retry than state that's quietly wrong forever.
        console.error("[playCard] hand claim failed:", handClaimErr.message);
        return json({ error: `Karte konnte nicht gespielt werden: ${handClaimErr.message}` }, 500);
      } else if (!handClaim || handClaim.length === 0) {
        return json({ ok: true }); // lost the race - another request already played this card
      }
      const playedCard = isWitch ? { ...card, type: "fool" } : (isRainbowChoice ? { ...card, suit: body.suit } : card);
      const newTrick = [...room.current_trick, { card: playedCard, playerIndex: callerIdx }];
      addLog(room, `${callerPlayer.ai_name}: ${cardLabel(playedCard)}`);
      if (card.specialType === "vampire" && room.werewolf_suit) {
        await revealCardUnderWerewolf(supabase, roomId, room);
      }
      return await advanceTrick(supabase, roomId, { ...room, current_trick: newTrick, current_player: callerIdx, log: room.log }, null);
    }

    case "playSpecial": {
      const { specialAction: sa, cardId, suit, takeCardId, giveCardId, choice } = body;

      if (sa === "witch" && takeCardId && giveCardId) {
        if (room.pending_witch !== callerIdx) return json({ error: "Nicht dein Zug" }, 400);
        const lastTrick = room.last_trick_cards ?? [];
        const takenCard = lastTrick.find(t => t.card.id === takeCardId)?.card;
        if (!takenCard) return json({ error: "Karte nicht gefunden" }, 400);
        const givenCard = callerPlayer.hand.find(c => c.id === giveCardId);
        const newHand = callerPlayer.hand.filter(c => c.id !== giveCardId);
        newHand.push(takenCard);
        await upd(supabase.from("room_players").update({ hand: newHand }).eq("id", callerPlayer.id), "playCard.hand");
        addLog(room, `🧹 ${callerPlayer.ai_name} tauscht: gibt ${cardLabel(givenCard)} · nimmt ${cardLabel(takenCard)}`);
        // Store swap info for 4 seconds display
        await supabase.from("rooms").update({
          pending_witch: null,
          phase: "witchReveal",
          witch_swap: { playerName: callerPlayer.ai_name, gave: givenCard, took: takenCard },
          log: room.log
        }).eq("id", roomId);
        // Round-over check happens in witchRevealDone/scheduleWitchRevealDone,
        // once the swap result has actually been displayed.
        scheduleWitchRevealDone(supabase, roomId);
        return json({ ok: true });
      }

      if (sa === "wizardfool") {
        if (room.phase !== "playing") return json({ error: "Falscher Status" }, 400);
        if (room.current_player !== callerIdx) return json({ error: "Nicht dein Zug" }, 403);
        const card = callerPlayer.hand.find(c => c.id === cardId);
        if (!card) return json({ error: "Karte nicht gefunden" }, 400);
        const newHand = callerPlayer.hand.filter(c => c.id !== cardId);
        // Same atomic hand-claim guard as playCard - see comment there,
        // including why the filter value must be pre-stringified.
        const { data: wfHandClaim, error: wfHandClaimErr } = await supabase
          .from("room_players").update({ hand: newHand }).eq("id", callerPlayer.id)
          .contains("hand", JSON.stringify([{ id: card.id }])).select("id");
        if (wfHandClaimErr) {
          // Same reasoning as playCard's identical guard - fail loudly
          // instead of silently advancing the trick with a hand write that
          // never actually happened.
          console.error("[playSpecial:wizardfool] hand claim failed:", wfHandClaimErr.message);
          return json({ error: `Karte konnte nicht gespielt werden: ${wfHandClaimErr.message}` }, 500);
        } else if (!wfHandClaim || wfHandClaim.length === 0) {
          return json({ ok: true }); // lost the race - another request already played this card
        }
        const resolvedCard = { ...card, type: choice === "wizard" ? "wizard" : "fool" };
        const newTrick = [...room.current_trick, { card: resolvedCard, playerIndex: callerIdx }];
        addLog(room, `${callerPlayer.ai_name}: Ron als ${choice === "wizard" ? "Zauberer" : "Narr"}`);
        return await advanceTrick(supabase, roomId, { ...room, current_trick: newTrick, log: room.log }, null);
      }

      return json({ error: "Unbekannte Sonderaktion" }, 400);
    }

    case "passCard": {
      if (!Array.isArray(room.pending_rainbow7) || !room.pending_rainbow7.includes(callerIdx))
        return json({ error: "Nicht dein Zug" }, 400);
      const passedCard = callerPlayer.hand.find(c => c.id === body.cardId);
      if (!passedCard) return json({ error: "Karte nicht gefunden" }, 400);

      // Atomically remove callerIdx from pending_rainbow7 and record their card
      // in the buffer, inside a single DB-locked transaction (SELECT ... FOR
      // UPDATE in record_rainbow7_pass) instead of a JS read-modify-write.
      // Previously, two players' concurrent passCard calls each computed their
      // buffer/remaining-list write from the same stale in-memory snapshot -
      // whichever write landed second silently overwrote the first player's
      // already-committed pass, permanently losing a card from play.
      const { data: passResult, error: passRpcErr } = await supabase.rpc("record_rainbow7_pass", {
        p_room_id: roomId, p_player_idx: callerIdx, p_card: passedCard,
      });
      if (passRpcErr) {
        console.error("[passCard] RPC failed:", passRpcErr.message);
        return json({ error: "Fehler beim Weitergeben" }, 500);
      }
      if (!passResult) return json({ ok: true }); // lost the race, or a duplicate/retried request

      const newHand = callerPlayer.hand.filter(c => c.id !== body.cardId);
      await upd(supabase.from("room_players").update({ hand: newHand }).eq("id", callerPlayer.id), "passCard.hand");
      addLog(room, `${callerPlayer.ai_name} hat eine Karte gewählt`);
      await upd(supabase.from("rooms").update({ log: room.log }).eq("id", roomId), "passCard.log");

      let remaining = passResult.pending;
      let buffer = passResult.buffer;
      // Reload fresh players for AI auto-pass to avoid stale hand data
      const { data: freshPassPlayers } = await supabase.from("room_players").select("*").eq("room_id", roomId).order("player_index");
      const updPlayers = freshPassPlayers ?? players;
      for (const aiIdx of [...remaining]) {
        const aiPlayer = updPlayers.find(p => p.player_index === aiIdx);
        if (aiPlayer?.is_ai && aiPlayer.hand.length > 0) {
          const aiCard = aiWorstCard(aiPlayer.hand, room.trump_suit, room.werewolf_suit);
          // Same atomic pass-recording as the human branch above - if a
          // concurrent request already passed for this AI (e.g. two human
          // passCard calls both driving the same trailing AI), this RPC call
          // returns null and the AI's card is left untouched.
          const { data: aiPassResult, error: aiPassErr } = await supabase.rpc("record_rainbow7_pass", {
            p_room_id: roomId, p_player_idx: aiIdx, p_card: aiCard,
          });
          if (aiPassErr || !aiPassResult) continue;
          const aiNewHand = aiPlayer.hand.filter(c => c.id !== aiCard.id);
          await upd(supabase.from("room_players").update({ hand: aiNewHand }).eq("id", aiPlayer.id), "passCard.aiHand");
          buffer = aiPassResult.buffer;
          remaining = aiPassResult.pending;
        }
      }
      if (remaining.length === 0) {
        // Atomic guard: only one concurrent passCard call may run the final
        // card distribution - same optimistic-lock idiom as handleClearTrick's
        // roundOver2 branch (flip a field, check how many rows it affected).
        const { data: finalizeLockRows } = await supabase.from("rooms")
          .update({ pending_rainbow7_buffer: null })
          .eq("id", roomId)
          .not("pending_rainbow7_buffer", "is", null)
          .select("id");
        if (!finalizeLockRows || finalizeLockRows.length === 0) return json({ ok: true }); // already finalized by another call

        const { data: finalPlayers } = await supabase.from("room_players").select("*").eq("room_id", roomId).order("player_index");
        for (const [fromIdxStr, card] of Object.entries(buffer)) {
          const fromIdx = parseInt(fromIdxStr);
          const leftIdx = (fromIdx + 1) % finalPlayers.length;
          const leftPlayer = finalPlayers.find(p => p.player_index === leftIdx);
          if (leftPlayer) await supabase.from("room_players").update({ hand: [...leftPlayer.hand, card] }).eq("id", leftPlayer.id);
        }
        addLog(room, "🎁 Alle haben eine Karte weitergegeben!");
        // After Jongleur resolves, activate deferred Wolke (9¾) if present
        const deferredRainbow9 = room.pending_rainbow9_deferred ?? null;
        await supabase.from("rooms").update({
          pending_rainbow7: null,
          pending_rainbow7_buffer: null,
          pending_rainbow9_deferred: null,
          pending_rainbow9: deferredRainbow9,
          phase: deferredRainbow9 !== null ? "trickEnd" : "playing",
          log: room.log
        }).eq("id", roomId);
        // If deferred rainbow9 is for an AI, auto-resolve it; otherwise the
        // human's rainbow9Adjust turn only actually begins now (after every
        // Jongleur pass has completed), so that's when they get notified.
        if (deferredRainbow9 !== null) {
          const { data: r9Players2 } = await supabase.from("room_players").select("*").eq("room_id", roomId).order("player_index");
          const r9Room2 = { ...room, pending_rainbow9: deferredRainbow9, pending_rainbow9_deferred: null };
          if (r9Players2 && r9Players2[deferredRainbow9]?.is_ai) {
            const wp = r9Players2[deferredRainbow9];
            const adj = (wp.tricks_won ?? 0) !== (wp.bid ?? 0) && (wp.bid ?? 0) > 0 && Math.random() < 0.5 ? -1 : 1;
            const newBid = Math.max(0, (wp.bid ?? 0) + adj);
            await supabase.from("room_players").update({ bid: newBid }).eq("id", wp.id);
            addLog(room, `${wp.ai_name} ändert Vorhersage auf ${newBid}`);
            await supabase.from("rooms").update({ pending_rainbow9: null, phase: "playing", log: room.log }).eq("id", roomId);
          } else {
            await notifyRainbow9Adjust(supabase, roomId, deferredRainbow9);
          }
        }
        // Check if round is over after card exchange
        const { data: afterPassPlayers } = await supabase.from("room_players").select("*").eq("room_id", roomId).order("player_index");
        const { data: afterPassRoom } = await supabase.from("rooms").select("*").eq("id", roomId).single();
        if (afterPassPlayers && afterPassRoom) {
          const totalT = afterPassPlayers.reduce((s, p) => s + (p.tricks_won ?? 0), 0);
          const allE = afterPassPlayers.every(p => (p.hand ?? []).length === 0);
          if (allE || totalT >= afterPassRoom.round) {
            await endRound(supabase, roomId, afterPassRoom, afterPassPlayers);
          }
        }
      }
      // No else branch needed here: record_rainbow7_pass already persisted
      // pending_rainbow7/pending_rainbow7_buffer atomically for every pass
      // recorded above - nothing stale left to (re-)write.
      return json({ ok: true });
    }

    case "rainbow9Adjust": {
      if (room.pending_rainbow9 !== callerIdx) return json({ error: "Nicht dein Zug" }, 400);
      const newBid = Math.max(0, (callerPlayer.bid ?? 0) + (body.adjust ?? 1));
      await supabase.from("room_players").update({ bid: newBid }).eq("id", callerPlayer.id);
      addLog(room, `${callerPlayer.ai_name} ändert Vorhersage auf ${newBid}`);
      await supabase.from("rooms").update({ pending_rainbow9: null, log: room.log }).eq("id", roomId);

      // Check if round is over after the prediction adjustment
      const { data: r9Players } = await supabase.from("room_players").select("*").eq("room_id", roomId).order("player_index");
      const { data: r9Room } = await supabase.from("rooms").select("*").eq("id", roomId).single();
      if (r9Players && r9Room) {
        const totalT9 = r9Players.reduce((s, p) => s + (p.tricks_won ?? 0), 0);
        const allE9 = r9Players.every(p => (p.hand ?? []).length === 0);
        if (allE9 || totalT9 >= r9Room.round) {
          await endRound(supabase, roomId, r9Room, r9Players);
          return json({ ok: true });
        }
      }

      await supabase.from("rooms").update({ phase: "playing" }).eq("id", roomId);
      return json({ ok: true });
    }

    case "nextRound": {
      if (room.phase !== "roundEnd") return json({ error: "Falscher Status" }, 400);
      if (room.host_id !== user.id) return json({ error: "Nur der Host" }, 403);
      // Reload fresh room AND players from DB for accurate state
      const { data: freshNextRoom } = await supabase.from("rooms").select("*").eq("id", roomId).single();
      const { data: freshNextPlayers } = await supabase.from("room_players").select("*").eq("room_id", roomId).order("player_index");
      const nextPlayers = freshNextPlayers ?? players;
      const currentDealer = freshNextRoom?.dealer ?? room.dealer;
      const nextDealer = (currentDealer + 1) % nextPlayers.length;
      const nextRound = (freshNextRoom?.round ?? room.round) + 1;
      addLog(room, `Runde ${nextRound} beginnt`);
      return await dealRound(supabase, roomId, { ...room, ...freshNextRoom, round: nextRound, dealer: nextDealer, log: room.log }, nextPlayers);
    }

    case "newGame": {
      if (callerIdx !== 0) return json({ error: "Nur der Host" }, 403);
      for (const p of players) await supabase.from("room_players").update({ score: 0, bid: null, tricks_won: 0, hand: [] }).eq("id", p.id);
      await supabase.from("round_history").delete().eq("room_id", roomId);
      addLog(room, "Neues Spiel gestartet");
      return await dealRound(supabase, roomId, { ...room, round: 1, dealer: 0, log: room.log }, players.map(p => ({ ...p, score: 0, bid: null, tricks_won: 0 })));
    }

    default:
      return json({ error: "Unbekannte Aktion" }, 400);
  }
});
