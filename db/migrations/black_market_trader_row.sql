-- Bug: black_market_trade INSERTs into trade_transactions with
-- trader_key='black_market', but the traders table has no row for
-- 'black_market'. The trade_transactions_trader_key_fkey FK throws
-- on every black-market trade, so the entire feature was broken in
-- production. Discovered while writing test coverage on 2026-05-09.
--
-- Fix: add a row for the black market trader (is_active=false so it
-- never enters the regular partner list / catalog logic).
INSERT INTO public.traders (key, name, description, is_active,
                            visit_capacity, visit_interval_minutes,
                            display_order, base_request_qty,
                            soft_deadline_minutes)
VALUES ('black_market', 'Black Market',
        'Always-on emergency trade. Bad rates on every resource.',
        FALSE, 0, 0, 999, 0, 0)
ON CONFLICT (key) DO NOTHING;
