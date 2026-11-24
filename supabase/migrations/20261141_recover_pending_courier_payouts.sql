-- Recupera remunerações ausentes de entregas concluídas usando a faixa atual por KM.
-- Não altera lançamentos pagos e não inventa valores quando falta distância/faixa.
BEGIN;

CREATE OR REPLACE FUNCTION public.rpc_recover_pending_delivery_courier_payouts(
  p_store_id uuid,
  p_start_date date,
  p_end_date date
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $function$
DECLARE
  v_mode text;
  v_ranges jsonb := '[]'::jsonb;
  v_row record;
  v_band jsonb;
  v_distance numeric(8,2);
  v_amount numeric(12,2);
  v_rule_label text;
  v_recovered integer := 0;
  v_without_distance integer := 0;
  v_without_band integer := 0;
  v_updated integer := 0;
BEGIN
  IF auth.uid() IS NULL
     OR NOT public.vortex_user_has_permission(p_store_id,'delivery.dispatch_manage') THEN
    RAISE EXCEPTION 'Seu perfil não pode recuperar remunerações dos motoboys.';
  END IF;

  IF p_start_date IS NULL OR p_end_date IS NULL
     OR p_start_date > p_end_date OR p_end_date-p_start_date > 366 THEN
    RAISE EXCEPTION 'Período inválido. Selecione no máximo 12 meses por vez.';
  END IF;

  SELECT mode,distance_ranges
    INTO v_mode,v_ranges
  FROM public.vortex_delivery_courier_payment_rules
  WHERE store_id=p_store_id;

  IF jsonb_typeof(COALESCE(v_ranges,'[]'::jsonb)) <> 'array' THEN
    v_ranges := '[]'::jsonb;
  END IF;

  FOR v_row IN
    SELECT l.stop_id,
           l.distance_km AS ledger_distance_km,
           s.distance_km AS stop_distance_km,
           s.courier_payment_amount AS stop_payment_amount,
           s.courier_payment_rule_label AS stop_rule_label
    FROM public.vortex_delivery_courier_ledger l
    JOIN public.vortex_delivery_route_stops s
      ON s.store_id=l.store_id AND s.id=l.stop_id
    WHERE l.store_id=p_store_id
      AND l.payout_status='pending'
      AND l.amount IS NULL
      AND s.status='delivered'
      AND l.delivered_at >= (p_start_date::timestamp AT TIME ZONE 'America/Sao_Paulo')
      AND l.delivered_at < ((p_end_date+1)::timestamp AT TIME ZONE 'America/Sao_Paulo')
    ORDER BY l.delivered_at,l.stop_id
    FOR UPDATE OF l,s SKIP LOCKED
  LOOP
    v_distance := round(COALESCE(v_row.ledger_distance_km,v_row.stop_distance_km),2);

    -- Se a parada já possui remuneração congelada, restaura exatamente esse
    -- valor histórico, sem recalculá-lo com as regras atuais.
    IF v_row.stop_payment_amount IS NOT NULL THEN
      v_amount := v_row.stop_payment_amount;
      v_rule_label := COALESCE(v_row.stop_rule_label,'Remuneração registrada na entrega');
    ELSE
      IF v_distance IS NULL OR v_distance <= 0 OR v_distance > 500 THEN
        v_without_distance := v_without_distance + 1;
        CONTINUE;
      END IF;

      IF v_mode <> 'per_km' OR jsonb_array_length(v_ranges)=0 THEN
        v_without_band := v_without_band + 1;
        CONTINUE;
      END IF;

      v_band := NULL;
      SELECT item.value
        INTO v_band
      FROM jsonb_array_elements(v_ranges) AS item(value)
      WHERE v_distance > (item.value->>'kmStart')::numeric
        AND v_distance <= (item.value->>'kmEnd')::numeric
      ORDER BY (item.value->>'kmStart')::numeric DESC
      LIMIT 1;

      IF v_band IS NULL THEN
        v_without_band := v_without_band + 1;
        CONTINUE;
      END IF;

      v_amount := replace(v_band->>'amount',',','.')::numeric;
      IF v_amount <= 0 OR v_amount > 10000 THEN
        v_without_band := v_without_band + 1;
        CONTINUE;
      END IF;

      v_rule_label := CASE
        WHEN (v_band->>'kmStart')::numeric=0
          THEN 'Até ' || (v_band->>'kmEnd') || ' km'
        ELSE 'Acima de ' || (v_band->>'kmStart') || ' até ' || (v_band->>'kmEnd') || ' km'
      END;
    END IF;

    UPDATE public.vortex_delivery_courier_ledger
    SET amount=v_amount,
        rule_label=v_rule_label,
        distance_km=v_distance,
        updated_at=now()
    WHERE store_id=p_store_id
      AND stop_id=v_row.stop_id
      AND payout_status='pending'
      AND amount IS NULL;

    GET DIAGNOSTICS v_updated = ROW_COUNT;

    IF v_updated=1 THEN
      -- Mantém o registro operacional coerente. O trigger financeiro existente
      -- sincroniza a parada, sem sobrescrever lançamentos já pagos.
      UPDATE public.vortex_delivery_route_stops
      SET distance_km=COALESCE(distance_km,v_distance),
          courier_payment_amount=CASE WHEN courier_payment_amount IS NULL THEN v_amount ELSE courier_payment_amount END,
          courier_payment_rule_label=CASE WHEN courier_payment_rule_label IS NULL THEN v_rule_label ELSE courier_payment_rule_label END,
          updated_at=now()
      WHERE store_id=p_store_id
        AND id=v_row.stop_id
        AND status='delivered'
        AND courier_payment_amount IS NULL;

      v_recovered := v_recovered + 1;
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'success',true,
    'recovered',v_recovered,
    'without_distance',v_without_distance,
    'without_matching_band',v_without_band
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_recover_pending_delivery_courier_payouts(uuid,date,date) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.rpc_recover_pending_delivery_courier_payouts(uuid,date,date) TO authenticated;

COMMIT;
