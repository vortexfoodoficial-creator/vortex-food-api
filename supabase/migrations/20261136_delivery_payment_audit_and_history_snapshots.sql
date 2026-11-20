BEGIN;

-- Snapshot imutável dos dados financeiros no momento em que a parada é concluída.
ALTER TABLE public.vortex_delivery_route_stops
  ADD COLUMN IF NOT EXISTS payment_method_snapshot text,
  ADD COLUMN IF NOT EXISTS payment_status_snapshot text,
  ADD COLUMN IF NOT EXISTS amount_due_snapshot numeric(12,2),
  ADD COLUMN IF NOT EXISTS cash_given_snapshot numeric(12,2),
  ADD COLUMN IF NOT EXISTS change_snapshot numeric(12,2),
  ADD COLUMN IF NOT EXISTS payment_snapshot_at timestamptz;

CREATE OR REPLACE FUNCTION public.vortex_snapshot_delivery_payment_on_completion()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $function$
BEGIN
  IF NEW.status='delivered' AND OLD.status IS DISTINCT FROM 'delivered'
     AND NEW.payment_snapshot_at IS NULL THEN
    SELECT o.payment,o.payment_status,o.total,o.cashgiven,o.change
    INTO NEW.payment_method_snapshot,NEW.payment_status_snapshot,
         NEW.amount_due_snapshot,NEW.cash_given_snapshot,NEW.change_snapshot
    FROM public.vortex_kds_orders o
    WHERE o.store_id=NEW.store_id AND o.id=NEW.order_id;
    NEW.payment_snapshot_at:=now();
  END IF;
  RETURN NEW;
END;
$function$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger
    WHERE tgname='trg_snapshot_delivery_payment_on_completion'
      AND tgrelid='public.vortex_delivery_route_stops'::regclass
      AND NOT tgisinternal
  ) THEN
    CREATE TRIGGER trg_snapshot_delivery_payment_on_completion
    BEFORE UPDATE OF status ON public.vortex_delivery_route_stops
    FOR EACH ROW
    EXECUTE FUNCTION public.vortex_snapshot_delivery_payment_on_completion();
  END IF;
END;
$$;

-- Backfill dos registros já concluídos: usa o último estado financeiro atualmente
-- disponível. Novas conclusões ficam congeladas automaticamente pelo trigger.
UPDATE public.vortex_delivery_route_stops s
SET payment_method_snapshot=o.payment,
    payment_status_snapshot=o.payment_status,
    amount_due_snapshot=o.total,
    cash_given_snapshot=o.cashgiven,
    change_snapshot=o.change,
    payment_snapshot_at=COALESCE(s.payment_snapshot_at,s.delivered_at,now())
FROM public.vortex_kds_orders o
WHERE o.store_id=s.store_id AND o.id=s.order_id
  AND s.status='delivered' AND s.payment_snapshot_at IS NULL;

-- Auditoria de alterações: mantém o evento existente e agora registra antes/depois,
-- usuário responsável e horário. Nenhum histórico anterior é apagado.
CREATE OR REPLACE FUNCTION public.rpc_update_delivery_payment(
  p_store_id uuid,
  p_order_id text,
  p_payment_method text,
  p_payment_status text DEFAULT NULL,
  p_cash_given numeric DEFAULT 0,
  p_change numeric DEFAULT 0
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $function$
DECLARE
  v_order public.vortex_kds_orders%ROWTYPE;
  v_method text;
  v_status text;
  v_route_id uuid;
  v_stop_id uuid;
  v_old_payment jsonb;
BEGIN
  IF auth.uid() IS NULL
     OR NOT (
       public.vortex_user_has_permission(p_store_id,'delivery.dispatch_manage')
       OR public.vortex_user_has_permission(p_store_id,'delivery.manage')
     ) THEN
    RAISE EXCEPTION 'Seu perfil não pode alterar o pagamento deste pedido.';
  END IF;

  v_method:=BTRIM(COALESCE(p_payment_method,''));
  IF v_method NOT IN (
    'Pix','Cartão de Débito (Maquininha)','Cartão de Crédito (Maquininha)',
    'Vale Refeição - VR (Maquininha)','Vale Alimentação - VA (Maquininha)','Dinheiro'
  ) THEN
    RAISE EXCEPTION 'Selecione uma forma de pagamento válida.';
  END IF;

  IF lower(v_method)='pix' THEN
    IF p_payment_status IS NULL OR p_payment_status NOT IN ('paid','pending') THEN
      RAISE EXCEPTION 'Informe se o Pix já foi pago.';
    END IF;
    v_status:=p_payment_status;
  ELSE
    v_status:=NULL;
  END IF;

  IF COALESCE(p_cash_given,0)<0 OR COALESCE(p_change,0)<0 THEN
    RAISE EXCEPTION 'Os valores de dinheiro e troco não podem ser negativos.';
  END IF;

  SELECT * INTO v_order
  FROM public.vortex_kds_orders
  WHERE store_id=p_store_id AND id=p_order_id
    AND COALESCE(origin,'') ILIKE '%Delivery%'
  FOR UPDATE;

  IF NOT FOUND OR v_order.status IN ('finished','cancelled') THEN
    RAISE EXCEPTION 'Pedido de delivery ativo não encontrado.';
  END IF;

  IF v_method='Dinheiro' AND COALESCE(p_cash_given,0)<COALESCE(v_order.total,0) THEN
    RAISE EXCEPTION 'O valor recebido em dinheiro é menor que o total do pedido.';
  END IF;

  v_old_payment:=jsonb_build_object('payment_method',v_order.payment,
    'payment_status',v_order.payment_status,'cash_given',v_order.cashgiven,'change',v_order.change);

  UPDATE public.vortex_kds_orders
  SET payment=v_method,
      payment_status=v_status,
      cashgiven=CASE WHEN v_method='Dinheiro' THEN COALESCE(p_cash_given,0) ELSE 0 END,
      change=CASE WHEN v_method='Dinheiro' THEN COALESCE(p_change,0) ELSE 0 END,
      updated_at=now()
  WHERE store_id=p_store_id AND id=p_order_id;

  SELECT s.route_id,s.id INTO v_route_id,v_stop_id
  FROM public.vortex_delivery_route_stops s
  JOIN public.vortex_delivery_routes r ON r.store_id=s.store_id AND r.id=s.route_id
  WHERE s.store_id=p_store_id AND s.order_id=p_order_id
    AND r.status IN ('assigned','in_route')
    AND s.status IN ('assigned','in_progress','occurrence')
  LIMIT 1;

  IF v_route_id IS NOT NULL THEN
    UPDATE public.vortex_delivery_routes
    SET route_version=route_version+1,updated_at=now()
    WHERE store_id=p_store_id AND id=v_route_id;

    INSERT INTO public.vortex_delivery_route_events(
      store_id,route_id,stop_id,order_id,actor_user_id,event_type,details
    ) VALUES (
      p_store_id,v_route_id,v_stop_id,p_order_id,auth.uid(),'delivery_payment_updated',
      jsonb_build_object('previous',v_old_payment,
        'current',jsonb_build_object('payment_method',v_method,'payment_status',v_status,
          'amount_due',v_order.total,'cash_given',CASE WHEN v_method='Dinheiro' THEN COALESCE(p_cash_given,0) ELSE 0 END,
          'change',CASE WHEN v_method='Dinheiro' THEN COALESCE(p_change,0) ELSE 0 END),
        'changed_at',now(),'changed_by_user_id',auth.uid())
    );
  END IF;

  RETURN jsonb_build_object('success',true,'payment_method',v_method,'payment_status',v_status);
END;
$function$;

-- Histórico individual do motoboy com pagamento congelado, comprovante e eventos.
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
    'payment_method',COALESCE(s.payment_method_snapshot,o.payment),
    'payment_status',COALESCE(s.payment_status_snapshot,o.payment_status),
    'amount_due',COALESCE(s.amount_due_snapshot,o.total),
    'cash_given',COALESCE(s.cash_given_snapshot,o.cashgiven),
    'change',COALESCE(s.change_snapshot,o.change),
    'payment_snapshot_at',s.payment_snapshot_at,
    'completion_method',(SELECT e.details->>'method'
          FROM public.vortex_delivery_route_events e
          WHERE e.store_id=s.store_id AND e.stop_id=s.id
            AND e.event_type='delivery_confirmed'
          ORDER BY e.created_at DESC LIMIT 1),
    'completion_actor_user_id',(SELECT e.actor_user_id
          FROM public.vortex_delivery_route_events e
          WHERE e.store_id=s.store_id AND e.stop_id=s.id
            AND e.event_type='delivery_confirmed'
          ORDER BY e.created_at DESC LIMIT 1),
    'events',(SELECT COALESCE(jsonb_agg(jsonb_build_object(
            'event_type',e.event_type,'created_at',e.created_at,
            'actor_user_id',e.actor_user_id,'details',e.details
          ) ORDER BY e.created_at),'[]'::jsonb)
          FROM public.vortex_delivery_route_events e
          WHERE e.store_id=s.store_id AND e.route_id=s.route_id
            AND (e.stop_id=s.id OR e.order_id=s.order_id)),
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

-- Histórico da central com as mesmas informações financeiras e trilha de eventos.
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
    'payment_method',COALESCE(s.payment_method_snapshot,o.payment),
    'payment_status',COALESCE(s.payment_status_snapshot,o.payment_status),
    'amount_due',COALESCE(s.amount_due_snapshot,o.total),
    'cash_given',COALESCE(s.cash_given_snapshot,o.cashgiven),
    'change',COALESCE(s.change_snapshot,o.change),
    'payment_snapshot_at',s.payment_snapshot_at,
    'completion_method',(SELECT e.details->>'method'
          FROM public.vortex_delivery_route_events e
          WHERE e.store_id=s.store_id AND e.stop_id=s.id
            AND e.event_type='delivery_confirmed'
          ORDER BY e.created_at DESC LIMIT 1),
    'completion_actor_user_id',(SELECT e.actor_user_id
          FROM public.vortex_delivery_route_events e
          WHERE e.store_id=s.store_id AND e.stop_id=s.id
            AND e.event_type='delivery_confirmed'
          ORDER BY e.created_at DESC LIMIT 1),
    'events',(SELECT COALESCE(jsonb_agg(jsonb_build_object(
            'event_type',e.event_type,'created_at',e.created_at,
            'actor_user_id',e.actor_user_id,'details',e.details
          ) ORDER BY e.created_at),'[]'::jsonb)
          FROM public.vortex_delivery_route_events e
          WHERE e.store_id=s.store_id AND e.route_id=s.route_id
            AND (e.stop_id=s.id OR e.order_id=s.order_id)),
    'distance_km',s.distance_km,
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

-- Rotas ativas e entregas concluídas hoje: sincroniza os snapshots e eventos.
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
          'address',o.address,'items',o.items,
          'payment_method',CASE WHEN s.status='delivered' THEN COALESCE(s.payment_method_snapshot,o.payment) ELSE o.payment END,
          'payment_status',CASE WHEN s.status='delivered' THEN COALESCE(s.payment_status_snapshot,o.payment_status) ELSE o.payment_status END,
          'requires_customer_code',EXISTS (
            SELECT 1
            FROM public.vortex_delivery_verifications v
            WHERE v.store_id=o.store_id AND v.order_id=o.id
              AND v.is_active=true AND v.consumed_at IS NULL
              AND v.expires_at>now()
          ),
          'amount_due',CASE WHEN s.status='delivered' THEN COALESCE(s.amount_due_snapshot,o.total) ELSE o.total END,
          'cash_given',CASE WHEN s.status='delivered' THEN COALESCE(s.cash_given_snapshot,o.cashgiven) ELSE o.cashgiven END,
          'change',CASE WHEN s.status='delivered' THEN COALESCE(s.change_snapshot,o.change) ELSE o.change END,
          'payment_snapshot_at',s.payment_snapshot_at,
          'events',(SELECT COALESCE(jsonb_agg(jsonb_build_object(
            'event_type',e.event_type,'created_at',e.created_at,
            'actor_user_id',e.actor_user_id,'details',e.details
          ) ORDER BY e.created_at),'[]'::jsonb)
          FROM public.vortex_delivery_route_events e
          WHERE e.store_id=s.store_id AND e.route_id=s.route_id
            AND (e.stop_id=s.id OR e.order_id=s.order_id)),
          'completion_method',(SELECT e.details->>'method'
          FROM public.vortex_delivery_route_events e
          WHERE e.store_id=s.store_id AND e.stop_id=s.id
            AND e.event_type='delivery_confirmed'
          ORDER BY e.created_at DESC LIMIT 1),
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

-- Central do estabelecimento: inclui pagamentos e eventos por parada.
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
          ORDER BY e.created_at DESC LIMIT 50
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
          'address',o.address,'order_status',o.status,
          'payment_method',CASE WHEN s.status='delivered' THEN COALESCE(s.payment_method_snapshot,o.payment) ELSE o.payment END,
          'payment_status',CASE WHEN s.status='delivered' THEN COALESCE(s.payment_status_snapshot,o.payment_status) ELSE o.payment_status END,
          'amount_due',CASE WHEN s.status='delivered' THEN COALESCE(s.amount_due_snapshot,o.total) ELSE o.total END,
          'cash_given',CASE WHEN s.status='delivered' THEN COALESCE(s.cash_given_snapshot,o.cashgiven) ELSE o.cashgiven END,
          'change',CASE WHEN s.status='delivered' THEN COALESCE(s.change_snapshot,o.change) ELSE o.change END,
          'payment_snapshot_at',s.payment_snapshot_at,
          'events',(SELECT COALESCE(jsonb_agg(jsonb_build_object(
            'event_type',e.event_type,'created_at',e.created_at,
            'actor_user_id',e.actor_user_id,'details',e.details
          ) ORDER BY e.created_at),'[]'::jsonb)
          FROM public.vortex_delivery_route_events e
          WHERE e.store_id=s.store_id AND e.route_id=s.route_id
            AND (e.stop_id=s.id OR e.order_id=s.order_id)),
          'completion_method',(SELECT e.details->>'method'
          FROM public.vortex_delivery_route_events e
          WHERE e.store_id=s.store_id AND e.stop_id=s.id
            AND e.event_type='delivery_confirmed'
          ORDER BY e.created_at DESC LIMIT 1)
        ) ORDER BY s.sequence_number)
        FROM public.vortex_delivery_route_stops s
        LEFT JOIN public.vortex_kds_orders o
          ON o.store_id=s.store_id AND o.id=s.order_id
        WHERE s.store_id=r.store_id AND s.route_id=r.id
          AND (s.status IN ('assigned','in_progress','occurrence')
            OR (s.status='delivered'
              AND s.delivered_at >= (((now() AT TIME ZONE 'America/Sao_Paulo')::date::timestamp AT TIME ZONE 'America/Sao_Paulo'))
              AND s.delivered_at < (((now() AT TIME ZONE 'America/Sao_Paulo')::date+1)::timestamp AT TIME ZONE 'America/Sao_Paulo')))
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

REVOKE ALL ON FUNCTION public.rpc_update_delivery_payment(uuid,text,text,text,numeric,numeric) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.rpc_get_my_delivery_history(uuid,date,date) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.rpc_get_delivery_dispatch_history(uuid,date,date) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.rpc_get_my_delivery_routes(uuid) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.rpc_get_delivery_dispatch_routes(uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.rpc_update_delivery_payment(uuid,text,text,text,numeric,numeric) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_get_my_delivery_history(uuid,date,date) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_get_delivery_dispatch_history(uuid,date,date) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_get_my_delivery_routes(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_get_delivery_dispatch_routes(uuid) TO authenticated;

COMMIT;
