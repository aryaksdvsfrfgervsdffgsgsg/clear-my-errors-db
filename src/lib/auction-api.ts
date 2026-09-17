import { supabase } from "@/integrations/supabase/client";
import { formatMoney, toInrEstimate } from "@/lib/currency";

export type Auction = {
  id: string;
  owner_id: string;
  title: string;
  description: string;
  starting_price: number;
  min_increment: number;
  current_price: number;
  leader_id: string | null;
  leader_name: string | null;
  last_seq: number;
  bid_count: number;
  status: string;
  ends_at: string | null;
  created_at: string;
  visibility: "public" | "private";
  participant_limit: number | null;
  item_count: number;
  locked: boolean;
  starts_at: string | null;
  listing_currency: string;
  payment_confirmed_at: string | null;
  payment_confirmed_by: string | null;
};

export type Bid = {
  id: string;
  auction_id: string;
  bidder_id: string;
  bidder_name: string;
  amount: number;
  seq: number;
  created_at: string;
  payment_ack: boolean;
  amount_inr: number | null;
};

export type AuctionMessage = {
  id: string;
  auction_id: string;
  user_id: string;
  sender_name: string;
  content: string;
  created_at: string;
};

export type AuctionParticipant = {
  id: string;
  auction_id: string;
  user_id: string;
  status: "invited" | "joined";
  invited_by: string | null;
  created_at: string;
  joined_at: string | null;
};

export type BidResult =
  | { ok: true; seq: number; amount: number; min_required: number }
  | { ok: false; reason: string; min_required?: number; current_price?: number };

export type SimpleResult = { ok: true } | { ok: false; reason: string };

export type InvariantReport = {
  ok: boolean;
  accepted: number;
  max_seq: number;
  violations: string[];
};

/** ₹10L — bids at or above this INR-equivalent require the payer to acknowledge
 * they'll complete payment if they win. There's no payment gateway behind this;
 * the owner confirms payment manually afterward via confirmAuctionPayment(). */
export const PAYMENT_ACK_THRESHOLD_INR = 1_000_000;

export const money = (value: number, currency = "USD") => formatMoney(value, currency);

/** The public homepage feed: public, non-draft auctions only. Filtered
 * explicitly (not just left to RLS) so a signed-in owner never sees their own
 * private or draft auctions leak into the general public listing. */
export async function listAuctions(): Promise<Auction[]> {
  const { data, error } = await supabase
    .from("auctions")
    .select("*")
    .eq("visibility", "public")
    .neq("status", "draft")
    .order("created_at", { ascending: false });
  if (error) throw error;
  return (data ?? []) as Auction[];
}

export async function getAuction(id: string): Promise<Auction | null> {
  const { data, error } = await supabase.from("auctions").select("*").eq("id", id).maybeSingle();
  if (error) throw error;
  return (data as Auction) ?? null;
}

export async function listBids(auctionId: string, limit = 200): Promise<Bid[]> {
  const { data, error } = await supabase
    .from("bids")
    .select("*")
    .eq("auction_id", auctionId)
    .order("seq", { ascending: false })
    .limit(limit);
  if (error) throw error;
  return (data ?? []) as Bid[];
}

export async function listMessages(auctionId: string, limit = 100): Promise<AuctionMessage[]> {
  const { data, error } = await supabase
    .from("auction_messages")
    .select("*")
    .eq("auction_id", auctionId)
    .order("created_at", { ascending: true })
    .limit(limit);
  if (error) throw error;
  return (data ?? []) as AuctionMessage[];
}

export async function sendMessage(auctionId: string, userId: string, content: string) {
  const { data: profile } = await supabase
    .from("profiles")
    .select("display_name")
    .eq("id", userId)
    .maybeSingle();
  const { error } = await supabase.from("auction_messages").insert({
    auction_id: auctionId,
    user_id: userId,
    sender_name: profile?.display_name || "bidder",
    content: content.trim(),
  });
  if (error) throw error;
}

/**
 * Places a bid. `paymentAck` must be true when the bid's INR-equivalent value
 * is at or above ₹10L (see PAYMENT_ACK_THRESHOLD_INR) — the server enforces
 * this too, so a client that skips the check just gets `payment_ack_required`
 * back. The INR estimate is computed client-side from live FX rates purely to
 * decide whether the checkbox is required; it isn't a real money transfer.
 */
export async function placeBid(
  auctionId: string,
  amount: number,
  listingCurrency: string,
  paymentAck = false,
): Promise<BidResult> {
  const amountInr = await toInrEstimate(amount, listingCurrency);
  const { data, error } = await supabase.rpc("place_bid", {
    p_auction_id: auctionId,
    p_amount: amount,
    p_payment_ack: paymentAck,
    p_amount_inr: amountInr ?? undefined,
  });
  if (error) return { ok: false, reason: error.message };
  return data as unknown as BidResult;
}

export async function checkInvariant(auctionId: string): Promise<InvariantReport> {
  const { data, error } = await supabase.rpc("check_auction_invariant", {
    p_auction_id: auctionId,
  });
  if (error) throw error;
  return data as unknown as InvariantReport;
}

export async function listParticipants(auctionId: string): Promise<AuctionParticipant[]> {
  const { data, error } = await supabase
    .from("auction_participants")
    .select("*")
    .eq("auction_id", auctionId)
    .order("created_at", { ascending: false });
  if (error) throw error;
  return (data ?? []) as AuctionParticipant[];
}

export async function inviteToAuction(auctionId: string, email: string): Promise<SimpleResult> {
  const { data, error } = await supabase.rpc("invite_to_auction", {
    p_auction_id: auctionId,
    p_email: email.trim(),
  });
  if (error) return { ok: false, reason: error.message };
  return data as unknown as SimpleResult;
}

export async function joinPrivateAuction(auctionId: string): Promise<SimpleResult> {
  const { data, error } = await supabase.rpc("join_private_auction", {
    p_auction_id: auctionId,
  });
  if (error) return { ok: false, reason: error.message };
  return data as unknown as SimpleResult;
}

export async function setAuctionLock(auctionId: string, locked: boolean) {
  const { error } = await supabase.from("auctions").update({ locked }).eq("id", auctionId);
  if (error) throw error;
}

/** Permanently deletes an auction (owner only — enforced by RLS). Cascades to
 * its bids, chat messages, participants, and history. */
export async function deleteAuction(auctionId: string) {
  const { error } = await supabase.from("auctions").delete().eq("id", auctionId);
  if (error) throw error;
}

export const hasWinner = (auction: Auction) =>
  auction.status === "ended" && auction.bid_count > 0 && !!auction.leader_name;

/** Turns Postgres/PostgREST's internal error text into something a site owner
 * can actually act on, for the specific case of a pending database migration. */
export function friendlyDbError(message: string): string {
  if (/schema cache/i.test(message)) {
    return "The database hasn't been updated with the latest columns yet. Run the pending migration (see drizzle/migrations/) against this project's database, then try again.";
  }
  return message;
}

export async function confirmAuctionPayment(auctionId: string): Promise<SimpleResult> {
  const { data, error } = await supabase.rpc("confirm_auction_payment", {
    p_auction_id: auctionId,
  });
  if (error) return { ok: false, reason: error.message };
  return data as unknown as SimpleResult;
}

export const nextMinimum = (auction: Auction) =>
  auction.bid_count === 0
    ? Number(auction.starting_price)
    : Number(auction.current_price) + Number(auction.min_increment);

export const isUpcoming = (auction: Auction) =>
  auction.status === "scheduled" && !!auction.starts_at && new Date(auction.starts_at).getTime() > Date.now();

export const reasonText = (reason: string) => {
  switch (reason) {
    case "not_signed_in":
      return "Sign in to place a bid.";
    case "too_low":
      return "Someone outbid you — your amount is below the new minimum.";
    case "auction_not_live":
      return "This auction isn't open for bids.";
    case "auction_ended":
      return "This auction has ended.";
    case "auction_locked":
      return "The owner has locked this auction — no new bids are being accepted.";
    case "not_started":
      return "This auction hasn't started yet.";
    case "not_a_participant":
      return "This is a private auction — you need to accept an invite before bidding.";
    case "payment_ack_required":
      return "Bids of ₹10,00,000 or more need the payment acknowledgement checked.";
    case "no_such_auction":
      return "Auction not found.";
    case "no_such_private_auction":
      return "Private auction not found.";
    case "not_invited":
      return "You haven't been invited to this auction.";
    case "participant_limit_reached":
      return "This private auction has reached its participant limit.";
    case "not_owner":
      return "Only the auction owner can do that.";
    case "no_such_user":
      return "No account found with that email.";
    default:
      return reason;
  }
};
