-- VORTEX FOOD: faixas de remuneração por distância e cálculo de rota no servidor.
-- Mantém a estrutura legada JSONB para compatibilidade; em modo per_km ela passa
-- a armazenar objetos {kmStart, kmEnd, amount}. Valores históricos já congelados não são reescritos.
BEGIN;

CREATE OR REPLACE FUNCTION public.rpc_save_delivery_courier_payment_rules(
  p_store_id uuid,
  p_mode text,
  p_fixed_amount numeric,
  p_neighborhood_rates jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $function$
DECLARE
  v_rates jsonb := COALESCE(p_neighborhood_rates,'[]'::jsonb);
  v_item jsonb;
  v_count integer;
  v_first numeric;
  v_gap boolean;
BEGIN
  IF auth.uid() IS NULL OR NOT public.vortex_user_has_permission(p_store_id,'settings.manage') THEN
    RAISE EXCEPTION 'Seu perfil não pode alterar a remuneração dos entregadores.';
  END IF;
  IF p_mode IS NULL OR p_mode NOT IN ('fixed','neighborhood','per_km')
     OR jsonb_typeof(v_rates)<>'array'
     OR jsonb_array_length(v_rates)>200
     OR (p_fixed_amount IS NOT NULL AND (p_fixed_amount<0 OR p_fixed_amount>10000)) THEN
    RAISE EXCEPTION 'Configuração de remuneração inválida.';
  END IF;

  IF p_mode='fixed' AND (p_fixed_amount IS NULL OR p_fixed_amount<=0) THEN
    RAISE EXCEPTION 'Informe um valor fixo válido por entrega.';
  ELSIF p_mode='neighborhood' THEN
    IF jsonb_array_length(v_rates)=0 THEN
      RAISE EXCEPTION 'Cadastre ao menos um bairro e valor para a remuneração.';
    END IF;
    FOR v_item IN SELECT value FROM jsonb_array_elements(v_rates) LOOP
      IF length(trim(COALESCE(v_item->>'name','')))<2
         OR COALESCE(v_item->>'amount','') !~ '^[0-9]{1,8}([.,][0-9]{1,2})?$'
         OR replace(v_item->>'amount',',','.')::numeric<=0
         OR replace(v_item->>'amount',',','.')::numeric>10000 THEN
        RAISE EXCEPTION 'Revise os bairros e valores informados na remuneração.';
      END IF;
    END LOOP;
  ELSIF p_mode='per_km' THEN
    v_count:=jsonb_array_length(v_rates);
    IF v_count=0 THEN
      RAISE EXCEPTION 'Cadastre ao menos uma faixa de quilometragem para remunerar o motoboy.';
    END IF;
    FOR v_item IN SELECT value FROM jsonb_array_elements(v_rates) LOOP
      IF COALESCE(v_item->>'kmStart','') !~ '^[0-9]{1,3}([.][0-9]{1,2})?$'
         OR COALESCE(v_item->>'kmEnd','') !~ '^[0-9]{1,3}([.][0-9]{1,2})?$'
         OR COALESCE(v_item->>'amount','') !~ '^[0-9]{1,8}([.][0-9]{1,2})?$'
         OR (v_item->>'kmStart')::numeric<0
         OR (v_item->>'kmEnd')::numeric<=(v_item->>'kmStart')::numeric
         OR (v_item->>'kmEnd')::numeric>500
         OR (v_item->>'amount')::numeric<=0
         OR (v_item->>'amount')::numeric>10000 THEN
        RAISE EXCEPTION 'Revise os limites e o valor de cada faixa de quilometragem.';
      END IF;
    END LOOP;

    SELECT min((value->>'kmStart')::numeric)
    INTO v_first FROM jsonb_array_elements(v_rates);
    IF v_first<>0 THEN
      RAISE EXCEPTION 'A primeira faixa de remuneração precisa começar em 0 KM.';
    END IF;

    SELECT EXISTS (
      SELECT 1 FROM (
        SELECT (value->>'kmStart')::numeric AS km_start,
               lag((value->>'kmEnd')::numeric) OVER (ORDER BY (value->>'kmStart')::numeric) AS previous_end
        FROM jsonb_array_elements(v_rates)
      ) ordered_ranges
      WHERE previous_end IS NOT NULL AND km_start<>previous_end
    ) INTO v_gap;
    IF v_gap THEN
      RAISE EXCEPTION 'As faixas de remuneração precisam ser contínuas, sem sobreposição ou distância descoberta.';
    END IF;
  END IF;

  INSERT INTO public.vortex_delivery_courier_payment_rules(
    store_id,mode,fixed_amount,neighborhood_rates,updated_by,updated_at
  ) VALUES (
    p_store_id,p_mode,CASE WHEN p_mode='fixed' THEN p_fixed_amount ELSE NULL END,
    v_rates,auth.uid(),now()
  )
  ON CONFLICT (store_id) DO UPDATE SET
    mode=EXCLUDED.mode,
    fixed_amount=EXCLUDED.fixed_amount,
    neighborhood_rates=EXCLUDED.neighborhood_rates,
    updated_by=EXCLUDED.updated_by,
    updated_at=now();

  RETURN jsonb_build_object('success',true,'mode',p_mode,'configured',true);
END;
$function$;

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

  SELECT mode,neighborhood_rates INTO v_mode,v_rates
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
  IF v_match IS NULL THEN
    RAISE EXCEPTION 'A distância de % KM não está coberta pelas faixas de remuneração. Revise as configurações.',v_distance;
  END IF;

  v_amount:=replace(v_match->>'amount',',','.')::numeric;
  UPDATE public.vortex_delivery_route_stops
  SET distance_km=v_distance,
      courier_payment_amount=v_amount,
      courier_payment_rule_label='Faixa de ' || (v_match->>'kmStart') || ' a ' || (v_match->>'kmEnd') || ' km',
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
      'rule_label','Faixa de ' || (v_match->>'kmStart') || ' a ' || (v_match->>'kmEnd') || ' km')
  );
  RETURN jsonb_build_object('success',true,'distance_km',v_distance,'courier_payment_amount',v_amount,
    'rule_label','Faixa de ' || (v_match->>'kmStart') || ' a ' || (v_match->>'kmEnd') || ' km');
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_save_delivery_courier_payment_rules(uuid,text,numeric,jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.rpc_save_delivery_courier_payment_rules(uuid,text,numeric,jsonb) TO authenticated;
REVOKE ALL ON FUNCTION public.rpc_set_delivery_stop_distance(uuid,uuid,text,numeric) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.rpc_set_delivery_stop_distance(uuid,uuid,text,numeric) TO authenticated;

COMMIT;
