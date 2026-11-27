-- VORTEX FOOD: precisão e coordenadas verificadas do destino de cada entrega.
-- Migração aditiva: não altera endereços escritos, distâncias históricas ou valores pagos.
BEGIN;

ALTER TABLE public.vortex_delivery_route_stops
  ADD COLUMN IF NOT EXISTS destination_longitude numeric(10,7),
  ADD COLUMN IF NOT EXISTS destination_latitude numeric(10,7),
  ADD COLUMN IF NOT EXISTS location_precision text NOT NULL DEFAULT 'unknown',
  ADD COLUMN IF NOT EXISTS location_source text;

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
        OR (destination_longitude BETWEEN -180 AND 180 AND destination_latitude BETWEEN -90 AND 90)
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
          'customer_name',regexp_replace(COALESCE(o.client,''),' \\([^()]*\\)$',''),
          'customer_phone',COALESCE((regexp_match(COALESCE(o.client,''),'\\(([^()]*)\\)$'))[1],''),
          'address',o.address,
          'destination_longitude',s.destination_longitude,'destination_latitude',s.destination_latitude,
          'location_precision',s.location_precision,'location_source',s.location_source,
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

COMMIT;
