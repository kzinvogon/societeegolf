-- ============================================================
-- Migration 021: society_directory — accept 'trialing' + 'past_due'
-- ============================================================
-- The previous filter included ('active','trial','free') only, but
-- register_society + Stripe webhooks both write 'trialing' (the
-- canonical Stripe status), so newly-registered societies were
-- silently invisible to the join-flow directory. Add 'trialing'
-- (and 'past_due' for safety so a billing-retry hiccup doesn't
-- evict a real society from the directory).
-- ============================================================

CREATE OR REPLACE FUNCTION public.society_directory()
RETURNS TABLE(name text, subdomain text)
LANGUAGE sql
STABLE SECURITY DEFINER
AS $function$
  SELECT name, subdomain
  FROM societies
  WHERE subscription_status IN ('active','trial','trialing','free','past_due')
    AND public_directory = true
    AND is_demo = false
  ORDER BY name;
$function$;
