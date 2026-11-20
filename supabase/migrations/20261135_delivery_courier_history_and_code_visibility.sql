BEGIN;

-- 1) Recupera baixas manuais feitas antes da sincronização entre a central e o painel.
-- O pedido já finalizado é a fonte de verdade; a parada é atribuída ao entregador
-- responsável pela rota e passa a compor o histórico individual dele.
UPDATE public.vortex_delivery_route_stops s
SET status = 'delivered',
    delivered_at = COALESCE(s.delivered_at, o.updated_at, now()),
    delivered_by_user_id = COALESCE(r.courier_user_id, o.courier_member_id),
    updated_at = now()
FROM public.vortex_kds_orders o
JOIN public.vortex_delivery_routes r
  ON r.store_id = o.store_id
WHERE s.store_id = o.store_id
  AND s.order_id = o.id
  AND s.route_id = r.id
  AND s.store_id = r.store_id
  AND o.status = 'finished'
  AND COALESCE(o.origin, '') ILIKE '%Delivery%'
  AND s.status IN ('assigned', 'in_progress', 'occurrence');

-- Se a regularização concluiu todas as paradas, conclui também a rota.
UPDATE public.vortex_delivery_routes r
SET status = 'completed',
    completed_at = COALESCE(
      r.completed_at,
      (SELECT MAX(s.delivered_at)
       FROM public.vortex_delivery_route_stops s
       WHERE s.store_id = r.store_id AND s.route_id = r.id),
      now()
    ),
    updated_at = now()
WHERE r.status IN ('assigned', 'in_route')
  AND EXISTS (
    SELECT 1
    FROM public.vortex_delivery_route_stops s
    JOIN public.vortex_kds_orders o
      ON o.store_id = s.store_id AND o.id = s.order_id
    WHERE s.store_id = r.store_id AND s.route_id = r.id
      AND o.status = 'finished'
      AND COALESCE(o.origin, '') ILIKE '%Delivery%'
      AND s.status = 'delivered'
  )
  AND NOT EXISTS (
    SELECT 1
    FROM public.vortex_delivery_route_stops pending
    WHERE pending.store_id = r.store_id AND pending.route_id = r.id
      AND pending.status IN ('assigned', 'in_progress', 'occurrence')
  );

-- Libera a disponibilidade do motoboy quando a regularização conclui sua rota.
UPDATE public.vortex_delivery_courier_presence p
SET status='available',updated_at=now()
FROM public.vortex_delivery_routes r
WHERE p.store_id=r.store_id
  AND p.courier_user_id=r.courier_user_id
  AND r.status='completed'
  AND r.completed_at >= now() - interval '10 minutes'
  AND p.status='in_route';

-- 2) O motoboy vê o botão de código quando existe uma verificação ativa
-- para aquele pedido. O código em si nunca é retornado nesta consulta.
-- Pedidos manuais, cuja verificação foi desativada, continuam sem exigir código.
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
          'promised_delivery_at',s.promised_delivery_at,
          'started_at',s.started_at,'delivered_at',s.delivered_at,
          'distance_km',s.distance_km,
          'courier_payment_amount',s.courier_payment_amount,
          'courier_payment_rule_label',s.courier_payment_rule_label,
          'delivered_by_user_id',s.delivered_by_user_id,
          'display_id',o."displayId",
          'customer_name',regexp_replace(COALESCE(o.client,''),' \([^()]*\)$',''),
          'customer_phone',COALESCE((regexp_match(COALESCE(o.client,''),'\(([^()]*)\)$'))[1],''),
          'address',o.address,'items',o.items,'payment_method',o.payment,
          'payment_status',o.payment_status,
          'requires_customer_code',EXISTS (
            SELECT 1
            FROM public.vortex_delivery_verifications v
            WHERE v.store_id=o.store_id AND v.order_id=o.id
              AND v.is_active=true AND v.consumed_at IS NULL
              AND v.expires_at>now()
          ),
          'amount_due',o.total,'cash_given',o.cashgiven,'change',o.change,
          'observation',o.observation,'order_status',o.status,
          'order_date',o.date,'order_time',o.time
        ) ORDER BY s.sequence_number)
        FROM public.vortex_delivery_route_stops s
        JOIN public.vortex_kds_orders o
          ON o.store_id=s.store_id AND o.id=s.order_id
        WHERE s.store_id=r.store_id AND s.route_id=r.id
          AND (
            s.status IN ('assigned','in_progress','occurrence')
            OR (
              s.status='delivered'
              AND s.delivered_at >= (((now() AT TIME ZONE 'America/Sao_Paulo')::date::timestamp AT TIME ZONE 'America/Sao_Paulo'))
              AND s.delivered_at < (((now() AT TIME ZONE 'America/Sao_Paulo')::date+1)::timestamp AT TIME ZONE 'America/Sao_Paulo')
            )
          )
      ),'[]'::jsonb)
    ) ORDER BY r.assigned_at DESC
  ),'[]'::jsonb)
  INTO v_result
  FROM public.vortex_delivery_routes r
  WHERE r.store_id=p_store_id
    AND r.courier_user_id=auth.uid()
    AND r.status IN ('assigned','in_route');

  RETURN v_result;
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_get_my_delivery_routes(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_get_my_delivery_routes(uuid) TO authenticated;

-- Motoboy confirma diretamente somente pedidos sem código ativo e da própria rota.
CREATE OR REPLACE FUNCTION public.rpc_confirm_delivery_manual_by_courier(
  p_store_id uuid,
  p_order_id text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $function$
DECLARE
  v_route_id uuid;
  v_stop_id uuid;
  v_order_status text;
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

  SELECT s.route_id,s.id,o.status
  INTO v_route_id,v_stop_id,v_order_status
  FROM public.vortex_delivery_route_stops s
  JOIN public.vortex_delivery_routes r
    ON r.store_id=s.store_id AND r.id=s.route_id
  JOIN public.vortex_kds_orders o
    ON o.store_id=s.store_id AND o.id=s.order_id
  WHERE s.store_id=p_store_id AND s.order_id=p_order_id
    AND r.courier_user_id=auth.uid()
    AND r.status IN ('assigned','in_route')
    AND s.status IN ('assigned','in_progress','occurrence')
  FOR UPDATE OF s,o;

  IF v_stop_id IS NULL THEN
    RETURN jsonb_build_object('success',false,'message','Entrega não encontrada na sua rota ativa.');
  END IF;
  IF v_order_status IN ('finished','cancelled') THEN
    RETURN jsonb_build_object('success',false,'message','Este pedido já foi finalizado ou cancelado.');
  END IF;
  IF v_order_status<>'delivering' THEN
    RETURN jsonb_build_object('success',false,'message','A entrega precisa estar em rota para ser confirmada.');
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.vortex_delivery_verifications v
    WHERE v.store_id=p_store_id AND v.order_id=p_order_id
      AND v.is_active=true AND v.consumed_at IS NULL AND v.expires_at>now()
  ) THEN
    RETURN jsonb_build_object('success',false,'message','Este pedido exige o código do cliente. A confirmação manual pelo motoboy não está disponível.');
  END IF;

  UPDATE public.vortex_kds_orders
  SET status='finished',updated_at=now()
  WHERE store_id=p_store_id AND id=p_order_id;

  UPDATE public.vortex_delivery_route_stops
  SET status='delivered',delivered_at=now(),
      delivered_by_user_id=auth.uid(),updated_at=now()
  WHERE store_id=p_store_id AND id=v_stop_id;

  INSERT INTO public.vortex_delivery_route_events(
    store_id,route_id,stop_id,order_id,actor_user_id,event_type,details
  ) VALUES (
    p_store_id,v_route_id,v_stop_id,p_order_id,auth.uid(),'delivery_confirmed',
    jsonb_build_object('confirmed_at',now(),'method','manual_by_courier',
      'confirmed_by_user_id',auth.uid(),'courier_user_id',auth.uid())
  );

  IF NOT EXISTS (
    SELECT 1 FROM public.vortex_delivery_route_stops
    WHERE store_id=p_store_id AND route_id=v_route_id
      AND status IN ('assigned','in_progress','occurrence')
  ) THEN
    UPDATE public.vortex_delivery_routes
    SET status='completed',completed_at=now(),updated_at=now()
    WHERE store_id=p_store_id AND id=v_route_id AND status IN ('assigned','in_route');

    UPDATE public.vortex_delivery_courier_presence
    SET status='available',updated_at=now()
    WHERE store_id=p_store_id AND courier_user_id=auth.uid();
  END IF;

  RETURN jsonb_build_object('success',true,'message','Entrega confirmada.');
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_confirm_delivery_manual_by_courier(uuid,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.rpc_confirm_delivery_manual_by_courier(uuid,text) TO authenticated;

COMMIT;
