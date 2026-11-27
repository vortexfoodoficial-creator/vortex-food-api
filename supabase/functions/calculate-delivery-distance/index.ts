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
const GEOCODE_CACHE_TTL_MS = 15 * 60 * 1000;
const GEOCODE_CACHE_MAX_ENTRIES = 500;
const geocodeCache = new Map<string, { coordinates: [number, number]; expiresAt: number }>();

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
    .replace(/\b(?:rua|r|avenida|av|travessa|tv|estrada|est|rodovia|rod)\.?\b/g, " ")
    .replace(/\b\d+[a-z]?\b/gi, " ")
    .replace(/[^a-z]/g, "");
}
function geocodeStreetMatches(item: any, requestedStreet: string): boolean {
  const expected = normalizeGeocodeLabel(requestedStreet);
  if (!expected) return false;
  const candidates = [item?.street, item?.address_line1, item?.name, item?.label];
  return candidates.some((candidate) => normalizeGeocodeLabel(candidate) === expected);
}
function isValidCoordinatePair(lon: unknown, lat: unknown): boolean {
  const longitude = Number(lon);
  const latitude = Number(lat);
  return Number.isFinite(longitude) && Number.isFinite(latitude) &&
    longitude >= -180 && longitude <= 180 && latitude >= -90 && latitude <= 90;
}
function normalizeBrazilianRegion(value: unknown): string {
  const normalized = normalizeGeocodeLabel(value);
  const aliases: Record<string, string> = {
    saopaulo: "sp", sp: "sp",
    riodejaneiro: "rj", rj: "rj",
    minasgerais: "mg", mg: "mg",
    espiritosanto: "es", es: "es",
    parana: "pr", pr: "pr",
    santacatarina: "sc", sc: "sc",
    riograndedosul: "rs", rs: "rs",
    bahia: "ba", ba: "ba",
    goias: "go", go: "go",
    matogrossodosul: "ms", ms: "ms",
    matogrosso: "mt", mt: "mt",
    tocantins: "to", to: "to",
    acre: "ac", ac: "ac",
    amazonas: "am", am: "am",
    para: "pa", pa: "pa",
    rondonia: "ro", ro: "ro",
    roraima: "rr", rr: "rr",
    amapa: "ap",
    maranhao: "ma", ma: "ma",
    piaui: "pi", pi: "pi",
    ceara: "ce", ce: "ce",
    riograndedonorte: "rn", rn: "rn",
    paraiba: "pb", pb: "pb",
    pernambuco: "pe", pe: "pe",
    alagoas: "al", al: "al",
    sergipe: "se", se: "se",
    distritofederal: "df", df: "df",
  };
  return aliases[normalized] || normalized;
}
function geocodeCacheKey(address: ReturnType<typeof parseStructuredAddress>): string {
  return [
    normalizeGeocodeLabel(address.street),
    cleanAddress(address.houseNumber).toLowerCase(),
    normalizeGeocodeLabel(address.neighbourhood),
    normalizeGeocodeLabel(address.locality),
    normalizeBrazilianRegion(address.region),
    cleanAddress(address.postalcode).replace(/\D/g, ""),
  ].join("|");
}
function getCachedGeocode(key: string): [number, number] | null {
  const cached = geocodeCache.get(key);
  if (!cached) return null;
  if (cached.expiresAt <= Date.now()) {
    geocodeCache.delete(key);
    return null;
  }
  return [cached.coordinates[0], cached.coordinates[1]];
}
function setCachedGeocode(key: string, coordinates: [number, number]) {
  if (geocodeCache.size >= GEOCODE_CACHE_MAX_ENTRIES) {
    const oldestKey = geocodeCache.keys().next().value;
    if (oldestKey) geocodeCache.delete(oldestKey);
  }
  geocodeCache.set(key, {
    coordinates: [coordinates[0], coordinates[1]],
    expiresAt: Date.now() + GEOCODE_CACHE_TTL_MS,
  });
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
    signal: init.signal || AbortSignal.timeout(15000),
    headers: { Authorization: apiKey, "Content-Type": "application/json", ...(init.headers || {}) },
  });
  const payload = await response.json().catch(() => ({}));
  if (!response.ok) {
    console.error("OpenRouteService request failed:", path, response.status, providerErrorDetail(payload) || "no details");
    throw new Error(providerFailureMessage("matriz/rota", response.status, payload));
  }
  return payload;
}
function parseStructuredAddress(
  address: string,
  settings: Record<string, unknown>,
  useStoreProfile = false,
) {
  const configuredCity = cleanAddress(settings.city);
  const configuredRegion = cleanAddress(settings.uf || settings.state);
  const configuredPostal = cleanAddress(settings.cep || settings.postalcode).match(/\b\d{5}-?\d{3}\b/)?.[0] || "";

  // Para a origem, preferimos os campos separados já salvos pelo cadastro do estabelecimento.
  // Isso evita depender da interpretação do endereço concatenado em uma única string.
  if (useStoreProfile) {
    const street = cleanAddress(settings.street || settings.logradouro);
    const houseNumber = cleanAddress(settings.streetNumber || settings.number || settings.numero)
      .replace(/^N[º°o]\s*/i, "");
    const streetLooksLikeSingleField = street && !street.includes(",") &&
      (Boolean(houseNumber) || !/\d/.test(street));
    if (streetLooksLikeSingleField && configuredCity) {
      return {
        address: [street, houseNumber].filter(Boolean).join(", "),
        street,
        houseNumber,
        neighbourhood: cleanAddress(settings.neighborhood || settings.bairro),
        locality: configuredCity,
        region: configuredRegion,
        postalcode: configuredPostal,
      };
    }
  }

  const normalized = normalizeAddressForGeocoding(address);
  const postalMatch = normalized.match(/\b\d{5}-?\d{3}\b/);
  const withoutPostal = normalized
    .replace(/,?\s*CEP\s*:?\s*\d{5}-?\d{3}\b/i, "")
    .replace(/,?\s*\b\d{5}-?\d{3}\b\s*$/i, "")
    .trim();
  const parts = withoutPostal.split(",").map((part) => part.trim()).filter(Boolean);
  const cityIndex = configuredCity
    ? parts.findIndex((part) => normalizeGeocodeLabel(part) === normalizeGeocodeLabel(configuredCity))
    : -1;

  let street = parts[0] || "";
  let houseNumber = "";
  let remainingStart = 1;

  const numberInFirstPart = street.match(/^(.*?)[,\s]+(?:N[º°o]\s*)?(\d+[A-Za-z]?)$/i);
  if (numberInFirstPart?.[1]) {
    street = numberInFirstPart[1].trim();
    houseNumber = numberInFirstPart[2];
  } else if (parts[1] && /^(?:N[º°o]\s*)?\d+[A-Za-z]?$/i.test(parts[1])) {
    houseNumber = parts[1].replace(/^N[º°o]\s*/i, "");
    remainingStart = 2;
  }

  const locality = cityIndex >= 0 ? parts[cityIndex] : configuredCity;
  const neighbourhoodParts = cityIndex >= 0
    ? parts.slice(remainingStart, cityIndex)
    : parts.slice(remainingStart).filter((part) => !/^[A-Z]{2}$/i.test(part));
  const regionFromAddress = cityIndex >= 0
    ? parts.slice(cityIndex + 1).find((part) => /^[A-Z]{2}$/i.test(part))
    : "";
  const region = configuredRegion || regionFromAddress || "";
  const neighbourhood = neighbourhoodParts.length
    ? (cityIndex >= 0 ? neighbourhoodParts.join(", ") : neighbourhoodParts[0])
    : "";

  return {
    address: [street, houseNumber].filter(Boolean).join(", "),
    street,
    houseNumber,
    neighbourhood,
    locality,
    region,
    postalcode: postalMatch?.[0] || configuredPostal,
  };
}

async function geoapifyGeocode(
  address: string,
  apiKey: string,
  settings: Record<string, unknown>,
  context: { role: string; orderId?: string },
): Promise<[number, number] | null> {
  const structured = parseStructuredAddress(address, settings, context.role === "store_origin");
  const street = structured.street;
  const houseNumber = structured.houseNumber;
  const requests: { label: string; params: URLSearchParams }[] = [];

  if (street && structured.locality) {
    const params = new URLSearchParams({
      street,
      city: structured.locality,
      country: "Brazil",
      format: "json",
      limit: "5",
      apiKey,
      lang: "pt",
    });
    if (houseNumber) params.set("housenumber", houseNumber);
    if (structured.region) params.set("state", structured.region);
    if (structured.postalcode) params.set("postcode", structured.postalcode);
    requests.push({ label: "structured", params });
  }

  requests.push({
    label: "text",
    params: new URLSearchParams({
      text: withRegion(address, settings),
      format: "json",
      limit: "5",
      apiKey,
      lang: "pt",
    }),
  });

  for (const request of requests) {
    let payload: any;
    try {
      const response = await fetch(
        "https://api.geoapify.com/v1/geocode/search?" + request.params.toString(),
        { signal: AbortSignal.timeout(9000) },
      );
      payload = await response.json().catch(() => ({}));
      if (!response.ok) {
        console.warn("Geoapify geocoding request failed:", {
          ...context, search: request.label, status: response.status,
        });
        continue;
      }
    } catch (error) {
      console.warn("Geoapify geocoding transport failure:", {
        ...context,
        search: request.label,
        detail: error instanceof Error ? error.message.slice(0, 120) : "unknown error",
      });
      continue;
    }

    const results = Array.isArray(payload?.results) ? payload.results : [];
    const requestedStreet = normalizeGeocodeLabel(street);
    const requestedCity = normalizeGeocodeLabel(structured.locality);
    const requestedHouse = houseNumber.toLowerCase();
    const requestedPostcode = structured.postalcode.replace(/\D/g, "");
    const requestedRegion = normalizeBrazilianRegion(structured.region);

    const evaluated = results.map((item: any) => {
      const type = String(item?.result_type || "").toLowerCase();
      const country = String(item?.country_code || "").toLowerCase();
      const returnedHouse = cleanAddress(item?.housenumber).toLowerCase();
      const returnedCity = normalizeGeocodeLabel(item?.city || item?.municipality);
      const returnedPostcode = cleanAddress(item?.postcode).replace(/\D/g, "");
      const returnedRegion = normalizeBrazilianRegion(item?.state_code || item?.state);
      const rank = item?.rank || {};
      const confidence = Number(rank.confidence);
      const streetConfidence = Number(rank.confidence_street_level);
      const cityConfidence = Number(rank.confidence_city_level);
      const buildingConfidence = Number(rank.confidence_building_level);

      const exactBuilding = Boolean(requestedHouse) &&
        type === "building" && returnedHouse === requestedHouse;
      const exactStreet = !requestedHouse && type === "street";
      const streetMatches = geocodeStreetMatches(item, street);
      const cityMatches = Boolean(requestedCity && returnedCity && returnedCity === requestedCity);
      const postcodeMatches = Boolean(requestedPostcode && returnedPostcode === requestedPostcode);
      const postcodeConflicts = Boolean(requestedPostcode && returnedPostcode && !postcodeMatches);
      const regionMatches = !requestedRegion || !returnedRegion || returnedRegion === requestedRegion;
      const componentConfidence = Number.isFinite(streetConfidence) && streetConfidence >= 0.85 &&
        Number.isFinite(cityConfidence) && cityConfidence >= 0.85 &&
        (!requestedHouse || (Number.isFinite(buildingConfidence) && buildingConfidence >= 0.85));
      const overallConfidence = Number.isFinite(confidence) && confidence >= 0.65;
      const locationQuality = overallConfidence || componentConfidence;
      const coordinatesAreValid = isValidCoordinatePair(item?.lon, item?.lat);

      const accepted = (exactBuilding || exactStreet) &&
        country === "br" &&
        streetMatches &&
        (cityMatches || postcodeMatches) &&
        !postcodeConflicts &&
        regionMatches &&
        locationQuality &&
        coordinatesAreValid;

      return {
        item,
        accepted,
        reason: !(exactBuilding || exactStreet) ? "result_type_or_house_number_mismatch"
          : country !== "br" ? "country_mismatch"
          : !streetMatches ? "street_mismatch"
          : !(cityMatches || postcodeMatches) ? "city_or_postcode_not_confirmed"
          : postcodeConflicts ? "postcode_mismatch"
          : !regionMatches ? "state_mismatch"
          : !locationQuality ? "low_address_component_confidence"
          : !coordinatesAreValid ? "invalid_coordinates"
          : null,
        diagnostics: {
          result_type: type || null,
          confidence: Number.isFinite(confidence) ? confidence : null,
          street_confidence: Number.isFinite(streetConfidence) ? streetConfidence : null,
          city_confidence: Number.isFinite(cityConfidence) ? cityConfidence : null,
          building_confidence: Number.isFinite(buildingConfidence) ? buildingConfidence : null,
          street_matches: streetMatches,
          city_matches: cityMatches,
          postcode_matches: postcodeMatches,
          house_number_matches: Boolean(requestedHouse && returnedHouse === requestedHouse),
          has_street_field: Boolean(item?.street),
          has_address_line1: Boolean(item?.address_line1),
        },
      };
    });

    const candidate = evaluated.find((entry: any) => entry.accepted)?.item;
    if (candidate) {
      console.info("Geoapify geocoding candidate accepted:", {
        ...context,
        search: request.label,
        result_type: candidate.result_type || null,
        confidence: candidate.rank?.confidence ?? null,
        street_confidence: candidate.rank?.confidence_street_level ?? null,
        building_confidence: candidate.rank?.confidence_building_level ?? null,
        match_type: candidate.rank?.match_type || null,
      });
      return [Number(candidate.lon), Number(candidate.lat)];
    }

    if (evaluated.length) {
      console.warn("Geoapify candidates did not satisfy address verification:", {
        ...context,
        search: request.label,
        candidates: evaluated.slice(0, 5).map((entry: any) => ({
          ...entry.diagnostics,
          reason: entry.reason,
        })),
      });
    }
  }

  console.warn("Geoapify could not confirm the requested street/building; trying validated OpenRouteService geocoding:", context);
  return null;
}

function orsFeatureMatches(item: any, structured: ReturnType<typeof parseStructuredAddress>): boolean {
  const properties = item?.properties || {};
  const layer = String(properties.layer || "").toLowerCase();
  const point = item?.geometry?.coordinates;
  const hasHouseNumber = Boolean(structured.houseNumber);
  const layerMatches = hasHouseNumber ? layer === "address" : (layer === "address" || layer === "street");
  if (!layerMatches || !Array.isArray(point) || point.length < 2 ||
      !isValidCoordinatePair(point[0], point[1])) return false;

  const returnedHouse = cleanAddress(properties.housenumber).toLowerCase();
  if (hasHouseNumber && returnedHouse !== structured.houseNumber.toLowerCase()) return false;

  const returnedStreet = properties.street || properties.name || properties.label;
  if (!geocodeStreetMatches({ street: returnedStreet }, structured.street)) return false;

  const returnedCity = normalizeGeocodeLabel(properties.locality || properties.city || properties.localadmin);
  const requestedCity = normalizeGeocodeLabel(structured.locality);
  const returnedPostcode = cleanAddress(properties.postalcode || properties.postcode).replace(/\D/g, "");
  const requestedPostcode = cleanAddress(structured.postalcode).replace(/\D/g, "");
  const cityMatches = Boolean(requestedCity && returnedCity && requestedCity === returnedCity);
  const postcodeMatches = Boolean(requestedPostcode && returnedPostcode === requestedPostcode);
  if (!(cityMatches || postcodeMatches)) return false;
  if (requestedPostcode && returnedPostcode && !postcodeMatches) return false;

  const country = String(properties.country_a || properties.country_code || "").toUpperCase();
  if (country && country !== "BR") return false;
  if (!country && !/\b(brasil|brazil)\b/i.test(String(properties.country || ""))) return false;

  const requestedRegion = normalizeBrazilianRegion(structured.region);
  const returnedRegion = normalizeBrazilianRegion(properties.region_a || properties.region || properties.state);
  if (requestedRegion && returnedRegion && requestedRegion !== returnedRegion) return false;

  const confidence = Number(properties.confidence);
  if (Number.isFinite(confidence) && confidence < 0.5) return false;
  return true;
}

async function geocode(
  address: string,
  apiKey: string,
  settings: Record<string, unknown>,
  context: { role: string; orderId?: string },
): Promise<[number, number]> {
  const structured = parseStructuredAddress(address, settings, context.role === "store_origin");
  if (!structured.street || !structured.locality) {
    throw new Error("Endereço incompleto para geolocalização. Confira rua e cidade no cadastro do estabelecimento ou do pedido.");
  }
  const cacheKey = geocodeCacheKey(structured);
  const cachedCoordinates = getCachedGeocode(cacheKey);
  if (cachedCoordinates) {
    console.info("Using recently verified geocoding result:", { ...context, cache_hit: true });
    return cachedCoordinates;
  }

  const geoapifyApiKey = Deno.env.get("GEOAPIFY_API_KEY");
  if (geoapifyApiKey) {
    const coordinates = await geoapifyGeocode(address, geoapifyApiKey, settings, context);
    if (coordinates) {
      setCachedGeocode(cacheKey, coordinates);
      return coordinates;
    }
  }

  let structuredFeatures: any[] = [];
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

  const textQuery = new URLSearchParams({
    text: withRegion(address, settings),
    "boundary.country": "BR",
    layers: "address,street",
    size: "5",
  });

  const searches = [
    { label: "structured", url: ORS_BASE + "/pelias/v1/search/structured?" + structuredQuery.toString() },
    { label: "text", url: ORS_BASE + "/pelias/v1/search?" + textQuery.toString() },
  ];

  for (const search of searches) {
    try {
      const response = await fetch(search.url, {
        headers: { Authorization: apiKey },
        signal: AbortSignal.timeout(9000),
      });
      const payload = await response.json().catch(() => ({}));
      if (!response.ok) {
        console.warn("OpenRouteService geocoding request failed:", {
          ...context, search: search.label, status: response.status,
          detail: providerErrorDetail(payload) || null,
        });
        continue;
      }

      const features = Array.isArray(payload?.features) ? payload.features : [];
      if (search.label === "structured") structuredFeatures = features;
      const candidate = features.find((item: any) => orsFeatureMatches(item, structured));
      if (candidate) {
        const properties = candidate.properties || {};
        console.info("OpenRouteService geocoding candidate accepted:", {
          ...context,
          search: search.label,
          layer: properties.layer || null,
          confidence: properties.confidence ?? null,
          match_type: properties.match_type || null,
          exact_house_number: Boolean(structured.houseNumber),
          street_verified: true,
          locality_verified: true,
        });
        const [longitude, latitude] = candidate.geometry.coordinates;
        const coordinates: [number, number] = [Number(longitude), Number(latitude)];
        setCachedGeocode(cacheKey, coordinates);
        return coordinates;
      }

      if (features.length) {
        console.warn("OpenRouteService candidates rejected by address verification:", {
          ...context,
          search: search.label,
          candidate_count: features.length,
          candidate_layers: features.slice(0, 5).map((item: any) => item?.properties?.layer || null),
          candidate_confidences: features.slice(0, 5).map((item: any) => item?.properties?.confidence ?? null),
        });
      }
    } catch (error) {
      console.warn("OpenRouteService geocoding transport failure:", {
        ...context,
        search: search.label,
        detail: error instanceof Error ? error.message.slice(0, 120) : "unknown error",
      });
    }
  }

  const fallback = structuredFeatures[0]?.properties || {};
  console.warn("No provider returned an address-level match; refusing approximate coordinates:", {
    ...context,
    has_street: Boolean(structured.street),
    has_house_number: Boolean(structured.houseNumber),
    has_neighbourhood: Boolean(structured.neighbourhood),
    has_locality: Boolean(structured.locality),
    has_region: Boolean(structured.region),
    has_postalcode: Boolean(structured.postalcode),
    fallback_layer: fallback.layer || null,
    fallback_accuracy: fallback.accuracy || null,
    fallback_match_type: fallback.match_type || null,
  });
  throw new Error("Não foi possível confirmar a rua e o número deste endereço nos serviços de mapas. Confira o cadastro. Nenhum centro de cidade ou ponto aproximado foi utilizado.");
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
        body: JSON.stringify({
          locations: coordinates, metrics: ["distance"], units: "m", resolve_locations: true,
        }),
      });
      const distances = matrix?.distances;
      if (!Array.isArray(distances) || distances.length !== coordinates.length) {
        return respond(502, { error: "O serviço de mapas não retornou uma matriz de distâncias válida." });
      }
      const resolvedPoints = [...(matrix?.sources || []), ...(matrix?.destinations || [])];
      const excessiveSnap = resolvedPoints.find((point: any) =>
        Number.isFinite(Number(point?.snapped_distance)) && Number(point.snapped_distance) > 250
      );
      if (excessiveSnap) {
        return respond(422, { error: "Um ou mais endereços ficaram distantes demais da via reconhecida pelo mapa. Confira os endereços antes de otimizar a rota." });
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
      const resolvedDestinations = Array.isArray(matrix?.destinations) ? matrix.destinations : [];
      const excessiveSnap = [resolvedOrigin, ...resolvedDestinations].find((point: any) =>
        Number.isFinite(Number(point?.snapped_distance)) && Number(point.snapped_distance) > 250
      );
      if (excessiveSnap) {
        return respond(422, { error: "O mapa posicionou um endereço a mais de 250 metros da via reconhecida. A distância e o pagamento não foram registrados. Confira o endereço." });
      }

      const results: Record<string, unknown>[] = [];
      for (let index = 0; index < orderIds.length; index++) {
        const rawMeters = distances[index];
        const meters = rawMeters == null ? NaN : Number(rawMeters);
        if (!Number.isFinite(meters) || meters <= 0) {
          const resolvedDestination = matrix?.destinations?.[index] || null;
          console.warn("OpenRouteService returned no road distance for delivery:", {
            order_id: orderIds[index],
            origin_snap_distance: resolvedOrigin?.snapped_distance ?? null,
            destination_snap_distance: resolvedDestination?.snapped_distance ?? null,
          });
          results.push({
            order_id: orderIds[index],
            success: false,
            error: "O mapa localizou os endereços, mas não encontrou uma ligação viária válida entre eles. Confira os endereços ou tente novamente.",
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
