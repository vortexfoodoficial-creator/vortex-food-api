-- VORTEX FOOD: histórico por data e remuneração individual dos entregadores.
-- Migração aditiva: preserva rotas/pedidos existentes; valores antigos permanecem NULL
-- quando não há informação histórica confiável para reconstruí-los.
-- Revisar e aplicar manualmente no Supabase.

BEGIN;

ALTER TABLE public.vortex_delivery_route_stops
  ADD COLUMN IF NOT EXISTS delivered_by_user_id uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS distance_km numeric(8,2),
  ADD COLUMN IF NOT EXISTS courier_payment_amount numeric(12,2),
  ADD COLUMN IF NOT EXISTS courier_payment_rule_label text;

ALTER TABLE public.vortex_delivery_route_stops
  ADD CONSTRAINT vortex_delivery_route_stops_distance_km_check CHECK (distance_km IS NULL OR distance_km BETWEEN 0 AND 500) NOT VALID;

ALTER TABLE public.vortex_delivery_route_stops
  VALIDATE CONSTRAINT vortex_delivery_route_stops_distance_km_check;

ALTER TABLE public.vortex_delivery_route_stops
  ADD CONSTRAINT vortex_delivery_route_stops_courier_payment_amount_check
  CHECK (courier_payment_amount IS NULL OR courier_payment_amount >= 0)
  NOT VALID;

ALTER TABLE public.vortex_delivery_route_stops
  VALIDATE CONSTRAINT vortex_delivery_route_stops_courier_payment_amount_check;

-- Recupera a autoria histórica quando o próprio motoboy confirmou o código
-- e o evento antigo registrou a conta autenticada como ator. Não inventa valores.
UPDATE public.vortex_delivery_route_stops s
SET delivered_by_user_id=e.actor_user_id
FROM public.vortex_delivery_route_events e
JOIN public.vortex_store_members m
  ON m.store_id=e.store_id AND m.user_id=e.actor_user_id AND m.profile_key='delivery'
WHERE s.store_id=e.store_id AND s.route_id=e.route_id
  AND s.order_id=e.order_id AND s.status='delivered'
  AND s.delivered_by_user_id IS NULL
  AND e.event_type='delivery_confirmed';

CREATE INDEX IF NOT EXISTS vortex_delivery_route_stops_delivered_at_idx
  ON public.vortex_delivery_route_stops(store_id,delivered_at DESC)
  WHERE status='delivered';

CREATE INDEX IF NOT EXISTS vortex_delivery_route_stops_delivered_by_idx
  ON public.vortex_delivery_route_stops(store_id,delivered_by_user_id,delivered_at DESC)
  WHERE status='delivered';

CREATE TABLE IF NOT EXISTS public.vortex_delivery_courier_payment_rules (
  store_id uuid PRIMARY KEY REFERENCES public.vortex_stores(id) ON DELETE CASCADE,
  mode text NOT NULL DEFAULT 'fixed' CHECK (mode IN ('fixed','neighborhood','per_km')),
  fixed_amount numeric(12,2),
  neighborhood_rates jsonb NOT NULL DEFAULT '[]'::jsonb,
  updated_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT vortex_delivery_courier_payment_rules_fixed_amount_check
    CHECK (fixed_amount IS NULL OR fixed_amount BETWEEN 0 AND 10000),
  CONSTRAINT vortex_delivery_courier_payment_rules_neighborhood_array_check
    CHECK (jsonb_typeof(neighborhood_rates)='array')
);

ALTER TABLE public.vortex_delivery_courier_payment_rules ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.vortex_delivery_courier_payment_rules FROM PUBLIC,anon,authenticated;

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
BEGIN
  IF auth.uid() IS NULL OR NOT public.vortex_user_has_permission(p_store_id,'settings.manage') THEN
    RAISE EXCEPTION 'Seu perfil não pode alterar a remuneração dos entregadores.';
  END IF;
  IF p_mode NOT IN ('fixed','neighborhood','per_km')
     OR jsonb_typeof(v_rates)<>'array'
     OR jsonb_array_length(v_rates)>200
     OR (p_fixed_amount IS NOT NULL AND (p_fixed_amount<0 OR p_fixed_amount>10000)) THEN
    RAISE EXCEPTION 'Configuração de remuneração inválida.';
  END IF;
  IF p_mode IN ('fixed','per_km') AND p_fixed_amount IS NULL THEN
    RAISE EXCEPTION 'Informe o valor fixo por entrega.';
  END IF;
  FOR v_item IN SELECT value FROM jsonb_array_elements(v_rates) LOOP
    IF length(trim(COALESCE(v_item->>'name','')))<2
       OR COALESCE(v_item->>'amount','') !~ '^\d{1,8}([.,]\d{1,2})?$'
       OR replace(v_item->>'amount',',','.')::numeric<0
       OR replace(v_item->>'amount',',','.')::numeric>10000 THEN
      RAISE EXCEPTION 'Revise os bairros e valores informados na remuneração.';
    END IF;
  END LOOP;

  INSERT INTO public.vortex_delivery_courier_payment_rules(
    store_id,mode,fixed_amount,neighborhood_rates,updated_by,updated_at
  ) VALUES (
    p_store_id,p_mode,CASE WHEN p_mode IN ('fixed','per_km') THEN p_fixed_amount ELSE NULL END,
    v_rates,auth.uid(),now()
  )
  ON CONFLICT (store_id) DO UPDATE SET
    mode=EXCLUDED.mode,
    fixed_amount=EXCLUDED.fixed_amount,
    neighborhood_rates=EXCLUDED.neighborhood_rates,
    updated_by=EXCLUDED.updated_by,
    updated_at=now();

  RETURN jsonb_build_object('success',true,'mode',p_mode);
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpc_get_delivery_courier_payment_rules(p_store_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $function$
DECLARE v_result jsonb;
BEGIN
  IF auth.uid() IS NULL OR NOT (
    public.vortex_user_has_permission(p_store_id,'settings.manage')
    OR public.vortex_user_has_permission(p_store_id,'delivery.dispatch_view')
    OR public.vortex_user_has_permission(p_store_id,'delivery.route_view')
  ) THEN
    RAISE EXCEPTION 'Seu perfil não pode consultar a remuneração dos entregadores.';
  END IF;
  SELECT jsonb_build_object(
    'mode',mode,'fixed_amount',fixed_amount,
    'neighborhood_rates',neighborhood_rates,'updated_at',updated_at
  ) INTO v_result
  FROM public.vortex_delivery_courier_payment_rules
  WHERE store_id=p_store_id;
  RETURN COALESCE(v_result,jsonb_build_object(
    'mode','fixed','fixed_amount',NULL,'neighborhood_rates','[]'::jsonb
  ));
END;
$function$;

-- O valor é congelado na criação da parada (ou ao reativar parada removida),
-- evitando que mudanças futuras na tabela de remuneração reescrevam o passado.
CREATE OR REPLACE FUNCTION public.vortex_snapshot_delivery_courier_payment()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $function$
DECLARE
  v_mode text;
  v_fixed numeric(12,2);
  v_rates jsonb;
  v_address text;
  v_match jsonb;
BEGIN
  IF TG_OP='UPDATE' THEN
    IF OLD.status='cancelled' AND NEW.status='assigned' THEN
      NULL;
    ELSIF NEW.status='delivered' AND OLD.courier_payment_amount IS NULL THEN
      NULL;
    ELSE
      RETURN NEW;
    END IF;
  END IF;
  IF NEW.status NOT IN ('assigned','in_progress','delivered') THEN
    RETURN NEW;
  END IF;

  SELECT mode,fixed_amount,neighborhood_rates
  INTO v_mode,v_fixed,v_rates
  FROM public.vortex_delivery_courier_payment_rules
  WHERE store_id=NEW.store_id;

  IF NOT FOUND THEN
    NEW.courier_payment_amount:=NULL;
    NEW.courier_payment_rule_label:=NULL;
    RETURN NEW;
  END IF;

  IF v_mode='fixed' THEN
    NEW.courier_payment_amount:=v_fixed;
    NEW.courier_payment_rule_label:=CASE WHEN v_fixed IS NULL THEN NULL ELSE 'Valor fixo por entrega' END;
  ELSIF v_mode='per_km' THEN
    IF NEW.distance_km IS NULL THEN
      NEW.courier_payment_amount:=NULL;
      NEW.courier_payment_rule_label:=NULL;
    ELSE
      NEW.courier_payment_amount:=round(v_fixed*NEW.distance_km,2);
      NEW.courier_payment_rule_label:='Por quilômetro · ' || NEW.distance_km::text || ' km';
    END IF;
  ELSIF v_mode='neighborhood' THEN
    SELECT o.address INTO v_address
    FROM public.vortex_kds_orders o
    WHERE o.store_id=NEW.store_id AND o.id=NEW.order_id;
    SELECT item.value INTO v_match
    FROM jsonb_array_elements(v_rates) AS item(value)
    WHERE length(trim(COALESCE(item.value->>'name','')))>=2
      AND COALESCE(v_address,'') ILIKE '%' || trim(item.value->>'name') || '%'
    ORDER BY length(trim(item.value->>'name')) DESC
    LIMIT 1;
    IF v_match IS NULL THEN
      NEW.courier_payment_amount:=NULL;
      NEW.courier_payment_rule_label:=NULL;
    ELSE
      NEW.courier_payment_amount:=replace(v_match->>'amount',',','.')::numeric;
      NEW.courier_payment_rule_label:='Bairro: ' || trim(v_match->>'name');
    END IF;
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS vortex_delivery_stop_payment_snapshot ON public.vortex_delivery_route_stops;
CREATE TRIGGER vortex_delivery_stop_payment_snapshot
BEFORE INSERT OR UPDATE OF status ON public.vortex_delivery_route_stops
FOR EACH ROW EXECUTE FUNCTION public.vortex_snapshot_delivery_courier_payment();

-- As rotas ativas continuam visíveis independentemente do dia. Rotas encerradas
-- permanecem na central operacional apenas se tiveram entrega concluída hoje.
CREATE OR REPLACE FUNCTION public.rpc_get_my_delivery_routes(p_store_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $function$
DECLARE v_result jsonb;
BEGIN
  IF auth.uid() IS NULL
     OR NOT public.vortex_user_has_permission(p_store_id,'delivery.route_view')
     OR NOT EXISTS (
       SELECT 1 FROM public.vortex_store_members
       WHERE store_id=p_store_id AND user_id=auth.uid()
         AND status='active' AND profile_key='delivery'
     ) THEN
    RAISE EXCEPTION 'Esta operação é exclusiva da conta ativa de motoboy.';
  END IF;

  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'id',r.id,'status',r.status,'route_version',r.route_version,
      'assigned_at',r.assigned_at,'started_at',r.started_at,
      'completed_at',r.completed_at,'notes',r.notes,
      'stops',COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'stop_id',s.id,'order_id',s.order_id,
          'sequence_number',s.sequence_number,'stop_status',s.status,
          'occurrence_type',s.occurrence_type,'occurrence_notes',s.occurrence_notes,
          'promised_delivery_at',s.promised_delivery_at,'started_at',s.started_at,'delivered_at',s.delivered_at,
          'distance_km',s.distance_km,
          'courier_payment_amount',s.courier_payment_amount,
          'courier_payment_rule_label',s.courier_payment_rule_label,
          'delivered_by_user_id',s.delivered_by_user_id,
          'display_id',o."displayId",
          'customer_name',regexp_replace(COALESCE(o.client,''),' \([^()]*\)$',''),
          'customer_phone',COALESCE((regexp_match(COALESCE(o.client,''),'\(([^()]*)\)$'))[1],''),
          'address',o.address,'items',o.items,'payment_method',o.payment,
          'amount_due',o.total,'cash_given',o.cashgiven,'change',o.change,
          'observation',o.observation,'order_status',o.status,
          'order_date',o.date,'order_time',o.time
        ) ORDER BY s.sequence_number)
        FROM public.vortex_delivery_route_stops s
        JOIN public.vortex_kds_orders o ON o.store_id=s.store_id AND o.id=s.order_id
        WHERE s.store_id=r.store_id AND s.route_id=r.id
          AND (s.status IN ('assigned','in_progress','occurrence')
            OR (s.status='delivered'
              AND s.delivered_at >= (((now() AT TIME ZONE 'America/Sao_Paulo')::date::timestamp AT TIME ZONE 'America/Sao_Paulo'))
              AND s.delivered_at < (((now() AT TIME ZONE 'America/Sao_Paulo')::date+1)::timestamp AT TIME ZONE 'America/Sao_Paulo')))
      ),'[]'::jsonb)
    ) ORDER BY r.assigned_at DESC
  ),'[]'::jsonb)
  INTO v_result
  FROM public.vortex_delivery_routes r
  WHERE r.store_id=p_store_id AND r.courier_user_id=auth.uid()
    AND r.status IN ('assigned','in_route');
  RETURN v_result;
END;
$function$;

-- Distância informada pelo despacho para remuneração por quilômetro.
-- O servidor calcula e congela o valor; o navegador nunca envia o pagamento calculado.
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
  v_rate numeric(12,2);
  v_amount numeric(12,2);
  v_stop_id uuid;
BEGIN
  IF auth.uid() IS NULL OR NOT public.vortex_user_has_permission(p_store_id,'delivery.dispatch_manage') THEN
    RAISE EXCEPTION 'Seu perfil não pode informar a distância desta entrega.';
  END IF;
  IF p_distance_km IS NULL OR p_distance_km<=0 OR p_distance_km>500 THEN
    RAISE EXCEPTION 'Informe uma distância maior que zero e de até 500 km.';
  END IF;
  SELECT * INTO v_route FROM public.vortex_delivery_routes
  WHERE store_id=p_store_id AND id=p_route_id AND status IN ('assigned','in_route')
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'A rota não está ativa.'; END IF;

  SELECT fixed_amount INTO v_rate
  FROM public.vortex_delivery_courier_payment_rules
  WHERE store_id=p_store_id AND mode='per_km';
  IF NOT FOUND OR v_rate IS NULL THEN
    RAISE EXCEPTION 'A remuneração por quilômetro não está configurada neste estabelecimento.';
  END IF;

  v_amount:=round(v_rate*p_distance_km,2);
  UPDATE public.vortex_delivery_route_stops
  SET distance_km=round(p_distance_km,2),
      courier_payment_amount=v_amount,
      courier_payment_rule_label='Por quilômetro · ' || round(p_distance_km,2)::text || ' km',
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
    jsonb_build_object('distance_km',round(p_distance_km,2),'courier_payment_amount',v_amount)
  );
  RETURN jsonb_build_object('success',true,'distance_km',round(p_distance_km,2),'courier_payment_amount',v_amount);
END;
$function$;

-- Consulta histórica do próprio motoboy: somente entregas efetivamente concluídas
-- pela conta autenticada, com intervalo de datas inclusivo.
CREATE OR REPLACE FUNCTION public.rpc_get_my_delivery_history(
  p_store_id uuid,p_start_date date,p_end_date date
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $function$
DECLARE v_result jsonb;
BEGIN
  IF auth.uid() IS NULL
     OR NOT public.vortex_user_has_permission(p_store_id,'delivery.route_view')
     OR NOT EXISTS (
       SELECT 1 FROM public.vortex_store_members
       WHERE store_id=p_store_id AND user_id=auth.uid()
         AND status='active' AND profile_key='delivery'
     ) THEN
    RAISE EXCEPTION 'Somente o motoboy pode consultar seu próprio histórico.';
  END IF;
  IF p_start_date IS NULL OR p_end_date IS NULL OR p_start_date>p_end_date
     OR p_end_date-p_start_date>366 THEN
    RAISE EXCEPTION 'Período inválido. Consulte no máximo 12 meses por vez.';
  END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'order_id',s.order_id,'display_id',o."displayId",
    'customer_name',regexp_replace(COALESCE(o.client,''),' \([^()]*\)$',''),
    'address',o.address,'delivered_at',s.delivered_at,
    'distance_km',s.distance_km,
    'courier_payment_amount',s.courier_payment_amount,
    'courier_payment_rule_label',s.courier_payment_rule_label,
    'route_id',s.route_id,'status',s.status
  ) ORDER BY s.delivered_at DESC),'[]'::jsonb)
  INTO v_result
  FROM public.vortex_delivery_route_stops s
  JOIN public.vortex_kds_orders o ON o.store_id=s.store_id AND o.id=s.order_id
  WHERE s.store_id=p_store_id AND s.delivered_by_user_id=auth.uid()
    AND s.status='delivered'
    AND s.delivered_at >= (p_start_date::timestamp AT TIME ZONE 'America/Sao_Paulo')
    AND s.delivered_at < ((p_end_date+1)::timestamp AT TIME ZONE 'America/Sao_Paulo');
  RETURN v_result;
END;
$function$;

-- Histórico do estabelecimento: cada parada concluída aparece com o entregador
-- que efetivamente confirmou o código, não com o responsável atual da rota.
CREATE OR REPLACE FUNCTION public.rpc_get_delivery_dispatch_history(
  p_store_id uuid,p_start_date date,p_end_date date
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $function$
DECLARE v_result jsonb;
BEGIN
  IF auth.uid() IS NULL
     OR NOT public.vortex_user_has_permission(p_store_id,'delivery.dispatch_view') THEN
    RAISE EXCEPTION 'Seu perfil não pode consultar o histórico de entregas.';
  END IF;
  IF p_start_date IS NULL OR p_end_date IS NULL OR p_start_date>p_end_date
     OR p_end_date-p_start_date>366 THEN
    RAISE EXCEPTION 'Período inválido. Consulte no máximo 12 meses por vez.';
  END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'order_id',s.order_id,'display_id',o."displayId",
    'customer_name',regexp_replace(COALESCE(o.client,''),' \([^()]*\)$',''),
    'address',o.address,'delivered_at',s.delivered_at,
    'courier_user_id',s.delivered_by_user_id,
    'courier_name',COALESCE(NULLIF(m.display_name,''),NULLIF(u.raw_user_meta_data->>'display_name',''),'Motoboy não identificado'),
    'courier_payment_amount',s.courier_payment_amount,
    'courier_payment_rule_label',s.courier_payment_rule_label,
    'route_id',s.route_id,'status',s.status
  ) ORDER BY s.delivered_at DESC),'[]'::jsonb)
  INTO v_result
  FROM public.vortex_delivery_route_stops s
  JOIN public.vortex_kds_orders o ON o.store_id=s.store_id AND o.id=s.order_id
  LEFT JOIN auth.users u ON u.id=s.delivered_by_user_id
  LEFT JOIN public.vortex_store_members m ON m.store_id=s.store_id AND m.user_id=s.delivered_by_user_id
  WHERE s.store_id=p_store_id AND s.status='delivered'
    AND s.delivered_at >= (p_start_date::timestamp AT TIME ZONE 'America/Sao_Paulo')
    AND s.delivered_at < ((p_end_date+1)::timestamp AT TIME ZONE 'America/Sao_Paulo');
  RETURN v_result;
END;
$function$;

-- Central de operações: apenas rotas ativas ou com entregas concluídas hoje.
CREATE OR REPLACE FUNCTION public.rpc_get_delivery_dispatch_routes(p_store_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $function$
DECLARE v_result jsonb;
BEGIN
  IF auth.uid() IS NULL
     OR NOT public.vortex_user_has_permission(p_store_id,'delivery.dispatch_view')
     OR NOT EXISTS (
       SELECT 1 FROM public.vortex_store_members
       WHERE store_id=p_store_id AND user_id=auth.uid() AND status='active'
     ) THEN
    RAISE EXCEPTION 'Seu perfil não pode visualizar a central de rotas.';
  END IF;

  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'id',r.id,'status',r.status,'route_version',r.route_version,
      'courier_user_id',r.courier_user_id,
      'courier_name',COALESCE(NULLIF(cm.display_name,''),NULLIF(u.raw_user_meta_data->>'display_name',''),'Motoboy'),
      'assigned_at',r.assigned_at,'started_at',r.started_at,
      'completed_at',r.completed_at,'cancelled_at',r.cancelled_at,
      'presence_status',COALESCE(cp.status,'unavailable'),
      'presence_updated_at',cp.updated_at,
      'stop_count',COALESCE(stats.stop_count,0),
      'delivered_count',COALESCE(stats.delivered_count,0),
      'occurrence_count',COALESCE(stats.occurrence_count,0),
      'returned_count',COALESCE(stats.returned_count,0),
      'events',COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'event_type',recent.event_type,'created_at',recent.created_at,'details',recent.details
        ) ORDER BY recent.created_at DESC)
        FROM (
          SELECT e.event_type,e.created_at,e.details
          FROM public.vortex_delivery_route_events e
          WHERE e.store_id=r.store_id AND e.route_id=r.id
          ORDER BY e.created_at DESC LIMIT 10
        ) recent
      ),'[]'::jsonb),
      'stops',COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'stop_id',s.id,'order_id',s.order_id,
          'sequence_number',s.sequence_number,'status',s.status,
          'occurrence_type',s.occurrence_type,'occurrence_notes',s.occurrence_notes,
          'occurrence_at',s.occurrence_at,'promised_delivery_at',s.promised_delivery_at,
          'started_at',s.started_at,'delivered_at',s.delivered_at,
          'distance_km',s.distance_km,
          'courier_payment_amount',s.courier_payment_amount,
          'courier_payment_rule_label',s.courier_payment_rule_label,
          'delivered_by_user_id',s.delivered_by_user_id,
          'display_id',o."displayId",
          'customer_name',regexp_replace(COALESCE(o.client,''),' \([^()]*\)$',''),
          'address',o.address,'order_status',o.status
        ) ORDER BY s.sequence_number)
        FROM public.vortex_delivery_route_stops s
        LEFT JOIN public.vortex_kds_orders o
          ON o.store_id=s.store_id AND o.id=s.order_id
        WHERE s.store_id=r.store_id AND s.route_id=r.id
      ),'[]'::jsonb)
    ) ORDER BY CASE r.status WHEN 'in_route' THEN 0 WHEN 'assigned' THEN 1 ELSE 2 END,
      r.assigned_at DESC
  ),'[]'::jsonb)
  INTO v_result
  FROM public.vortex_delivery_routes r
  JOIN auth.users u ON u.id=r.courier_user_id
  LEFT JOIN public.vortex_store_members cm ON cm.store_id=r.store_id AND cm.user_id=r.courier_user_id
  LEFT JOIN public.vortex_delivery_courier_presence cp
    ON cp.store_id=r.store_id AND cp.courier_user_id=r.courier_user_id
  LEFT JOIN LATERAL (
    SELECT count(*) FILTER (WHERE s.status IN ('assigned','in_progress','occurrence')
        OR (s.status='delivered'
          AND s.delivered_at >= (((now() AT TIME ZONE 'America/Sao_Paulo')::date::timestamp AT TIME ZONE 'America/Sao_Paulo'))
          AND s.delivered_at < (((now() AT TIME ZONE 'America/Sao_Paulo')::date+1)::timestamp AT TIME ZONE 'America/Sao_Paulo')))::integer AS stop_count,
      count(*) FILTER (WHERE s.status='delivered'
        AND s.delivered_at >= (((now() AT TIME ZONE 'America/Sao_Paulo')::date::timestamp AT TIME ZONE 'America/Sao_Paulo'))
        AND s.delivered_at < (((now() AT TIME ZONE 'America/Sao_Paulo')::date+1)::timestamp AT TIME ZONE 'America/Sao_Paulo'))::integer AS delivered_count,
      count(*) FILTER (WHERE s.status='occurrence')::integer AS occurrence_count,
      count(*) FILTER (WHERE s.status='returned')::integer AS returned_count
    FROM public.vortex_delivery_route_stops s
    WHERE s.store_id=r.store_id AND s.route_id=r.id
  ) stats ON true
  WHERE r.store_id=p_store_id
    AND (r.status IN ('assigned','in_route') OR EXISTS (
      SELECT 1 FROM public.vortex_delivery_route_stops today_stop
      WHERE today_stop.store_id=r.store_id AND today_stop.route_id=r.id
        AND today_stop.status='delivered'
        AND today_stop.delivered_at >= (((now() AT TIME ZONE 'America/Sao_Paulo')::date::timestamp AT TIME ZONE 'America/Sao_Paulo'))
        AND today_stop.delivered_at < (((now() AT TIME ZONE 'America/Sao_Paulo')::date+1)::timestamp AT TIME ZONE 'America/Sao_Paulo')
    ));
  RETURN v_result;
END;
$function$;

-- Substitui somente a confirmação de entrega para registrar o entregador real.
-- Mantém validação do código, limite de tentativas e transação existentes.
CREATE OR REPLACE FUNCTION public.rpc_confirm_delivery_code(
  p_store_id uuid,p_order_id text,p_code text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $function$
DECLARE
  v_verification public.vortex_delivery_verifications%ROWTYPE;
  v_origin text;
  v_status text;
  v_attempts integer;
  v_profile_key text;
  v_courier_member_id uuid;
  v_route_id uuid;
  v_stop_id uuid;
BEGIN
  IF auth.uid() IS NULL OR NOT public.vortex_user_has_permission(p_store_id,'delivery.confirm') THEN
    RAISE EXCEPTION 'Seu perfil não pode confirmar entregas.';
  END IF;
  SELECT profile_key INTO v_profile_key
  FROM public.vortex_store_members
  WHERE store_id=p_store_id AND user_id=auth.uid() AND status='active';

  SELECT origin,status,courier_member_id
  INTO v_origin,v_status,v_courier_member_id
  FROM public.vortex_kds_orders
  WHERE store_id=p_store_id AND id=p_order_id
  FOR UPDATE;

  IF NOT FOUND OR COALESCE(v_origin,'') NOT ILIKE '%Delivery%' OR v_status<>'delivering' THEN
    RETURN jsonb_build_object('success',false,'message','Este pedido não está em rota de entrega.');
  END IF;
  IF v_profile_key='delivery' AND v_courier_member_id IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'Este pedido não está atribuído à sua conta de entregador.';
  END IF;

  SELECT * INTO v_verification
  FROM public.vortex_delivery_verifications
  WHERE store_id=p_store_id AND order_id=p_order_id
  FOR UPDATE;
  IF NOT FOUND OR NOT v_verification.is_active
     OR v_verification.consumed_at IS NOT NULL OR v_verification.expires_at<=now() THEN
    RETURN jsonb_build_object('success',false,'message','Código inexistente, expirado ou já utilizado.');
  END IF;
  IF v_verification.locked_until IS NOT NULL AND v_verification.locked_until>now() THEN
    RETURN jsonb_build_object('success',false,'message','Muitas tentativas incorretas. Aguarde 15 minutos antes de tentar novamente.');
  END IF;
  IF v_verification.attempt_count>=5 THEN
    UPDATE public.vortex_delivery_verifications
    SET attempt_count=0,locked_until=NULL
    WHERE store_id=p_store_id AND order_id=p_order_id;
    v_verification.attempt_count:=0;
  END IF;
  IF COALESCE(p_code,'') !~ '^[0-9]{6}$' OR p_code<>v_verification.code THEN
    v_attempts:=v_verification.attempt_count+1;
    UPDATE public.vortex_delivery_verifications
    SET attempt_count=v_attempts,
        locked_until=CASE WHEN v_attempts>=5 THEN now()+interval '15 minutes' ELSE NULL END
    WHERE store_id=p_store_id AND order_id=p_order_id;
    RETURN jsonb_build_object('success',false,
      'message',CASE WHEN v_attempts>=5 THEN 'Limite de tentativas atingido. Aguarde 15 minutos.'
        ELSE 'Código incorreto. Confira os seis números e tente novamente.' END);
  END IF;

  UPDATE public.vortex_delivery_verifications
  SET is_active=false,consumed_at=now()
  WHERE store_id=p_store_id AND order_id=p_order_id;
  UPDATE public.vortex_kds_orders
  SET status='finished',updated_at=now()
  WHERE store_id=p_store_id AND id=p_order_id;

  UPDATE public.vortex_delivery_route_stops
  SET status='delivered',delivered_at=now(),delivered_by_user_id=COALESCE(v_courier_member_id,auth.uid()),updated_at=now()
  WHERE store_id=p_store_id AND order_id=p_order_id
    AND status IN ('in_progress','occurrence')
  RETURNING route_id,id INTO v_route_id,v_stop_id;

  IF v_route_id IS NOT NULL THEN
    INSERT INTO public.vortex_delivery_route_events(
      store_id,route_id,stop_id,order_id,actor_user_id,event_type,details
    ) VALUES (
      p_store_id,v_route_id,v_stop_id,p_order_id,auth.uid(),'delivery_confirmed',
      jsonb_build_object('confirmed_at',now(),'method','customer_code',
        'delivered_by_user_id',COALESCE(v_courier_member_id,auth.uid()))
    );
    IF NOT EXISTS (
      SELECT 1 FROM public.vortex_delivery_route_stops
      WHERE store_id=p_store_id AND route_id=v_route_id
        AND status IN ('assigned','in_progress','occurrence')
    ) THEN
      UPDATE public.vortex_delivery_routes
      SET status='completed',completed_at=now(),updated_at=now()
      WHERE store_id=p_store_id AND id=v_route_id AND status='in_route';
      UPDATE public.vortex_delivery_courier_presence
      SET status='available',updated_at=now()
      WHERE store_id=p_store_id
        AND courier_user_id=(SELECT courier_user_id FROM public.vortex_delivery_routes
          WHERE store_id=p_store_id AND id=v_route_id);
    END IF;
  END IF;
  RETURN jsonb_build_object('success',true,'message','Entrega confirmada com sucesso.');
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_set_delivery_stop_distance(uuid,uuid,text,numeric) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.rpc_set_delivery_stop_distance(uuid,uuid,text,numeric) TO authenticated;
REVOKE ALL ON FUNCTION public.rpc_save_delivery_courier_payment_rules(uuid,text,numeric,jsonb) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.rpc_get_delivery_courier_payment_rules(uuid) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.rpc_get_my_delivery_history(uuid,date,date) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.rpc_get_delivery_dispatch_history(uuid,date,date) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.rpc_save_delivery_courier_payment_rules(uuid,text,numeric,jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_get_delivery_courier_payment_rules(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_get_my_delivery_history(uuid,date,date) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_get_delivery_dispatch_history(uuid,date,date) TO authenticated;

COMMIT;
