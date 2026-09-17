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
      AND p.status IN ('invited', 'joined')
  )
$$;