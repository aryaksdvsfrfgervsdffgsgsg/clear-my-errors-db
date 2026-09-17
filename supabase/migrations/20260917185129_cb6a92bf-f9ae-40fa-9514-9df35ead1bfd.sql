CREATE OR REPLACE FUNCTION public.is_auction_participant(_auction_id uuid, _user_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.auction_participants p
    WHERE p.auction_id = _auction_id
      AND p.user_id = _user_id
      AND p.status = 'joined'
  )
$$;

DROP POLICY IF EXISTS "Participants can view their private auctions" ON public.auctions;

CREATE POLICY "Participants can view their private auctions"
ON public.auctions FOR SELECT TO authenticated
USING (visibility = 'private' AND public.is_auction_participant(id, auth.uid()));

CREATE OR REPLACE FUNCTION public.is_auction_owner(_auction_id uuid, _user_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.auctions a
    WHERE a.id = _auction_id AND a.owner_id = _user_id
  )
$$;

DROP POLICY IF EXISTS "Owners manage participants" ON public.auction_participants;

CREATE POLICY "Owners manage participants"
ON public.auction_participants FOR ALL TO authenticated
USING (public.is_auction_owner(auction_id, auth.uid()))
WITH CHECK (public.is_auction_owner(auction_id, auth.uid()));

DROP POLICY IF EXISTS "Owners can view auction history" ON public.auction_events;

CREATE POLICY "Owners can view auction history"
ON public.auction_events FOR SELECT TO authenticated
USING (public.is_auction_owner(auction_id, auth.uid()));