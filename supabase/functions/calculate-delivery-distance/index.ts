import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const allowedOrigin = Deno.env.get("VORTEX_APP_ORIGIN") || "*";
const corsHeaders = {
  "Access-Control-Allow-Origin": allowedOrigin,
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Content-Type": "application/json",
};

const ORS_BASE = "https://api.heigit.org";
const ORS_PROFILE = "driving-car"; // Perfil viário disponível; não é um perfil exclusivo para motocicletas.

function respond(status: number, body: Record<string, unknown>) {
  return new Response(JSON.stringify(body), { status, headers: corsHeaders });
}
function cleanAddress(value: unknown): string {
  return String(value || "").replace(/\\s+/g, " ").trim();
}
function withRegion(address: string, settings: Record<string, unknown>) {
  const city = cleanAddress(settings.city);
  const uf = cleanAddress(settings.uf);
  const suffix = [city, uf, "Brasil"].filter((part, index, all) =>
    part && !address.toLowerCase().includes(part.toLowerCase()) &&
    (part !== "Brasil" || !/\\b(brasil|brazil)\\b/i.test(address))
  );
  return [address, ...suffix].join(", ");
}
async function orsRequest(path: string, apiKey: string, init: RequestInit) {
  const response = await fetch(ORS_BASE + path, {
    ...init,
    headers: { Authorization: apiKey, "Content-Type": "application/json", ...(init.headers || {}) },
  });
  const payload = await response.json().catch(() => ({}));
  if (!response.ok) {
    console.error("OpenRouteService request failed:", path, response.status, payload?.error?.code || payload?.message || "no details");
    throw new Error("O serviço de mapas não conseguiu processar os endereços. Confira os endereços e a chave do OpenRouteService.");
  }
  return payload;
}
async function geocode(address: string, apiKey: string, settings: Record<string, unknown>): Promise<[number, number]> {
  const query = new URLSearchParams({
    text: withRegion(address, settings),
    "boundary.country": "BR",
    size: "1",
  });
  const response = await fetch(ORS_BASE + "/pelias/v1/search?" + query.toString(), {
    headers: { Authorization: apiKey },
  });
  const payload = await response.json().catch(() => ({}));
  const coordinates = payload?.features?.[0]?.geometry?.coordinates;
  if (!response.ok || !Array.isArray(coordinates) || coordinates.length < 2 ||
      !Number.isFinite(Number(coordinates[0])) || !Number.isFinite(Number(coordinates[1]))) {
    console.error("OpenRouteService geocoding failed:", response.status, payload?.errors || payload?.message || "no result");
    throw new Error("Não foi possível localizar um dos endereços. Confira rua, número, bairro, cidade e CEP.");
  }
  return [Number(coordinates[0]), Number(coordinates[1])];
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return respond(405, { error: "Método não permitido." });

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const orsApiKey = Deno.env.get("OPENROUTESERVICE_API_KEY");
  if (!supabaseUrl || !anonKey || !serviceRoleKey) {
    return respond(500, { error: "A função de cálculo de distância não está configurada no Supabase." });
  }
  if (!orsApiKey) {
    return respond(503, { error: "O cálculo automático ainda não está ativado. Configure OPENROUTESERVICE_API_KEY nos segredos das Edge Functions." });
  }

  const authorization = req.headers.get("Authorization");
  if (!authorization?.startsWith("Bearer ")) return respond(401, { error: "Entre novamente para calcular a rota." });

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

    const { data: context, error: contextError } = await caller.rpc("rpc_get_my_permissions");
    if (contextError || !context?.store_id || !Array.isArray(context.permissions)) {
      return respond(403, { error: "Não foi possível validar o estabelecimento e as permissões." });
    }
    if (!context.permissions.includes("delivery.dispatch_manage")) {
      return respond(403, { error: "Seu perfil não pode calcular distâncias das rotas." });
    }
    const storeId = String(context.store_id);

    const { data: settingsDoc, error: settingsError } = await admin
      .from("vortex_store_documents").select("data")
      .eq("store_id", storeId).eq("document_key", "settings").maybeSingle();
    if (settingsError) {
      console.error("distance settings lookup:", settingsError);
      return respond(500, { error: "Não foi possível consultar o endereço do estabelecimento." });
    }
    const settings = settingsDoc?.data && typeof settingsDoc.data === "object"
      ? settingsDoc.data as Record<string, unknown> : {};
    const originRaw = cleanAddress(settings.storeAddress || settings.address || settings.endereco);
    if (!originRaw) return respond(422, { error: "Cadastre o endereço completo do estabelecimento nas Configurações do Sistema." });

    // O otimizador consulta a matriz viária do mesmo provedor usado para calcular cada remuneração.
    if (body.action === "optimize") {
      const rawIds = Array.isArray(body.order_ids) ? body.order_ids : [];
      const orderIds = Array.from(new Set(rawIds.map(value => String(value || "").trim()).filter(Boolean)));
      if (!orderIds.length || orderIds.length > 24) {
        return respond(400, { error: "Selecione entre 1 e 24 pedidos prontos para otimizar." });
      }
      const { data: orders, error: ordersError } = await admin
        .from("vortex_kds_orders").select("id,address")
        .eq("store_id", storeId).in("id", orderIds);
      if (ordersError || !Array.isArray(orders) || orders.length !== orderIds.length) {
        return respond(422, { error: "Um ou mais pedidos não foram encontrados no estabelecimento ou não possuem endereço disponível." });
      }
      const orderById = new Map(orders.map(order => [String(order.id), order]));
      const orderedOrders = orderIds.map(id => orderById.get(id));
      const addresses = orderedOrders.map(order => cleanAddress(order?.address));
      if (addresses.some(address => !address)) return respond(422, { error: "Um ou mais pedidos não possuem endereço completo para otimização." });

      const coordinates: [number, number][] = [];
      try {
        coordinates.push(await geocode(originRaw, orsApiKey, settings));
        for (const address of addresses) coordinates.push(await geocode(address, orsApiKey, settings));
      } catch (error) {
        return respond(422, { error: error instanceof Error ? error.message : "Não foi possível localizar os endereços." });
      }
      const matrix = await orsRequest("/openrouteservice/v2/matrix/" + ORS_PROFILE, orsApiKey, {
        method: "POST",
        body: JSON.stringify({ locations: coordinates, metrics: ["distance"], units: "m" }),
      });
      const distances = matrix?.distances;
      if (!Array.isArray(distances) || distances.length !== coordinates.length) {
        return respond(502, { error: "O serviço de mapas não retornou uma matriz de distâncias válida." });
      }
      const remaining = new Set(orderIds.map((_, index) => index + 1));
      const optimizedIds: string[] = [];
      let current = 0;
      while (remaining.size) {
        let next = -1;
        let shortest = Number.POSITIVE_INFINITY;
        for (const candidate of remaining) {
          const distance = Number(distances[current]?.[candidate]);
          if (Number.isFinite(distance) && distance >= 0 && distance < shortest) {
            shortest = distance;
            next = candidate;
          }
        }
        if (next < 0) return respond(422, { error: "Não foi possível conectar todos os endereços por vias roteáveis. Confira os endereços dos pedidos." });
        optimizedIds.push(orderIds[next - 1]);
        remaining.delete(next);
        current = next;
      }
      return respond(200, { success: true, provider: "openrouteservice", profile: ORS_PROFILE, optimization: "nearest_next_by_road_distance", optimized_order_ids: optimizedIds });
    }

    const routeId = String(body.route_id || "").trim();
    const orderId = String(body.order_id || "").trim();
    if (!routeId || routeId.length > 100 || !orderId || orderId.length > 120) {
      return respond(400, { error: "Informe uma rota e um pedido válidos." });
    }
    const { data: stop, error: stopError } = await admin
      .from("vortex_delivery_route_stops")
      .select("id,store_id,route_id,order_id,status")
      .eq("store_id", storeId).eq("route_id", routeId).eq("order_id", orderId)
      .in("status", ["assigned", "in_progress", "occurrence"]).maybeSingle();
    if (stopError || !stop) return respond(404, { error: "A parada ativa não foi encontrada nesta rota." });

    const { data: order, error: orderError } = await admin
      .from("vortex_kds_orders").select("address")
      .eq("store_id", storeId).eq("id", orderId).maybeSingle();
    if (orderError || !order) return respond(404, { error: "O pedido desta entrega não foi encontrado." });
    const destinationRaw = cleanAddress(order.address);
    if (!destinationRaw) return respond(422, { error: "O pedido não possui um endereço de entrega completo." });

    const [originCoordinates, destinationCoordinates] = await Promise.all([
      geocode(originRaw, orsApiKey, settings),
      geocode(destinationRaw, orsApiKey, settings),
    ]);
    const route = await orsRequest("/openrouteservice/v2/directions/" + ORS_PROFILE + "/json", orsApiKey, {
      method: "POST",
      body: JSON.stringify({ coordinates: [originCoordinates, destinationCoordinates], instructions: false, units: "m" }),
    });
    const meters = Number(route?.routes?.[0]?.summary?.distance);
    if (!Number.isFinite(meters) || meters <= 0) {
      return respond(422, { error: "Não foi encontrada uma rota viária válida entre o estabelecimento e o cliente." });
    }
    const distanceKm = Math.ceil(meters / 10) / 100;
    const { data: saved, error: saveError } = await caller.rpc("rpc_set_delivery_stop_distance", {
      p_store_id: storeId, p_route_id: routeId, p_order_id: orderId, p_distance_km: distanceKm,
    });
    if (saveError) {
      console.error("rpc_set_delivery_stop_distance:", saveError);
      return respond(409, { error: saveError.message || "A distância foi calculada, mas a faixa de remuneração não pôde ser aplicada." });
    }
    if (!saved?.success) return respond(409, { error: saved?.message || "O banco não confirmou o cálculo da remuneração." });
    return respond(200, {
      success: true, provider: "openrouteservice", profile: ORS_PROFILE,
      route_id: routeId, order_id: orderId,
      distance_km: saved.distance_km,
      courier_payment_amount: saved.courier_payment_amount,
      rule_label: saved.rule_label,
    });
  } catch (error) {
    console.error("calculate-delivery-distance:", error);
    return respond(502, { error: error instanceof Error ? error.message : "O serviço de mapas não conseguiu calcular esta entrega." });
  }
});
