REVOKE EXECUTE ON FUNCTION public.is_auction_participant(uuid, uuid) FROM anon;
REVOKE EXECUTE ON FUNCTION public.is_auction_owner(uuid, uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.is_auction_participant(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.is_auction_owner(uuid, uuid) TO authenticated;