-- ── Cash ledger completeness (2026-05-08 audit) ──
-- Audit finding: player_profiles.money does not reconcile with the
-- sum of cash_transactions for the same player. Drew: gap=$16923.
-- Jill: gap=$16916. Both gaps are ~$17k of NPC trade income earned
-- since their cities started.
--
-- Six functions update player_profiles.money but never INSERT into
-- cash_transactions. The biggest is _pp_resolve_trader_visits, which
-- runs every production tick — every auto-trade since the auto-trade
-- mechanic shipped is missing from the ledger.
--
-- This migration fixes the highest-impact path (auto-trade via
-- _pp_resolve_trader_visits) and reconciles the historical gap with
-- a one-time ledger_adjustment per player. The other untracked paths
-- (resolve_trader_visit / sell_to_trader / black_market_trade /
-- accept_trade / _pp_run_agreements) are lower-frequency and can be
-- patched separately; the auto-trader is the bleed.

-- Expand the source allowlist with the categories we'll use going
-- forward. ledger_adjustment is the one-time backfill source.
ALTER TABLE public.cash_transactions DROP CONSTRAINT cash_source_check;
ALTER TABLE public.cash_transactions ADD CONSTRAINT cash_source_check CHECK (
  source = ANY (ARRAY[
    'tax_revenue', 'build_cost', 'expansion_cost', 'starting_grant',
    'demolish_refund', 'upkeep',
    'npc_trade', 'p2p_trade', 'p2p_agreement', 'black_market',
    'ledger_adjustment'
  ])
);

-- _pp_resolve_trader_visits: log npc_trade per visit phase. Sell
-- earnings = positive, buy spending = negative. Both phases can fire
-- in one visit; one ledger row per phase, both tagged with the
-- trader and visit timestamp for reporting.
CREATE OR REPLACE FUNCTION public._pp_resolve_trader_visits(p_player_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER AS $function$
DECLARE
  v_trader record;
  v_last_visit timestamptz;
  v_interval interval;
  v_player_money integer;
  v_visit_at timestamptz;
  v_next_visit_at timestamptz;
  v_iterations integer;
  v_max_iterations constant integer := 50;
  v_sell record;
  v_buy record;
BEGIN
  IF NOT public.is_trade_unlocked(p_player_id) THEN RETURN; END IF;
  SELECT money INTO v_player_money FROM public.player_profiles WHERE id = p_player_id;

  FOR v_trader IN SELECT * FROM public.traders WHERE is_active LOOP
    IF NOT public._trader_is_unlocked(p_player_id, v_trader.key) THEN CONTINUE; END IF;
    v_interval := (v_trader.visit_interval_minutes::text || ' minutes')::interval;
    SELECT visited_at INTO v_last_visit
    FROM public.trader_visits
    WHERE player_id = p_player_id AND trader_key = v_trader.key
    ORDER BY visited_at DESC LIMIT 1;
    IF v_last_visit IS NULL THEN
      SELECT created_at INTO v_last_visit FROM public.player_profiles WHERE id = p_player_id;
    END IF;
    v_next_visit_at := v_last_visit + v_interval;
    v_iterations := 0;
    WHILE v_next_visit_at <= now() AND v_iterations < v_max_iterations LOOP
      v_iterations := v_iterations + 1;
      v_visit_at := v_next_visit_at;

      SELECT * INTO v_sell FROM public._rtv_sell_phase(p_player_id, v_trader.key, v_trader.visit_capacity);
      IF v_sell.earned > 0 THEN
        UPDATE public.player_profiles SET money = money + v_sell.earned WHERE id = p_player_id;
        v_player_money := v_player_money + v_sell.earned;
        INSERT INTO public.cash_transactions (player_id, source, amount, context)
          VALUES (p_player_id, 'npc_trade', v_sell.earned,
                  jsonb_build_object('trader', v_trader.key, 'direction', 'sell', 'visit_at', v_visit_at));
      END IF;

      SELECT * INTO v_buy FROM public._rtv_buy_phase(p_player_id, v_trader.key,
        v_trader.visit_capacity - v_sell.capacity_used, v_player_money);
      IF v_buy.spent > 0 THEN
        UPDATE public.player_profiles SET money = money - v_buy.spent WHERE id = p_player_id;
        v_player_money := v_buy.money_out;
        INSERT INTO public.cash_transactions (player_id, source, amount, context)
          VALUES (p_player_id, 'npc_trade', -v_buy.spent,
                  jsonb_build_object('trader', v_trader.key, 'direction', 'buy', 'visit_at', v_visit_at));
      END IF;

      INSERT INTO public.trader_visits
        (trader_key, player_id, capacity_total, capacity_used, summary, visited_at)
      VALUES (v_trader.key, p_player_id, v_trader.visit_capacity,
        v_sell.capacity_used + v_buy.capacity_used,
        v_sell.summary || v_buy.summary, v_visit_at);
      v_next_visit_at := v_visit_at + v_interval;
    END LOOP;
  END LOOP;
END;
$function$;

-- One-time ledger_adjustment per player so historical books balance
-- from this point forward. Without this, the ~$17k gap stays in the
-- ledger forever. Written as direct INSERT (not via UPDATE on money)
-- so we don't perturb the player's actual cash.
DO $$
DECLARE
  v_pp record;
  v_gap integer;
BEGIN
  FOR v_pp IN SELECT id, money FROM public.player_profiles LOOP
    SELECT v_pp.money - COALESCE((SELECT SUM(amount) FROM public.cash_transactions WHERE player_id = v_pp.id), 0)
    INTO v_gap;
    IF v_gap <> 0 THEN
      INSERT INTO public.cash_transactions (player_id, source, amount, context)
        VALUES (v_pp.id, 'ledger_adjustment', v_gap,
                jsonb_build_object('reason', 'reconcile pre-2026-05-08 untracked NPC trade and starter grant',
                                   'applied_at', now()));
    END IF;
  END LOOP;
END $$;
