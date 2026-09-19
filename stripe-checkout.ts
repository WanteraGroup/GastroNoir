// =========================================================
// GASTRONOIRE – Stripe fizetés (Supabase Edge Function)
// Fájlnév a feltöltéskor: supabase/functions/stripe-checkout/index.ts
//
// Ez a funkció a SZERVEROLDALON fut, ide kerül a Stripe TITKOS kulcsa.
// A böngésző SOHA nem látja a titkos kulcsot – ez a biztonságos megoldás.
// =========================================================

import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import Stripe from "https://esm.sh/stripe@13.10.0?target=deno";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

// A Stripe titkos kulcsát a Supabase titkos tárolójából olvassuk (Settings → Edge Functions → Secrets)
const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY")!, {
  apiVersion: "2023-10-16",
});

// A csomagok árai forintban (érdemes inkább Stripe termék-ID-ket használni – lásd lentebb)
const PLANS: Record<string, { amount: number; mode: "payment" | "subscription"; months: number | null; name: string }> = {
  trial7:   { amount: 990,   mode: "payment",      months: 0,    name: "Degusztáció (7 nap)" },
  premium:  { amount: 2990,  mode: "subscription", months: 1,    name: "Table d'Hôte (havi)" },
  m3:       { amount: 7990,  mode: "payment",      months: 3,    name: "Cuvée (3 hónap)" },
  m6:       { amount: 14900, mode: "payment",      months: 6,    name: "Appellation (6 hónap)" },
  m9:       { amount: 20900, mode: "payment",      months: 9,    name: "Grand Cru (9 hónap)" },
  yearly:   { amount: 29900, mode: "payment",      months: 12,   name: "Sommelier (éves)" },
  lifetime: { amount: 99900, mode: "payment",      months: null, name: "Héritage (örök)" },
};

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });

  try {
    const { plan, origin } = await req.json();
    const cfg = PLANS[plan];
    if (!cfg) return json({ error: "Ismeretlen csomag." }, 400);

    // A hívó felhasználó azonosítása a bejelentkezési tokenből
    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_ANON_KEY")!,
      { global: { headers: { Authorization: req.headers.get("Authorization")! } } }
    );
    const { data: { user } } = await supabase.auth.getUser();
    if (!user) return json({ error: "Nincs bejelentkezve." }, 401);

    const base = origin || Deno.env.get("APP_URL") || "http://localhost:3000";

    const session = await stripe.checkout.sessions.create({
      mode: cfg.mode,
      customer_email: user.email,
      line_items: [{
        quantity: 1,
        price_data: {
          currency: "huf",
          unit_amount: cfg.amount,           // Ft-ban, a legkisebb egységben
          product_data: { name: cfg.name },
          ...(cfg.mode === "subscription" ? { recurring: { interval: "month" } } : {}),
        },
      }],
      metadata: { user_id: user.id, plan },
      success_url: `${base}?payment=success&plan=${plan}`,
      cancel_url:  `${base}?payment=cancel&plan=${plan}`,
    });

    return json({ url: session.url });
  } catch (e) {
    return json({ error: String(e?.message || e) }, 500);
  }
});

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status, headers: { ...CORS, "Content-Type": "application/json" },
  });
}

// =========================================================
// 2) FIZETÉS-VISSZAIGAZOLÁS (webhook)
// Fájlnév: supabase/functions/stripe-webhook/index.ts
//
// Ez fut le, amikor a Stripe jelzi, hogy a fizetés sikerült.
// Itt állítjuk be a felhasználó előfizetését az adatbázisban.
// =========================================================
/*
import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import Stripe from "https://esm.sh/stripe@13.10.0?target=deno";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY")!, { apiVersion: "2023-10-16" });
const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

const EXPIRY: Record<string, number | null> = { trial7: 7/30, premium: 1, m3: 3, m6: 6, m9: 9, yearly: 12, lifetime: null };

serve(async (req) => {
  const sig = req.headers.get("stripe-signature")!;
  const body = await req.text();
  let event;
  try {
    event = await stripe.webhooks.constructEventAsync(body, sig, Deno.env.get("STRIPE_WEBHOOK_SECRET")!);
  } catch (e) { return new Response("Bad signature", { status: 400 }); }

  if (event.type === "checkout.session.completed") {
    const s = event.data.object as Stripe.Checkout.Session;
    const userId = s.metadata?.user_id, plan = s.metadata?.plan || "premium";
    const months = EXPIRY[plan];
    let expires = null;
    if (months !== null && months !== undefined) {
      const d = new Date();
      if (months < 1) d.setDate(d.getDate() + Math.round(months * 30));
      else d.setMonth(d.getMonth() + months);
      expires = d.toISOString();
    }
    await db.from("subscriptions").update({ status: "cancelled" }).eq("user_id", userId).eq("status", "active");
    await db.from("subscriptions").insert({ user_id: userId, plan, status: "active", expires_at: expires, amount_paid: s.amount_total ?? null });
  }
  return new Response("ok", { status: 200 });
});
*/
