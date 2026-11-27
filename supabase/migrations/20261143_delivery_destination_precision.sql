-- VORTEX FOOD: precisão e coordenadas verificadas do destino de cada entrega.
-- Migração aditiva: não altera endereços escritos, distâncias históricas ou valores pagos.
BEGIN;

ALTER TABLE public.vortex_delivery_route_stops
  ADD COLUMN IF NOT EXISTS destination_longitude numeric(10,7),
  ADD COLUMN IF NOT EXISTS destination_latitude numeric(10,7),
  ADD COLUMN IF NOT EXISTS location_precision text NOT NULL DEFAULT 'unknown',
  ADD COLUMN IF NOT EXISTS location_source text,
  ADD COLUMN IF NOT EXISTS location_confirmed_at timestamptz,
  ADD COLUMN IF NOT EXISTS location_confirmed_by uuid REFERENCES auth.users(id) ON DELETE SET NULL;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid='public.vortex_delivery_route_stops'::regclass AND conname='vortex_delivery_route_stops_location_precision_check') THEN
    ALTER TABLE public.vortex_delivery_route_stops ADD CONSTRAINT vortex_delivery_route_stops_location_precision_check
      CHECK (location_precision IN ('unknown','exact','street_segment','manual_pin'));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid='public.vortex_delivery_route_stops'::regclass AND conname='vortex_delivery_route_stops_location_source_check') THEN
    ALTER TABLE public.vortex_delivery_route_stops ADD CONSTRAINT vortex_delivery_route_stops_location_source_check
      CHECK (location_source IS NULL OR location_source IN ('geoapify','openrouteservice','manual'));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid='public.vortex_delivery_route_stops'::regclass AND conname='vortex_delivery_route_stops_location_coordinates_check') THEN
    ALTER TABLE public.vortex_delivery_route_stops ADD CONSTRAINT vortex_delivery_route_stops_location_coordinates_check
      CHECK (
        (destination_longitude IS NULL AND destination_latitude IS NULL)
        OR (destination_longitude IS NOT NULL AND destination_latitude IS NOT NULL
          AND destination_longitude BETWEEN -180 AND 180 AND destination_latitude BETWEEN -90 AND 90)
      );
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.rpc_get_my_delivery_routes(p_store_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $function$
DECLARE
  v_result jsonb;
BEGIN
  IF auth.uid() IS NULL OR NOT public.vortex_user_has_permission(p_store_id,'delivery.route_view') THEN
    RAISE EXCEPTION 'Seu perfil não pode consultar o painel de rotas.';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.vortex_store_members
    WHERE store_id=p_store_id AND user_id=auth.uid() AND status='active' AND profile_key='delivery'
  ) THEN
    RAISE EXCEPTION 'Esta operação é exclusiva da conta de motoboy.';
  END IF;
  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'id',r.id,'status',r.status,'route_version',r.route_version,
      'assigned_at',r.assigned_at,'started_at',r.started_at,'completed_at',r.completed_at,'notes',r.notes,
      'stops',COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'stop_id',s.id,'order_id',s.order_id,'sequence_number',s.sequence_number,'stop_status',s.status,
          'occurrence_type',s.occurrence_type,'occurrence_notes',s.occurrence_notes,
          'promised_delivery_at',s.promised_delivery_at,'started_at',s.started_at,'delivered_at',s.delivered_at,
          'display_id',o."displayId",
          'customer_name',regexp_replace(COALESCE(o.client,''),' \([^()]*\)$',''),
          'customer_phone',COALESCE((regexp_match(COALESCE(o.client,''),'\(([^()]*)\)$'))[1],''),
          'address',o.address,
          'destination_longitude',s.destination_longitude,'destination_latitude',s.destination_latitude,
          'location_precision',s.location_precision,'location_source',s.location_source,
          'location_confirmed_at',s.location_confirmed_at,'location_confirmed_by',s.location_confirmed_by,
          'items',o.items,'payment_method',o.payment,'amount_due',o.total,
          'cash_given',o.cashgiven,'change',o.change,'observation',o.observation,
          'order_status',o.status,'order_date',o.date,'order_time',o.time
        ) ORDER BY s.sequence_number)
        FROM public.vortex_delivery_route_stops s
        JOIN public.vortex_kds_orders o ON o.store_id=s.store_id AND o.id=s.order_id
        WHERE s.store_id=r.store_id AND s.route_id=r.id
      ),'[]'::jsonb)
    ) ORDER BY r.assigned_at DESC
  ),'[]'::jsonb)
  INTO v_result
  FROM public.vortex_delivery_routes r
  WHERE r.store_id=p_store_id AND r.courier_user_id=auth.uid()
    AND (r.status IN ('assigned','in_route') OR r.assigned_at>now()-interval '30 days');
  RETURN v_result;
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpc_get_delivery_dispatch_routes(p_store_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $function$
DECLARE
  v_result jsonb;
BEGIN
  IF auth.uid() IS NULL
     OR NOT public.vortex_user_has_permission(p_store_id,'delivery.dispatch_view') THEN
    RAISE EXCEPTION 'Seu perfil não pode visualizar a central de rotas.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.vortex_store_members
    WHERE store_id=p_store_id AND user_id=auth.uid() AND status='active'
  ) THEN
    RAISE EXCEPTION 'Acesso ao estabelecimento não autorizado.';
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
          'display_id',o."displayId",
          'customer_name',regexp_replace(COALESCE(o.client,''),' \([^()]*\)$',''),
          'address',o.address,
          'destination_longitude',s.destination_longitude,
          'destination_latitude',s.destination_latitude,
          'location_precision',s.location_precision,
          'location_source',s.location_source,
          'order_status',o.status
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
    SELECT count(*) FILTER (WHERE s.status<>'cancelled')::integer AS stop_count,
      count(*) FILTER (WHERE s.status='delivered')::integer AS delivered_count,
      count(*) FILTER (WHERE s.status='occurrence')::integer AS occurrence_count,
      count(*) FILTER (WHERE s.status='returned')::integer AS returned_count
    FROM public.vortex_delivery_route_stops s
    WHERE s.store_id=r.store_id AND s.route_id=r.id
  ) stats ON true
  WHERE r.store_id=p_store_id
    AND (r.status IN ('assigned','in_route') OR r.assigned_at>now()-interval '30 days');

  RETURN v_result;
END;
$function$;


CREATE OR REPLACE FUNCTION public.rpc_start_delivery_route(p_store_id uuid,p_route_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $function$
DECLARE
  v_route public.vortex_delivery_routes%ROWTYPE;
  v_stop_count integer;
  v_invalid_count integer;
  v_missing_location_count integer;
BEGIN
  IF auth.uid() IS NULL
     OR NOT public.vortex_user_has_permission(p_store_id,'delivery.route_start') THEN
    RAISE EXCEPTION 'Seu perfil não pode iniciar rotas.';
  END IF;

  SELECT * INTO v_route
  FROM public.vortex_delivery_routes
  WHERE store_id=p_store_id AND id=p_route_id
    AND courier_user_id=auth.uid()
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Esta rota não está atribuída à sua conta.';
  END IF;
  IF v_route.status<>'assigned' THEN
    RAISE EXCEPTION 'Somente uma rota aguardando saída pode ser iniciada.';
  END IF;

  SELECT count(*) INTO v_stop_count
  FROM public.vortex_delivery_route_stops s
  WHERE s.store_id=p_store_id AND s.route_id=p_route_id AND s.status='assigned';

  SELECT count(*) INTO v_invalid_count
  FROM public.vortex_delivery_route_stops s
  JOIN public.vortex_kds_orders o ON o.store_id=s.store_id AND o.id=s.order_id
  WHERE s.store_id=p_store_id AND s.route_id=p_route_id
    AND s.status='assigned' AND o.status IN ('finished','cancelled');

  IF v_stop_count=0 OR v_invalid_count>0 THEN
    RAISE EXCEPTION 'Esta rota não possui entregas pendentes válidas. Atualize a rota com o estabelecimento.';
  END IF;

  SELECT count(*) INTO v_missing_location_count
  FROM public.vortex_delivery_route_stops s
  WHERE s.store_id=p_store_id AND s.route_id=p_route_id AND s.status='assigned'
    AND (
      s.destination_latitude IS NULL OR s.destination_longitude IS NULL
      OR s.location_precision NOT IN ('exact','street_segment','manual_pin')
    );
  IF v_missing_location_count>0 THEN
    RAISE EXCEPTION 'Uma ou mais entregas ainda não possuem localização confirmada. Peça ao estabelecimento para corrigir o ponto no mapa antes de iniciar a rota.';
  END IF;

  UPDATE public.vortex_delivery_routes
  SET status='in_route',started_at=now(),updated_at=now()
  WHERE store_id=p_store_id AND id=p_route_id;

  UPDATE public.vortex_delivery_route_stops
  SET status='in_progress',started_at=now(),updated_at=now()
  WHERE store_id=p_store_id AND route_id=p_route_id AND status='assigned';

  UPDATE public.vortex_kds_orders o
  SET status='delivering',updated_at=now()
  FROM public.vortex_delivery_route_stops s
  WHERE s.store_id=p_store_id AND s.route_id=p_route_id
    AND s.order_id=o.id AND o.store_id=s.store_id
    AND s.status='in_progress' AND o.status NOT IN ('finished','cancelled');

  UPDATE public.vortex_delivery_courier_presence
  SET status='in_route',updated_at=now()
  WHERE store_id=p_store_id AND courier_user_id=auth.uid();

  INSERT INTO public.vortex_delivery_route_events(store_id,route_id,actor_user_id,event_type,details)
  VALUES (p_store_id,p_route_id,auth.uid(),'route_started',jsonb_build_object('started_at',now()));

  RETURN jsonb_build_object('success',true,'route_id',p_route_id,'started_at',now());
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpc_set_delivery_stop_manual_location(
  p_store_id uuid,
  p_route_id uuid,
  p_order_id text,
  p_latitude numeric,
  p_longitude numeric
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $function$
DECLARE
  v_route public.vortex_delivery_routes%ROWTYPE;
  v_stop_id uuid;
BEGIN
  IF auth.uid() IS NULL OR NOT public.vortex_user_has_permission(p_store_id,'delivery.dispatch_manage') THEN
    RAISE EXCEPTION 'Seu perfil não pode corrigir a localização das entregas.';
  END IF;
  IF p_latitude IS NULL OR p_longitude IS NULL
     OR p_latitude NOT BETWEEN -90 AND 90
     OR p_longitude NOT BETWEEN -180 AND 180 THEN
    RAISE EXCEPTION 'Informe coordenadas válidas para o ponto de entrega.';
  END IF;

  SELECT * INTO v_route
  FROM public.vortex_delivery_routes
  WHERE store_id=p_store_id AND id=p_route_id
  FOR UPDATE;
  IF NOT FOUND OR v_route.status<>'assigned' THEN
    RAISE EXCEPTION 'A localização só pode ser corrigida antes de iniciar a rota.';
  END IF;

  SELECT id INTO v_stop_id
  FROM public.vortex_delivery_route_stops
  WHERE store_id=p_store_id AND route_id=p_route_id
    AND order_id=p_order_id AND status='assigned'
  FOR UPDATE;
  IF v_stop_id IS NULL THEN
    RAISE EXCEPTION 'A entrega não está pendente nesta rota.';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.vortex_delivery_courier_ledger
    WHERE store_id=p_store_id AND stop_id=v_stop_id AND payout_status='paid'
  ) THEN
    RAISE EXCEPTION 'A localização não pode ser alterada depois que o repasse foi quitado.';
  END IF;

  UPDATE public.vortex_delivery_route_stops
  SET destination_longitude=round(p_longitude,7),
      destination_latitude=round(p_latitude,7),
      location_precision='manual_pin',
      location_source='manual',
      location_confirmed_at=now(),
      location_confirmed_by=auth.uid(),
      distance_km=NULL,
      courier_payment_amount=NULL,
      courier_payment_rule_label=NULL,
      updated_at=now()
  WHERE store_id=p_store_id AND route_id=p_route_id AND order_id=p_order_id;

  UPDATE public.vortex_delivery_routes
  SET route_version=route_version+1,updated_at=now()
  WHERE store_id=p_store_id AND id=p_route_id;

  INSERT INTO public.vortex_delivery_route_events(
    store_id,route_id,stop_id,order_id,actor_user_id,event_type,details
  ) VALUES (
    p_store_id,p_route_id,v_stop_id,p_order_id,auth.uid(),'delivery_location_manual_set',
    jsonb_build_object('latitude',round(p_latitude,7),'longitude',round(p_longitude,7),'precision','manual_pin')
  );

  RETURN jsonb_build_object('success',true,'location_precision','manual_pin','location_source','manual');
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_set_delivery_stop_manual_location(uuid,uuid,text,numeric,numeric) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_set_delivery_stop_manual_location(uuid,uuid,text,numeric,numeric) TO authenticated;

COMMIT;
