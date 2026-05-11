// Player-to-player trade RPCs. v1 supports both one-off offers and
// recurring agreements; v2's first cut handles one-offs only —
// agreements add an interval_minutes param + cancel UX that we can
// layer on later.
import { sb } from './supabase.js';

export async function proposeTrade(params) {
  const { data, error } = await sb.rpc('propose_trade', {
    p_to_player_id: params.toPlayerId,
    p_give_money: params.giveMoney || 0,
    p_give_resources: params.giveResources || [],
    p_receive_money: params.receiveMoney || 0,
    p_receive_resources: params.receiveResources || [],
    p_message: params.message || null
  });
  if (error) throw error;
  return data;
}

export async function proposeTradeAgreement(params) {
  const { data, error } = await sb.rpc('propose_trade_agreement', {
    p_to_player_id: params.toPlayerId,
    p_give_money: params.giveMoney || 0,
    p_give_resources: params.giveResources || [],
    p_receive_money: params.receiveMoney || 0,
    p_receive_resources: params.receiveResources || [],
    p_interval_minutes: params.intervalMinutes,
    p_message: params.message || null
  });
  if (error) throw error;
  return data;
}

export async function acceptTradeAgreement(agreementId) {
  const { data, error } = await sb.rpc('accept_trade_agreement', { p_agreement_id: agreementId });
  if (error) throw error;
  return data;
}

export async function cancelTradeAgreement(agreementId) {
  const { data, error } = await sb.rpc('cancel_trade_agreement', { p_agreement_id: agreementId });
  if (error) throw error;
  return data;
}

export async function listTradeAgreements() {
  const { data, error } = await sb.rpc('list_trade_agreements');
  if (error) throw error;
  return data || [];
}

export async function acceptTrade(offerId) {
  const { data, error } = await sb.rpc('accept_trade', { p_offer_id: offerId });
  if (error) throw error;
  return data;
}

export async function rejectTrade(offerId) {
  const { data, error } = await sb.rpc('reject_trade', { p_offer_id: offerId });
  if (error) throw error;
  return data;
}

export async function cancelTrade(offerId) {
  const { data, error } = await sb.rpc('cancel_trade', { p_offer_id: offerId });
  if (error) throw error;
  return data;
}

// Pulls every offer the current player is a party to (incoming +
// outgoing, pending only). RLS scopes by player_id already.
export async function listMyOffers() {
  const { data, error } = await sb
    .from('player_trade_offers')
    .select('*, from_player:player_profiles!from_player_id(display_name, color_hex), to_player:player_profiles!to_player_id(display_name, color_hex)')
    .eq('status', 'pending')
    .order('created_at', { ascending: false });
  if (error) throw error;
  return data || [];
}
