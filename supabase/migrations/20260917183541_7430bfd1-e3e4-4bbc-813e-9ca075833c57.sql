ALTER TABLE public.auctions
  ADD COLUMN IF NOT EXISTS visibility text NOT NULL DEFAULT 'public',
  ADD COLUMN IF NOT EXISTS participant_limit integer,
  ADD COLUMN IF NOT EXISTS item_count integer NOT NULL DEFAULT 1,
  ADD COLUMN IF NOT EXISTS locked boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS starts_at timestamptz,
  ADD COLUMN IF NOT EXISTS listing_currency text NOT NULL DEFAULT 'USD',
  ADD COLUMN IF NOT EXISTS payment_confirmed_at timestamptz,
  ADD COLUMN IF NOT EXISTS payment_confirmed_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS leader_name text;

DO $$ BEGIN
  ALTER TABLE public.auctions ADD CONSTRAINT auctions_visibility_check CHECK (visibility IN ('public','private'));
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  ALTER TABLE public.auctions ADD CONSTRAINT auctions_participant_limit_check CHECK (participant_limit IS NULL OR participant_limit > 0);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  ALTER TABLE public.auctions ADD CONSTRAINT auctions_item_count_check CHECK (item_count > 0);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  ALTER TABLE public.auctions ADD CONSTRAINT auctions_listing_currency_check CHECK (char_length(listing_currency) = 3);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

ALTER TABLE public.auctions DROP CONSTRAINT IF EXISTS auctions_status_check;
ALTER TABLE public.auctions
  ADD CONSTRAINT auctions_status_check CHECK (status IN ('draft','scheduled','live','ended'));

ALTER TABLE public.bids
  ADD COLUMN IF NOT EXISTS payment_ack boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS amount_inr numeric(14,2);

CREATE TABLE IF NOT EXISTS public.auction_participants (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  auction_id uuid NOT NULL REFERENCES public.auctions(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  status text NOT NULL DEFAULT 'invited' CHECK (status IN ('invited', 'joined')),
  invited_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  joined_at timestamptz,
  UNIQUE (auction_id, user_id)
);
GRANT SELECT, INSERT, UPDATE, DELETE ON public.auction_participants TO authenticated;
GRANT ALL ON public.auction_participants TO service_role;
ALTER TABLE public.auction_participants ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Owners manage participants" ON public.auction_participants;
CREATE POLICY "Owners manage participants" ON public.auction_participants
FOR ALL TO authenticated USING (
  EXISTS (SELECT 1 FROM public.auctions a WHERE a.id = auction_id AND a.owner_id = auth.uid())
) WITH CHECK (
  EXISTS (SELECT 1 FROM public.auctions a WHERE a.id = auction_id AND a.owner_id = auth.uid())
);
DROP POLICY IF EXISTS "Invitees can view own invite" ON public.auction_participants;
CREATE POLICY "Invitees can view own invite" ON public.auction_participants
FOR SELECT TO authenticated USING (auth.uid() = user_id);
DROP POLICY IF EXISTS "Invitees can accept own invite" ON public.auction_participants;
CREATE POLICY "Invitees can accept own invite" ON public.auction_participants
FOR UPDATE TO authenticated USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);

CREATE INDEX IF NOT EXISTS auction_participants_auction_idx ON public.auction_participants (auction_id, status);
ALTER TABLE public.auction_participants REPLICA IDENTITY FULL;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime' AND schemaname = 'public' AND tablename = 'auction_participants'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.auction_participants;
  END IF;
END $$;

DROP POLICY IF EXISTS "Live auctions are public" ON public.auctions;
DROP POLICY IF EXISTS "Public auctions are visible to everyone" ON public.auctions;
CREATE POLICY "Public auctions are visible to everyone" ON public.auctions
FOR SELECT USING (status <> 'draft' AND visibility = 'public');

DROP POLICY IF EXISTS "Participants can view their private auctions" ON public.auctions;
CREATE POLICY "Participants can view their private auctions" ON public.auctions
FOR SELECT TO authenticated USING (
  visibility = 'private' AND EXISTS (
    SELECT 1 FROM public.auction_participants p
    WHERE p.auction_id = id AND p.user_id = auth.uid() AND p.status = 'joined'
  )
);

CREATE OR REPLACE FUNCTION public.join_private_auction(p_auction_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_auction public.auctions%ROWTYPE;
  v_user uuid := auth.uid();
  v_joined_count integer;
BEGIN
  IF v_user IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_signed_in');
  END IF;

  SELECT * INTO v_auction FROM public.auctions WHERE id = p_auction_id FOR UPDATE;
  IF NOT FOUND OR v_auction.visibility <> 'private' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_such_private_auction');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.auction_participants WHERE auction_id = p_auction_id AND user_id = v_user) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_invited');
  END IF;

  SELECT count(*) INTO v_joined_count FROM public.auction_participants
    WHERE auction_id = p_auction_id AND status = 'joined';

  IF v_auction.participant_limit IS NOT NULL AND v_joined_count >= v_auction.participant_limit THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'participant_limit_reached');
  END IF;

  UPDATE public.auction_participants SET status = 'joined', joined_at = now()
    WHERE auction_id = p_auction_id AND user_id = v_user;
  RETURN jsonb_build_object('ok', true);
END;
$$;
GRANT EXECUTE ON FUNCTION public.join_private_auction(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.invite_to_auction(p_auction_id uuid, p_email text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_owner uuid;
  v_target uuid;
BEGIN
  SELECT owner_id INTO v_owner FROM public.auctions WHERE id = p_auction_id;
  IF v_owner IS NULL OR v_owner <> auth.uid() THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_owner');
  END IF;

  SELECT id INTO v_target FROM auth.users WHERE lower(email) = lower(p_email);
  IF v_target IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_such_user');
  END IF;

  INSERT INTO public.auction_participants (auction_id, user_id, invited_by)
  VALUES (p_auction_id, v_target, auth.uid())
  ON CONFLICT (auction_id, user_id) DO NOTHING;

  RETURN jsonb_build_object('ok', true);
END;
$$;
GRANT EXECUTE ON FUNCTION public.invite_to_auction(uuid, text) TO authenticated;

CREATE OR REPLACE FUNCTION public.sync_auction_start(p_auction_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE v_changed boolean := false;
BEGIN
  UPDATE public.auctions
  SET status = 'live'
  WHERE id = p_auction_id AND status = 'scheduled' AND starts_at IS NOT NULL AND starts_at <= now();
  GET DIAGNOSTICS v_changed = ROW_COUNT;
  RETURN v_changed;
END;
$$;
GRANT EXECUTE ON FUNCTION public.sync_auction_start(uuid) TO anon, authenticated, service_role;

DROP FUNCTION IF EXISTS public.place_bid(uuid, numeric);

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

REVOKE ALL ON FUNCTION public.place_bid(uuid, numeric, boolean, numeric) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.place_bid(uuid, numeric, boolean, numeric) TO authenticated;
GRANT EXECUTE ON FUNCTION public.place_bid(uuid, numeric, boolean, numeric) TO service_role;

CREATE OR REPLACE FUNCTION public.confirm_auction_payment(p_auction_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE v_owner uuid;
BEGIN
  SELECT owner_id INTO v_owner FROM public.auctions WHERE id = p_auction_id;
  IF v_owner IS NULL OR v_owner <> auth.uid() THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_owner');
  END IF;
  UPDATE public.auctions SET payment_confirmed_at = now(), payment_confirmed_by = auth.uid() WHERE id = p_auction_id;
  RETURN jsonb_build_object('ok', true);
END;
$$;
GRANT EXECUTE ON FUNCTION public.confirm_auction_payment(uuid) TO authenticated;

NOTIFY pgrst, 'reload schema';