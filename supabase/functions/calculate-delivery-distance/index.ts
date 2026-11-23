import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const allowedOrigin = Deno.env.get("VORTEX_APP_ORIGIN") || "*";
const corsHeaders = {
  "Access-Control-Allow-Origin": allowedOrigin,
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Content-Type": "application/json",
};

function respond(status: number, body: Record<string, unknown>) {
  return new Response(JSON.stringify(body), { status, headers: corsHeaders });
}

function cleanAddress(value: unknown): string {
  return String(value || "").replace(/\s+/g, " ").trim();
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return respond(405, { error: "Método não permitido." });

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const googleMapsApiKey = Deno.env.get("GOOGLE_MAPS_API_KEY");
  if (!supabaseUrl || !anonKey || !serviceRoleKey) {
    return respond(500, { error: "A função de cálculo de distância não está configurada no Supabase." });
  }
  if (!googleMapsApiKey) {
    return respond(503, { error: "O cálculo automático ainda não está ativado. Configure a chave GOOGLE_MAPS_API_KEY nos segredos das Edge Functions." });
  }

  const authorization = req.headers.get("Authorization");
  if (!authorization?.startsWith("Bearer ")) {
    return respond(401, { error: "Entre novamente para calcular a rota." });
  }

  const caller = createClient(supabaseUrl, anonKey, {
    auth: { persistSession: false, autoRefreshToken: false },
    global: { headers: { Authorization: authorization } },
  });
  const admin = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  try {
    const token = authorization.slice("Bearer ".length).trim();
    const { data: userData, error: userError } = await caller.auth.getUser(token);
    if (userError || !userData.user) return respond(401, { error: "Sessão inválida. Entre novamente." });

    let body: Record<string, unknown>;
    try { body = await req.json(); }
    catch { return respond(400, { error: "Dados da rota inválidos." }); }

    const routeId = String(body.route_id || "").trim();
    const orderId = String(body.order_id || "").trim();
    if (!routeId || routeId.length > 100 || !orderId || orderId.length > 120) {
      return respond(400, { error: "Informe uma rota e um pedido válidos." });
    }

    const { data: context, error: contextError } = await caller.rpc("rpc_get_my_permissions");
    if (contextError || !context?.store_id || !Array.isArray(context.permissions)) {
      return respond(403, { error: "Não foi possível validar o estabelecimento e as permissões." });
    }
    if (!context.permissions.includes("delivery.dispatch_manage")) {
      return respond(403, { error: "Seu perfil não pode calcular distâncias das rotas." });
    }
    const storeId = String(context.store_id);

    const { data: stop, error: stopError } = await admin
      .from("vortex_delivery_route_stops")
      .select("id,store_id,route_id,order_id,status")
      .eq("store_id", storeId)
      .eq("route_id", routeId)
      .eq("order_id", orderId)
      .in("status", ["assigned", "in_progress", "occurrence"])
      .maybeSingle();
    if (stopError || !stop) return respond(404, { error: "A parada ativa não foi encontrada nesta rota." });

    const [{ data: settingsDoc, error: settingsError }, { data: order, error: orderError }] = await Promise.all([
      admin.from("vortex_store_documents").select("data")
        .eq("store_id", storeId).eq("document_key", "settings").maybeSingle(),
      admin.from("vortex_kds_orders").select("address")
        .eq("store_id", storeId).eq("id", orderId).maybeSingle(),
    ]);
    if (settingsError || orderError) {
      console.error("distance lookup:", settingsError || orderError);
      return respond(500, { error: "Não foi possível consultar os endereços cadastrados para esta entrega." });
    }

    const settings = settingsDoc?.data && typeof settingsDoc.data === "object" ? settingsDoc.data : {};
    const originRaw = cleanAddress(settings.storeAddress || settings.address || settings.endereco);
    const destinationRaw = cleanAddress(order?.address);
    if (!originRaw || !destinationRaw) {
      return respond(422, { error: !originRaw
        ? "Cadastre o endereço completo do estabelecimento nas Configurações do Sistema."
        : "O pedido não possui um endereço de entrega completo." });
    }

    const withBrazil = (address: string) => /\b(brasil|brazil)\b/i.test(address) ? address : address + ", Brasil";
    const routeResponse = await fetch("https://routes.googleapis.com/directions/v2:computeRoutes", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-Goog-Api-Key": googleMapsApiKey,
        "X-Goog-FieldMask": "routes.distanceMeters,routes.duration",
      },
      body: JSON.stringify({
        origin: { address: withBrazil(originRaw) },
        destination: { address: withBrazil(destinationRaw) },
        travelMode: "TWO_WHEELER",
        regionCode: "BR",
        languageCode: "pt-BR",
        routingPreference: "TRAFFIC_UNAWARE",
      }),
    });

    const routePayload = await routeResponse.json().catch(() => ({}));
    if (!routeResponse.ok) {
      console.error("Google Routes API error:", routePayload);
      return respond(502, { error: "O serviço de mapas não conseguiu calcular esta rota. Confira os endereços e a configuração da API." });
    }
    const meters = Number(routePayload?.routes?.[0]?.distanceMeters);
    if (!Number.isFinite(meters) || meters <= 0) {
      return respond(422, { error: "Não foi encontrada uma rota viária válida entre o estabelecimento e o cliente." });
    }
    // Arredonda para cima a 0,01 km para não enquadrar uma rota acima do limite
    // artificialmente na faixa inferior por causa do arredondamento.
    const distanceKm = Math.ceil(meters / 10) / 100;

    const { data: saved, error: saveError } = await caller.rpc("rpc_set_delivery_stop_distance", {
      p_store_id: storeId,
      p_route_id: routeId,
      p_order_id: orderId,
      p_distance_km: distanceKm,
    });
    if (saveError) {
      console.error("rpc_set_delivery_stop_distance:", saveError);
      return respond(409, { error: saveError.message || "A distância foi calculada, mas a faixa de remuneração não pôde ser aplicada." });
    }
    if (!saved?.success) return respond(409, { error: saved?.message || "O banco não confirmou o cálculo da remuneração." });

    return respond(200, {
      success: true,
      route_id: routeId,
      order_id: orderId,
      distance_km: saved.distance_km,
      courier_payment_amount: saved.courier_payment_amount,
      rule_label: saved.rule_label,
    });
  } catch (error) {
    console.error("calculate-delivery-distance:", error);
    return respond(500, { error: "Ocorreu um erro inesperado ao calcular a distância da entrega." });
  }
});
