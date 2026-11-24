-- VORTEX FOOD: registra distância viária mesmo quando a remuneração não tem faixa correspondente.
-- A rota continua bloqueada até que todas as remunerações por KM estejam definidas.
BEGIN;

CREATE OR REPLACE FUNCTION public.rpc_set_delivery_stop_distance(
  p_store_id uuid,p_route_id uuid,p_order_id text,p_distance_km numeric
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $function$
DECLARE
  v_route public.vortex_delivery_routes%ROWTYPE;
  v_mode text;
  v_rates jsonb;
  v_match jsonb;
  v_amount numeric(12,2);
  v_stop_id uuid;
  v_distance numeric(8,2);
BEGIN
  IF auth.uid() IS NULL OR NOT public.vortex_user_has_permission(p_store_id,'delivery.dispatch_manage') THEN
    RAISE EXCEPTION 'Seu perfil não pode calcular a distância desta entrega.';
  END IF;
  IF p_distance_km IS NULL OR p_distance_km<=0 OR p_distance_km>500 THEN
    RAISE EXCEPTION 'A distância calculada precisa ser maior que zero e de até 500 km.';
  END IF;
  v_distance:=round(p_distance_km,2);

  SELECT * INTO v_route FROM public.vortex_delivery_routes
  WHERE store_id=p_store_id AND id=p_route_id AND status IN ('assigned','in_route')
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'A rota não está ativa.'; END IF;

  SELECT mode,distance_ranges INTO v_mode,v_rates
  FROM public.vortex_delivery_courier_payment_rules
  WHERE store_id=p_store_id;
  IF NOT FOUND OR v_mode<>'per_km' THEN
    RAISE EXCEPTION 'A remuneração por faixas de quilometragem não está configurada neste estabelecimento.';
  END IF;

  SELECT value INTO v_match
  FROM jsonb_array_elements(COALESCE(v_rates,'[]'::jsonb)) AS ranges(value)
  WHERE v_distance>(value->>'kmStart')::numeric
    AND v_distance<=(value->>'kmEnd')::numeric
  ORDER BY (value->>'kmStart')::numeric DESC
  LIMIT 1;
  IF v_match IS NULL AND v_distance=0 THEN
    SELECT value INTO v_match
    FROM jsonb_array_elements(COALESCE(v_rates,'[]'::jsonb)) AS ranges(value)
    WHERE (value->>'kmStart')::numeric=0
    ORDER BY (value->>'kmEnd')::numeric
    LIMIT 1;
  END IF;
  -- A distância é um dado independente da remuneração. Se nenhuma faixa
  -- cobrir o percurso, registra a distância e mantém o repasse pendente.
  IF v_match IS NOT NULL THEN
    v_amount:=replace(v_match->>'amount',',','.')::numeric;
  ELSE
    v_amount:=NULL;
  END IF;
  UPDATE public.vortex_delivery_route_stops
  SET distance_km=v_distance,
      courier_payment_amount=v_amount,
      courier_payment_rule_label=CASE
        WHEN v_match IS NULL THEN NULL
        WHEN (v_match->>'kmStart')::numeric=0 THEN 'Até ' || (v_match->>'kmEnd') || ' km'
        ELSE 'Acima de ' || (v_match->>'kmStart') || ' até ' || (v_match->>'kmEnd') || ' km'
      END,
      updated_at=now()
  WHERE store_id=p_store_id AND route_id=p_route_id
    AND order_id=p_order_id AND status IN ('assigned','in_progress','occurrence')
  RETURNING id INTO v_stop_id;
  IF v_stop_id IS NULL THEN RAISE EXCEPTION 'Entrega ativa não encontrada nesta rota.'; END IF;

  UPDATE public.vortex_delivery_routes
  SET route_version=route_version+1,updated_at=now()
  WHERE store_id=p_store_id AND id=p_route_id;

  INSERT INTO public.vortex_delivery_route_events(
    store_id,route_id,stop_id,order_id,actor_user_id,event_type,details
  ) VALUES (
    p_store_id,p_route_id,v_stop_id,p_order_id,auth.uid(),'delivery_distance_updated',
    jsonb_build_object('distance_km',v_distance,'courier_payment_amount',v_amount,
      'payment_pending',v_match IS NULL,
      'rule_label',CASE WHEN v_match IS NULL THEN NULL
        WHEN (v_match->>'kmStart')::numeric=0 THEN 'Até ' || (v_match->>'kmEnd') || ' km'
        ELSE 'Acima de ' || (v_match->>'kmStart') || ' até ' || (v_match->>'kmEnd') || ' km' END)
  );
  RETURN jsonb_build_object('success',true,'distance_saved',true,'distance_km',v_distance,
    'courier_payment_amount',v_amount,'payment_pending',v_match IS NULL,
    'rule_label',CASE WHEN v_match IS NULL THEN NULL
      WHEN (v_match->>'kmStart')::numeric=0 THEN 'Até ' || (v_match->>'kmEnd') || ' km'
      ELSE 'Acima de ' || (v_match->>'kmStart') || ' até ' || (v_match->>'kmEnd') || ' km' END);
END;
$function$;

COMMIT;
