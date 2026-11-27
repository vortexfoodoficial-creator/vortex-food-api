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
  return String(value || "").replace(/\s+/g, " ").trim();
}
function normalizeAddressForGeocoding(address: string): string {
  return cleanAddress(address)
    .replace(/\s*\|\s*CEP\s*:\s*/i, ", ")
    .replace(/\bN[º°o]\s*/gi, "")
    .replace(/\s+-\s+/g, ", ")
    .replace(/\s*,\s*/g, ", ")
    .replace(/(?:,\s*){2,}/g, ", ")
    .replace(/^,|,$/g, "")
    .trim();
}
function withRegion(address: string, settings: Record<string, unknown>) {
  const normalized = normalizeAddressForGeocoding(address);
  const city = cleanAddress(settings.city);
  const uf = cleanAddress(settings.uf);
  const suffix = [city, uf, "Brasil"].filter((part) =>
    part && !normalized.toLowerCase().includes(part.toLowerCase()) &&
    (part !== "Brasil" || !/\b(brasil|brazil)\b/i.test(normalized))
  );
  return [normalized, ...suffix].join(", ");
}
function normalizeGeocodeLabel(value: unknown): string {
  return cleanAddress(value)
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .toLowerCase()
    .replace(/^(rua|r|avenida|av|travessa|tv|estrada|est|rodovia|rod)\.?\s+/i, "")
    .replace(/[^a-z0-9]/g, "");
}
function providerErrorDetail(payload: any): string {
  const candidate = payload?.error?.message || payload?.error?.code ||
    payload?.message || payload?.detail ||
    (Array.isArray(payload?.errors) ? payload.errors[0]?.message : "");
  return typeof candidate === "string" ? candidate.slice(0, 180) : "";
}
function providerFailureMessage(operation: string, status: number, payload: any): string {
  let reason = "requisição rejeitada";
  if (status === 401 || status === 403) reason = "acesso negado; confira a chave e as permissões da API";
  else if (status === 429) reason = "limite de requisições da API atingido";
  else if (status >= 500) reason = "serviço externo temporariamente indisponível";
  const detail = providerErrorDetail(payload);
  return "OpenRouteService — " + operation + ": " + reason + " (HTTP " + status + ")" +
    (detail ? ". Detalhe: " + detail : ".");
}
async function orsRequest(path: string, apiKey: string, init: RequestInit) {
  const response = await fetch(ORS_BASE + path, {
    ...init,
    headers: { Authorization: apiKey, "Content-Type": "application/json", ...(init.headers || {}) },
  });
  const payload = await response.json().catch(() => ({}));
  if (!response.ok) {
    console.error("OpenRouteService request failed:", path, response.status, providerErrorDetail(payload) || "no details");
    throw new Error(providerFailureMessage("matriz/rota", response.status, payload));
  }
  return payload;
}
function parseStructuredAddress(address: string, settings: Record<string, unknown>) {
  const normalized = normalizeAddressForGeocoding(address);
  const postalMatch = normalized.match(/\b\d{5}-?\d{3}\b/);
  const withoutPostal = normalized.replace(/\bCEP\s*:?\s*\d{5}-?\d{3}\b/i, "").trim();
  const parts = withoutPostal.split(",").map((part) => part.trim()).filter(Boolean);
  const configuredCity = cleanAddress(settings.city);
  const configuredRegion = cleanAddress(settings.uf || settings.state);
  const cityIndex = configuredCity
    ? parts.findIndex((part) => part.toLowerCase() === configuredCity.toLowerCase())
    : -1;

  let addressPart = parts[0] || "";
  let remainingStart = 1;
  if (parts[1] && /^\d+[A-Za-z]?$/.test(parts[1])) {
    addressPart += ", " + parts[1];
    remainingStart = 2;
  }

  const locality = cityIndex >= 0
    ? parts[cityIndex]
    : configuredCity;
  const neighbourhoodParts = cityIndex >= 0
    ? parts.slice(remainingStart, cityIndex)
    : parts.slice(remainingStart).filter((part) => !/^[A-Z]{2}$/i.test(part));
  const regionFromAddress = cityIndex >= 0
    ? parts.slice(cityIndex + 1).find((part) => /^[A-Z]{2}$/i.test(part))
    : "";
  const region = configuredRegion || regionFromAddress || "";

  return {
    address: addressPart,
    neighbourhood: neighbourhoodParts.join(", "),
    locality,
    region,
    postalcode: postalMatch?.[0] || "",
  };
}

async function geoapifyGeocode(
  address: string,
  apiKey: string,
  settings: Record<string, unknown>,
  context: { role: string; orderId?: string },
): Promise<[number, number] | null> {
  const structured = parseStructuredAddress(address, settings);
  const houseMatch = structured.address.match(/^(.*?),\s*(\d+[A-Za-z]?)$/);
  const street = houseMatch?.[1] || structured.address;
  const houseNumber = houseMatch?.[2] || "";

  const requests: URLSearchParams[] = [];
  if (street && structured.locality) {
    const params = new URLSearchParams({
      street,
      city: structured.locality,
      country: "Brazil",
      format: "json",
      limit: "5",
      apiKey,
    });
    if (houseNumber) params.set("housenumber", houseNumber);
    params.set("lang", "pt");
    if (structured.region) params.set("state", structured.region);
    if (structured.postalcode) params.set("postcode", structured.postalcode);
    requests.push(params);
  }
  requests.push(new URLSearchParams({
    text: withRegion(address, settings),
    format: "json",
    limit: "5",
    apiKey,
  }));

  for (let index = 0; index < requests.length; index++) {
    try {
      const response = await fetch("https://api.geoapify.com/v1/geocode/search?" + requests[index].toString());
      const payload = await response.json().catch(() => ({}));
      if (!response.ok) {
        console.warn("Geoapify geocoding request failed:", {
          ...context,
          search: index === 0 && requests.length > 1 ? "structured" : "text",
          status: response.status,
        });
        continue;
      }
      const results = Array.isArray(payload?.results) ? payload.results : [];
      const requestedStreet = normalizeGeocodeLabel(street);
      const requestedCity = normalizeGeocodeLabel(structured.locality);
      const requestedHouseNumber = houseNumber.toLowerCase();
      const evaluated = results.map((item: any) => {
        const type = String(item?.result_type || "").toLowerCase();
        const country = String(item?.country_code || "").toLowerCase();
        const returnedHouseNumber = cleanAddress(item?.housenumber).toLowerCase();
        const returnedStreet = normalizeGeocodeLabel(item?.street || item?.name);
        const returnedCity = normalizeGeocodeLabel(item?.city || item?.municipality);
        const confidence = Number(item?.rank?.confidence);
        const exactBuilding = Boolean(requestedHouseNumber) &&
          type === "building" &&
          returnedHouseNumber === requestedHouseNumber;
        const acceptableStreet = !requestedHouseNumber && type === "street";
        const streetMatches = Boolean(requestedStreet && returnedStreet === requestedStreet);
        const cityMatches = Boolean(!requestedCity || !returnedCity || returnedCity === requestedCity);
        const confidenceIsAdequate = Number.isFinite(confidence) && confidence >= 0.5;
        const coordinatesAreValid = Number.isFinite(Number(item?.lon)) &&
          Number.isFinite(Number(item?.lat));
        const accepted = (exactBuilding || acceptableStreet) &&
          country === "br" &&
          streetMatches &&
          cityMatches &&
          confidenceIsAdequate &&
          coordinatesAreValid;
        return {
          item,
          accepted,
          reason: !exactBuilding && !acceptableStreet ? "result_type_or_house_number_mismatch"
            : country !== "br" ? "country_mismatch"
            : !streetMatches ? "street_mismatch"
            : !cityMatches ? "city_mismatch"
            : !confidenceIsAdequate ? "low_or_missing_confidence"
            : !coordinatesAreValid ? "invalid_coordinates"
            : null,
        };
      });
      const candidate = evaluated.find((entry: any) => entry.accepted)?.item;
      if (candidate) {
        console.info("Geoapify geocoding candidate accepted:", {
          ...context,
          search: index === 0 && requests.length > 1 ? "structured" : "text",
          result_type: candidate.result_type || null,
          rank_confidence: candidate.rank?.confidence ?? null,
          street_match: true,
          city_match: true,
          house_number_match: Boolean(requestedHouseNumber),
        });
        return [Number(candidate.lon), Number(candidate.lat)];
      }
      if (evaluated.length) {
        console.warn("Geoapify geocoding candidates rejected:", {
          ...context,
          search: index === 0 && requests.length > 1 ? "structured" : "text",
          candidates: evaluated.slice(0, 5).map((entry: any) => ({
            result_type: entry.item?.result_type || null,
            rank_confidence: entry.item?.rank?.confidence ?? null,
            reason: entry.reason,
          })),
        });
        // Não recorrer a outro provedor quando a Geoapify encontrou candidatos,
        // mas nenhum corresponde com segurança ao endereço solicitado.
        throw new Error("A localização encontrada para o endereço não passou na validação de rua, número, cidade ou confiança. Confira o endereço do estabelecimento/cliente antes de calcular a rota.");
      }
    } catch (error) {
      console.warn("Geoapify geocoding network error:", {
        ...context,
        search: index === 0 && requests.length > 1 ? "structured" : "text",
        detail: error instanceof Error ? error.message.slice(0, 160) : "unknown error",
      });
    }
  }
  console.warn("Geoapify did not return a street/building match; trying OpenRouteService:", context);
  return null;
}

async function geocode(
  address: string,
  apiKey: string,
  settings: Record<string, unknown>,
  context: { role: string; orderId?: string },
): Promise<[number, number]> {
  const normalizedQuery = withRegion(address, settings);
  const geoapifyApiKey = Deno.env.get("GEOAPIFY_API_KEY");
  if (geoapifyApiKey) {
    const geoapifyCoordinates = await geoapifyGeocode(address, geoapifyApiKey, settings, context);
    if (geoapifyCoordinates) return geoapifyCoordinates;
  }
  const validFeature = (item: any) => {
    const layer = String(item?.properties?.layer || "").toLowerCase();
    const point = item?.geometry?.coordinates;
    return (layer === "address" || layer === "street") &&
      Array.isArray(point) && point.length >= 2 &&
      Number.isFinite(Number(point[0])) && Number.isFinite(Number(point[1]));
  };

  let feature: any = null;
  let source = "text";
  let structuredFeatures: any[] = [];
  const structured = parseStructuredAddress(address, settings);

  if (structured.address && structured.locality) {
    const structuredQuery = new URLSearchParams({
      address: structured.address,
      locality: structured.locality,
      country: "Brasil",
      "boundary.country": "BR",
      layers: "address,street",
      size: "5",
    });
    if (structured.neighbourhood) structuredQuery.set("neighbourhood", structured.neighbourhood);
    if (structured.region) structuredQuery.set("region", structured.region);
    if (structured.postalcode) structuredQuery.set("postalcode", structured.postalcode);

    try {
      const structuredResponse = await fetch(ORS_BASE + "/pelias/v1/search/structured?" + structuredQuery.toString(), {
        headers: { Authorization: apiKey },
      });
      const structuredPayload = await structuredResponse.json().catch(() => ({}));
      if (!structuredResponse.ok) {
        console.warn("OpenRouteService structured geocoding request failed; trying text search:", {
          ...context,
          status: structuredResponse.status,
          detail: providerErrorDetail(structuredPayload) || null,
        });
      } else {
        structuredFeatures = Array.isArray(structuredPayload?.features) ? structuredPayload.features : [];
        feature = structuredFeatures.find(validFeature) || null;
        if (feature) source = "structured";
      }
    } catch (error) {
      console.warn("OpenRouteService structured geocoding network error; trying text search:", {
        ...context,
        detail: error instanceof Error ? error.message.slice(0, 160) : "unknown error",
      });
    }
  }

  if (!feature) {
    const query = new URLSearchParams({
      text: normalizedQuery,
      "boundary.country": "BR",
      layers: "address,street",
      size: "5",
    });
    const response = await fetch(ORS_BASE + "/pelias/v1/search?" + query.toString(), {
      headers: { Authorization: apiKey },
    });
    const payload = await response.json().catch(() => ({}));
    if (!response.ok) {
      console.error("OpenRouteService geocoding failed:", {
        ...context,
        status: response.status,
        detail: providerErrorDetail(payload) || null,
      });
      throw new Error(providerFailureMessage("localização de endereço", response.status, payload));
    }
    const features = Array.isArray(payload?.features) ? payload.features : [];
    feature = features.find(validFeature) || null;
    if (feature) source = "text";
    if (!feature) {
      const fallback = features[0]?.properties || structuredFeatures[0]?.properties || {};
      console.warn("OpenRouteService did not return a street/address match:", {
        ...context,
        requested_layer: "address,street",
        parsed_address: {
          has_street: Boolean(structured.address),
          has_house_number: /,\s*\d+[A-Za-z]?$/.test(structured.address),
          has_neighbourhood: Boolean(structured.neighbourhood),
          has_locality: Boolean(structured.locality),
          has_region: Boolean(structured.region),
          has_postalcode: Boolean(structured.postalcode),
        },
        structured_search: Boolean(structured.address && structured.locality),
        fallback_layer: fallback.layer || null,
        fallback_accuracy: fallback.accuracy || null,
        fallback_match_type: fallback.match_type || null,
        fallback_name: fallback.name || null,
        fallback_confidence: fallback.confidence ?? null,
      });
      throw new Error("O mapa não reconheceu a rua ou o endereço informado. Não foi usada a localização genérica da cidade. Confira rua, número, bairro e CEP.");
    }
  }

  const coordinates = feature.geometry.coordinates;
  const properties = feature.properties || {};
  console.info("OpenRouteService geocoding candidate:", {
    ...context,
    source,
    confidence: properties.confidence ?? null,
    match_type: properties.match_type || null,
    accuracy: properties.accuracy || null,
    layer: properties.layer || null,
  });
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
        coordinates.push(await geocode(originRaw, orsApiKey, settings, { role: "store_origin" }));
        for (let index = 0; index < addresses.length; index++) {
          coordinates.push(await geocode(addresses[index], orsApiKey, settings, {
            role: "customer_destination", orderId: orderIds[index],
          }));
        }
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

    if (body.action === "calculate_route") {
      const routeId = String(body.route_id || "").trim();
      const rawIds = Array.isArray(body.order_ids) ? body.order_ids : [];
      const orderIds = Array.from(new Set(rawIds.map(value => String(value || "").trim()).filter(Boolean)));
      if (!routeId || !orderIds.length || orderIds.length > 24) {
        return respond(400, { error: "Informe uma rota e entre 1 e 24 pedidos válidos." });
      }
      const { data: stops, error: stopsError } = await admin
        .from("vortex_delivery_route_stops")
        .select("id,store_id,route_id,order_id,status")
        .eq("store_id", storeId).eq("route_id", routeId).in("order_id", orderIds)
        .in("status", ["assigned", "in_progress", "occurrence"]);
      if (stopsError || !Array.isArray(stops) || stops.length !== orderIds.length) {
        return respond(422, { error: "Uma ou mais entregas não estão ativas nesta rota. Atualize a Central de Operações e tente novamente." });
      }
      const { data: orders, error: ordersError } = await admin
        .from("vortex_kds_orders").select("id,address")
        .eq("store_id", storeId).in("id", orderIds);
      if (ordersError || !Array.isArray(orders) || orders.length !== orderIds.length) {
        return respond(422, { error: "Não foi possível localizar todos os endereços dos pedidos desta rota." });
      }
      const orderById = new Map(orders.map(order => [String(order.id), order]));
      const orderedOrders = orderIds.map(id => orderById.get(id));
      const addresses = orderedOrders.map(order => cleanAddress(order?.address));
      if (addresses.some(address => !address)) {
        return respond(422, { error: "Uma ou mais entregas não possuem endereço completo para calcular a remuneração." });
      }

      const coordinates: [number, number][] = [];
      try {
        coordinates.push(await geocode(originRaw, orsApiKey, settings, { role: "store_origin" }));
        for (let index = 0; index < addresses.length; index++) {
          coordinates.push(await geocode(addresses[index], orsApiKey, settings, {
            role: "customer_destination", orderId: orderIds[index],
          }));
        }
      } catch (error) {
        return respond(422, { error: error instanceof Error ? error.message : "Não foi possível localizar os endereços da rota." });
      }
      const matrix = await orsRequest("/openrouteservice/v2/matrix/" + ORS_PROFILE, orsApiKey, {
        method: "POST",
        body: JSON.stringify({
          locations: coordinates,
          sources: ["0"],
          destinations: orderIds.map((_, index) => String(index + 1)),
          metrics: ["distance"],
          units: "m",
          resolve_locations: true,
        }),
      });
      const distances = matrix?.distances?.[0];
      const resolvedOrigin = matrix?.sources?.[0] || null;
      if (!Array.isArray(distances) || distances.length !== orderIds.length) {
        return respond(502, { error: "O serviço de mapas não retornou todas as distâncias da rota." });
      }

      const results: Record<string, unknown>[] = [];
      for (let index = 0; index < orderIds.length; index++) {
        const rawMeters = distances[index];
        const meters = rawMeters == null ? NaN : Number(rawMeters);
        if (!Number.isFinite(meters) || meters <= 0) {
          const resolvedDestination = matrix?.destinations?.[index] || null;
          const originLabel = String(resolvedOrigin?.name || "").trim();
          const destinationLabel = String(resolvedDestination?.name || "").trim();
          const sourceSnap = Array.isArray(resolvedOrigin?.location) ? resolvedOrigin.location : null;
          const destinationSnap = Array.isArray(resolvedDestination?.location) ? resolvedDestination.location : null;
          const originalDestination = coordinates[index + 1];
          const locationDetails = [
            originLabel ? "Origem reconhecida pelo mapa: " + originLabel : "",
            destinationLabel ? "Destino reconhecido pelo mapa: " + destinationLabel : "",
            sourceSnap ? "Ponto viário da loja (longitude, latitude): " + sourceSnap.join(", ") : "",
            destinationSnap ? "Ponto viário do cliente (longitude, latitude): " + destinationSnap.join(", ") : "",
            originalDestination ? "Coordenada localizada para o cliente (longitude, latitude): " + originalDestination.join(", ") : "",
            Number.isFinite(Number(resolvedDestination?.snapped_distance))
              ? "Ajuste até a via: " + Number(resolvedDestination.snapped_distance).toFixed(1) + " m" : "",
          ].filter(Boolean).join(". ");
          console.warn("OpenRouteService returned no road distance for delivery:", {
            order_id: orderIds[index],
            origin: resolvedOrigin ? { name: resolvedOrigin.name, location: resolvedOrigin.location } : null,
            destination: resolvedDestination ? { name: resolvedDestination.name, location: resolvedDestination.location } : null,
          });
          results.push({
            order_id: orderIds[index],
            success: false,
            error: "O mapa localizou os pontos, mas não encontrou ligação viária entre eles." +
              (locationDetails ? " " + locationDetails : " Confira se o ponto indicado pelo mapa corresponde ao endereço informado."),
          });
          continue;
        }
        const distanceKm = Math.ceil(meters / 10) / 100;
        const { data: saved, error: saveError } = await caller.rpc("rpc_set_delivery_stop_distance", {
          p_store_id: storeId, p_route_id: routeId, p_order_id: orderIds[index], p_distance_km: distanceKm,
        });
        if (saveError || !saved?.success) {
          results.push({ order_id: orderIds[index], success: false, error: saveError?.message || saved?.message || "Não foi possível registrar a remuneração desta entrega." });
        } else {
          results.push({
            order_id: orderIds[index], success: true, distance_saved: saved.distance_saved === true,
            distance_km: saved.distance_km,
            courier_payment_amount: saved.courier_payment_amount,
            payment_pending: saved.payment_pending === true,
            rule_label: saved.rule_label,
          });
        }
      }
      return respond(200, {
        success: results.every(item => item.success === true),
        provider: "openrouteservice",
        profile: ORS_PROFILE,
        route_id: routeId,
        results,
      });
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
      geocode(originRaw, orsApiKey, settings, { role: "store_origin" }),
      geocode(destinationRaw, orsApiKey, settings, { role: "customer_destination", orderId }),
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
      distance_saved: saved.distance_saved === true,
      distance_km: saved.distance_km,
      courier_payment_amount: saved.courier_payment_amount,
      payment_pending: saved.payment_pending === true,
      rule_label: saved.rule_label,
    });
  } catch (error) {
    console.error("calculate-delivery-distance:", error);
    return respond(502, { error: error instanceof Error ? error.message : "O serviço de mapas não conseguiu calcular esta entrega." });
  }
});
