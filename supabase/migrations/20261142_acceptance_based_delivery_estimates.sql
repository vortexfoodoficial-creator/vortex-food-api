BEGIN;

-- O aceite do pedido e a previsão ficam registrados no próprio pedido.
-- Pedidos antigos permanecem NULL: não inferimos horários históricos.
ALTER TABLE public.vortex_kds_orders
  ADD COLUMN IF NOT EXISTS accepted_at timestamptz,
  ADD COLUMN IF NOT EXISTS promised_delivery_at timestamptz;

CREATE INDEX IF NOT EXISTS vortex_kds_orders_store_accepted_at_idx
  ON public.vortex_kds_orders(store_id,accepted_at DESC)
  WHERE accepted_at IS NOT NULL;

-- A etapa "preparing" é a confirmação de aceite feita pela loja no KDS.
-- O prazo configurado é congelado no instante do aceite.
CREATE OR REPLACE FUNCTION public.rpc_update_kds_order_status(
  p_store_id uuid,
  p_order_id text,
  p_status text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $function$
DECLARE
  v_order public.vortex_kds_orders%ROWTYPE;
  v_delivery_minutes integer;
  v_accepted_at timestamptz;
  v_promised_delivery_at timestamptz;
BEGIN
  IF auth.uid() IS NULL OR NOT public.vortex_user_has_store_access(p_store_id) THEN
    RAISE EXCEPTION 'Acesso não autorizado.';
  END IF;

  IF p_status NOT IN ('preparing','ready','finished') THEN
    RAISE EXCEPTION 'Etapa de pedido inválida.';
  END IF;

  SELECT * INTO v_order
  FROM public.vortex_kds_orders
  WHERE store_id=p_store_id AND id=p_order_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Pedido não encontrado nesta loja.';
  END IF;

  IF p_status='finished' AND COALESCE(v_order.origin,'') ILIKE '%Delivery%' THEN
    RAISE EXCEPTION 'Pedidos de delivery precisam ser finalizados pelo fluxo de confirmação de entrega.';
  ELSIF p_status='finished' AND COALESCE(v_order.origin,'') ILIKE '%Mesa%' THEN
    IF NOT public.vortex_user_has_permission(p_store_id,'tables.close') THEN
      RAISE EXCEPTION 'Seu perfil não pode fechar esta comanda.';
    END IF;
  ELSIF NOT public.vortex_user_has_permission(p_store_id,'kds.update_status') THEN
    RAISE EXCEPTION 'Seu perfil não pode atualizar o preparo.';
  END IF;

  v_accepted_at := v_order.accepted_at;
  v_promised_delivery_at := v_order.promised_delivery_at;

  IF p_status='preparing'
     AND COALESCE(v_order.origin,'') ILIKE '%Delivery%'
     AND v_order.status IN ('new','received')
     AND v_order.accepted_at IS NULL THEN
    v_accepted_at := now();

    SELECT CASE
      WHEN trim(COALESCE(data->>'estDeliveryTime','')) ~ '^[0-9]{1,4}$'
      THEN trim(data->>'estDeliveryTime')::integer
      ELSE NULL
    END
    INTO v_delivery_minutes
    FROM public.vortex_store_documents
    WHERE store_id=p_store_id AND document_key='settings';

    IF v_delivery_minutes BETWEEN 1 AND 1440 THEN
      v_promised_delivery_at := v_accepted_at + make_interval(mins => v_delivery_minutes);
    END IF;
  END IF;

  UPDATE public.vortex_kds_orders
  SET status=p_status,
      accepted_at=v_accepted_at,
      promised_delivery_at=v_promised_delivery_at,
      updated_at=now()
  WHERE store_id=p_store_id AND id=p_order_id;

  -- Se a parada já foi criada antes do aceite, propaga a previsão uma única vez.
  IF v_promised_delivery_at IS NOT NULL THEN
    UPDATE public.vortex_delivery_route_stops
    SET promised_delivery_at=v_promised_delivery_at,
        updated_at=now()
    WHERE store_id=p_store_id AND order_id=p_order_id
      AND status IN ('assigned','in_progress','occurrence')
      AND promised_delivery_at IS NULL;
  END IF;

  RETURN jsonb_build_object(
    'success',true,
    'status',p_status,
    'accepted_at',v_accepted_at,
    'promised_delivery_at',v_promised_delivery_at
  );
END;
$function$;

-- Rotas criadas depois do aceite recebem automaticamente a previsão congelada.
CREATE OR REPLACE FUNCTION public.vortex_copy_order_delivery_estimate_to_stop()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $function$
BEGIN
  IF NEW.promised_delivery_at IS NULL THEN
    SELECT o.promised_delivery_at
    INTO NEW.promised_delivery_at
    FROM public.vortex_kds_orders o
    WHERE o.store_id=NEW.store_id AND o.id=NEW.order_id;
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_copy_order_delivery_estimate_to_stop
  ON public.vortex_delivery_route_stops;

CREATE TRIGGER trg_copy_order_delivery_estimate_to_stop
BEFORE INSERT OR UPDATE OF order_id
ON public.vortex_delivery_route_stops
FOR EACH ROW
EXECUTE FUNCTION public.vortex_copy_order_delivery_estimate_to_stop();

-- Recupera somente remunerações ainda NULL em paradas ativas de uma rota não iniciada.
-- Nunca altera valores já congelados, pagamentos quitados ou histórico concluído.
CREATE OR REPLACE FUNCTION public.rpc_recalculate_pending_delivery_courier_stop_payments(
  p_store_id uuid,
  p_route_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $function$
DECLARE
  v_mode text;
  v_fixed numeric(12,2);
  v_neighborhood_rates jsonb;
  v_distance_ranges jsonb;
  v_stop record;
  v_match jsonb;
  v_amount numeric(12,2);
  v_label text;
  v_updated integer := 0;
  v_pending_ids text[];
BEGIN
  IF auth.uid() IS NULL
     OR NOT public.vortex_user_has_permission(p_store_id,'delivery.dispatch_manage') THEN
    RAISE EXCEPTION 'Seu perfil não pode recalcular a remuneração das entregas.';
  END IF;

  PERFORM 1
  FROM public.vortex_delivery_routes r
  WHERE r.store_id=p_store_id AND r.id=p_route_id AND r.status='assigned'
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'A rota não existe ou já foi iniciada.';
  END IF;

  SELECT mode,fixed_amount,neighborhood_rates,distance_ranges
  INTO v_mode,v_fixed,v_neighborhood_rates,v_distance_ranges
  FROM public.vortex_delivery_courier_payment_rules
  WHERE store_id=p_store_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Configure a remuneração dos motoboys antes de recalcular.';
  END IF;

  FOR v_stop IN
    SELECT s.id,s.order_id,s.distance_km,o.address
    FROM public.vortex_delivery_route_stops s
    JOIN public.vortex_kds_orders o
      ON o.store_id=s.store_id AND o.id=s.order_id
    WHERE s.store_id=p_store_id AND s.route_id=p_route_id
      AND s.status IN ('assigned','in_progress','occurrence')
      AND s.courier_payment_amount IS NULL
      AND NOT EXISTS (
        SELECT 1 FROM public.vortex_delivery_courier_ledger l
        WHERE l.store_id=s.store_id AND l.stop_id=s.id AND l.payout_status='paid'
      )
    ORDER BY s.sequence_number
    FOR UPDATE OF s
  LOOP
    v_amount := NULL;
    v_label := NULL;
    v_match := NULL;

    IF v_mode='fixed' THEN
      v_amount := v_fixed;
      v_label := CASE WHEN v_fixed IS NULL THEN NULL ELSE 'Valor fixo por entrega' END;
    ELSIF v_mode='neighborhood' THEN
      SELECT item.value INTO v_match
      FROM jsonb_array_elements(COALESCE(v_neighborhood_rates,'[]'::jsonb)) AS item(value)
      WHERE length(trim(COALESCE(item.value->>'name','')))>=2
        AND position(lower(trim(item.value->>'name')) in lower(COALESCE(v_stop.address,'')))>0
      ORDER BY length(trim(item.value->>'name')) DESC
      LIMIT 1;

      IF v_match IS NOT NULL THEN
        v_amount := replace(v_match->>'amount',',','.')::numeric;
        v_label := 'Bairro: ' || trim(v_match->>'name');
      END IF;
    ELSIF v_mode='per_km' AND v_stop.distance_km IS NOT NULL THEN
      SELECT item.value INTO v_match
      FROM jsonb_array_elements(COALESCE(v_distance_ranges,'[]'::jsonb)) AS item(value)
      WHERE v_stop.distance_km > (item.value->>'kmStart')::numeric
        AND v_stop.distance_km <= (item.value->>'kmEnd')::numeric
      ORDER BY (item.value->>'kmStart')::numeric DESC
      LIMIT 1;

      IF v_match IS NOT NULL THEN
        v_amount := replace(v_match->>'amount',',','.')::numeric;
        v_label := CASE WHEN (v_match->>'kmStart')::numeric=0
          THEN 'Até ' || (v_match->>'kmEnd') || ' km'
          ELSE 'Acima de ' || (v_match->>'kmStart') || ' até ' || (v_match->>'kmEnd') || ' km'
        END;
      END IF;
    END IF;

    IF v_amount IS NOT NULL AND v_amount >= 0 THEN
      UPDATE public.vortex_delivery_route_stops
      SET courier_payment_amount=v_amount,
          courier_payment_rule_label=v_label,
          updated_at=now()
      WHERE store_id=p_store_id AND id=v_stop.id
        AND courier_payment_amount IS NULL;
      IF FOUND THEN v_updated := v_updated + 1; END IF;
    END IF;
  END LOOP;

  SELECT COALESCE(array_agg(s.order_id ORDER BY s.sequence_number),ARRAY[]::text[])
  INTO v_pending_ids
  FROM public.vortex_delivery_route_stops s
  WHERE s.store_id=p_store_id AND s.route_id=p_route_id
    AND s.status IN ('assigned','in_progress','occurrence')
    AND s.courier_payment_amount IS NULL
    AND NOT EXISTS (
      SELECT 1 FROM public.vortex_delivery_courier_ledger l
      WHERE l.store_id=s.store_id AND l.stop_id=s.id AND l.payout_status='paid'
    );

  IF v_updated > 0 THEN
    UPDATE public.vortex_delivery_routes
    SET route_version=route_version+1,updated_at=now()
    WHERE store_id=p_store_id AND id=p_route_id;
  END IF;

  RETURN jsonb_build_object(
    'success',true,
    'updated_count',v_updated,
    'pending_order_ids',to_jsonb(v_pending_ids),
    'pending_count',cardinality(v_pending_ids)
  );
END;
$function$;

-- A rota só pode sair quando a remuneração estiver definida em qualquer modalidade.
-- No modo por quilômetro, a distância real também é obrigatória.
CREATE OR REPLACE FUNCTION public.vortex_require_courier_distance_before_route_start()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $function$
DECLARE
  v_mode text;
BEGIN
  IF OLD.status='assigned' AND NEW.status='in_route' THEN
    SELECT mode INTO v_mode
    FROM public.vortex_delivery_courier_payment_rules
    WHERE store_id=NEW.store_id;

    IF v_mode IS NULL OR v_mode NOT IN ('fixed','per_km','neighborhood') THEN
      RAISE EXCEPTION 'Não é possível iniciar a rota: configure a remuneração dos motoboys.';
    END IF;

    IF EXISTS (
      SELECT 1
      FROM public.vortex_delivery_route_stops s
      WHERE s.store_id=NEW.store_id
        AND s.route_id=NEW.id
        AND s.status IN ('assigned','in_progress','occurrence')
        AND (
          s.courier_payment_amount IS NULL
          OR (v_mode='per_km' AND s.distance_km IS NULL)
        )
    ) THEN
      RAISE EXCEPTION 'Não é possível iniciar a rota: ainda existem entregas sem remuneração calculada ou, no modo por quilômetro, sem distância real. Confira as regras e os endereços.';
    END IF;
  END IF;
  RETURN NEW;
END;
$function$;

REVOKE ALL ON FUNCTION public.vortex_require_courier_distance_before_route_start() FROM PUBLIC,anon,authenticated;

REVOKE ALL ON FUNCTION public.vortex_copy_order_delivery_estimate_to_stop() FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.rpc_recalculate_pending_delivery_courier_stop_payments(uuid,uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.rpc_recalculate_pending_delivery_courier_stop_payments(uuid,uuid) TO authenticated;

COMMIT;
