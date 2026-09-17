-- Track the current leader's display name alongside leader_id, kept in sync on
-- every accepted bid. Once an auction ends this is simply "who won" — and
-- having it on the auctions row means listing pages can show it without an
-- extra join or a per-card bids fetch.
--
-- Idempotent: safe to re-run. Requires 0003_feature_expansion.sql to have run
-- first (it depends on columns that migration adds).

ALTER TABLE public.auctions ADD COLUMN IF NOT EXISTS leader_name text;

-- Backfill for any auctions that already have bids.
UPDATE public.auctions a
SET leader_name = b.bidder_name
FROM public.bids b
WHERE b.auction_id = a.id AND b.seq = a.last_seq AND a.leader_id IS NOT NULL;

CREATE OR REPLACE FUNCTION public.place_bid(
  p_auction_id uuid,
  p_amount numeric,
  p_payment_ack boolean DEFAULT false,
  p_amount_inr numeric DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_auction public.auctions%ROWTYPE;
  v_user uuid := auth.uid();
  v_name text;
  v_min numeric;
  v_seq bigint;
BEGIN
  IF v_user IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_signed_in');
  END IF;

  SELECT * INTO v_auction FROM public.auctions WHERE id = p_auction_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_such_auction');
  END IF;

  IF v_auction.locked THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'auction_locked');
  END IF;

  IF v_auction.status NOT IN ('live', 'scheduled') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'auction_not_live');
  END IF;

  IF v_auction.status = 'scheduled' AND v_auction.starts_at IS NOT NULL AND v_auction.starts_at > now() THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_started');
  END IF;

  IF v_auction.ends_at IS NOT NULL AND v_auction.ends_at <= now() THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'auction_ended');
  END IF;

  IF v_auction.visibility = 'private' AND v_auction.owner_id <> v_user THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.auction_participants
      WHERE auction_id = p_auction_id AND user_id = v_user AND status = 'joined'
    ) THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'not_a_participant');
    END IF;
  END IF;

  v_min := CASE WHEN v_auction.bid_count = 0
                THEN v_auction.starting_price
                ELSE v_auction.current_price + v_auction.min_increment END;

  IF p_amount < v_min THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'too_low', 'min_required', v_min, 'current_price', v_auction.current_price);
  END IF;

  IF p_amount_inr IS NOT NULL AND p_amount_inr >= 1000000 AND NOT p_payment_ack THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'payment_ack_required');
  END IF;

  SELECT display_name INTO v_name FROM public.profiles WHERE id = v_user;
  v_seq := v_auction.last_seq + 1;

  INSERT INTO public.bids (auction_id, bidder_id, bidder_name, amount, seq, payment_ack, amount_inr)
  VALUES (p_auction_id, v_user, COALESCE(v_name, 'bidder'), p_amount, v_seq, p_payment_ack, p_amount_inr);

  UPDATE public.auctions
     SET current_price = p_amount,
         leader_id = v_user,
         leader_name = COALESCE(v_name, 'bidder'),
         last_seq = v_seq,
         bid_count = bid_count + 1
   WHERE id = p_auction_id;

  RETURN jsonb_build_object('ok', true, 'seq', v_seq, 'amount', p_amount, 'min_required', p_amount + v_auction.min_increment);
END;
$$;

NOTIFY pgrst, 'reload schema';
