-- VORTEX FOOD: sincronização de baixa manual, pagamentos e privacidade do código do cliente.
-- Aplique manualmente no Supabase depois das migrações 20261128–20261133.
-- Esta migração não remove tabelas nem dados de pedidos.

BEGIN;

ALTER TABLE public.vortex_kds_orders
  ADD COLUMN IF NOT EXISTS payment_status text;

DO $constraint$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname='vortex_kds_orders_delivery_payment_status_check'
      AND conrelid='public.vortex_kds_orders'::regclass
  ) THEN
    ALTER TABLE public.vortex_kds_orders
      ADD CONSTRAINT vortex_kds_orders_delivery_payment_status_check
      CHECK (payment_status IS NULL OR payment_status IN ('paid','pending'));
  END IF;
END;
$constraint$;

COMMENT ON COLUMN public.vortex_kds_orders.payment_status IS
  'Situação do Pix em pedidos de delivery: paid ou pending; NULL para outras formas de pagamento ou registros antigos sem confirmação.';

-- Os códigos dos pedidos online continuam sendo entregues pelo checkout ao cliente.
-- Códigos de pedidos manuais antigos são desativados: não existe checkout privado para eles.
UPDATE public.vortex_delivery_verifications v
SET is_active=false, consumed_at=COALESCE(v.consumed_at,now())
FROM public.vortex_kds_orders o
WHERE o.store_id=v.store_id AND o.id=v.order_id
  AND COALESCE(o.origin,'') NOT ILIKE '%online%'
  AND v.is_active=true;

-- Criação de rota não emite códigos para pedidos manuais.
-- Pedidos online preservam o código já emitido diretamente ao cliente no checkout.
CREATE OR REPLACE FUNCTION public.rpc_create_delivery_route(
  p_store_id uuid,
  p_courier_user_id uuid,
  p_order_ids text[]
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $function$
DECLARE
  v_route_id uuid;
  v_courier_name text;
  v_order_count integer;
BEGIN
  IF auth.uid() IS NULL
     OR NOT public.vortex_user_has_permission(p_store_id,'delivery.assign')
     OR NOT public.vortex_user_has_permission(p_store_id,'delivery.dispatch') THEN
    RAISE EXCEPTION 'Seu perfil não pode criar e atribuir rotas.';
  END IF;

  IF p_courier_user_id IS NULL
     OR p_order_ids IS NULL
     OR cardinality(p_order_ids)<1
     OR cardinality(p_order_ids)>20
     OR array_position(p_order_ids,NULL) IS NOT NULL
     OR EXISTS (SELECT 1 FROM unnest(p_order_ids) AS x(order_id) GROUP BY x.order_id HAVING count(*)>1) THEN
    RAISE EXCEPTION 'Selecione um motoboy e entre 1 e 20 pedidos diferentes.';
  END IF;

  SELECT COALESCE(NULLIF(display_name,''),'Motoboy')
  INTO v_courier_name
  FROM public.vortex_store_members
  WHERE store_id=p_store_id AND user_id=p_courier_user_id
    AND status='active' AND profile_key='delivery';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'O motoboy selecionado não possui uma conta ativa nesta loja.';
  END IF;

  PERFORM 1
  FROM public.vortex_kds_orders o
  WHERE o.store_id=p_store_id AND o.id=ANY(p_order_ids)
  ORDER BY o.id
  FOR UPDATE;

  SELECT count(*) INTO v_order_count
  FROM public.vortex_kds_orders o
  WHERE o.store_id=p_store_id AND o.id=ANY(p_order_ids)
    AND COALESCE(o.origin,'') ILIKE '%Delivery%'
    AND o.status NOT IN ('finished','cancelled');
  IF v_order_count<>cardinality(p_order_ids) THEN
    RAISE EXCEPTION 'Um ou mais pedidos não existem, não são delivery ou já foram encerrados.';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.vortex_kds_orders o
    WHERE o.store_id=p_store_id AND o.id=ANY(p_order_ids)
      AND o.courier_member_id IS NOT NULL
      AND o.courier_member_id<>p_courier_user_id
  ) THEN
    RAISE EXCEPTION 'Um ou mais pedidos já estão atribuídos a outro motoboy. Faça a transferência pela operação de despacho.';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.vortex_delivery_route_stops s
    WHERE s.store_id=p_store_id AND s.order_id=ANY(p_order_ids)
      AND s.status IN ('assigned','in_progress','occurrence')
  ) THEN
    RAISE EXCEPTION 'Um ou mais pedidos já pertencem a uma rota ativa.';
  END IF;

  INSERT INTO public.vortex_delivery_routes(store_id,courier_user_id,status,assigned_by)
  VALUES (p_store_id,p_courier_user_id,'assigned',auth.uid())
  RETURNING id INTO v_route_id;

  INSERT INTO public.vortex_delivery_route_stops(store_id,route_id,order_id,sequence_number)
  SELECT p_store_id,v_route_id,x.order_id,x.ordinality::integer
  FROM unnest(p_order_ids) WITH ORDINALITY AS x(order_id,ordinality);

  UPDATE public.vortex_kds_orders
  SET courier_member_id=p_courier_user_id,courier=v_courier_name,updated_at=now()
  WHERE store_id=p_store_id AND id=ANY(p_order_ids);

  INSERT INTO public.vortex_delivery_route_events(store_id,route_id,actor_user_id,event_type,details)
  VALUES (p_store_id,v_route_id,auth.uid(),'route_assigned',
    jsonb_build_object('courier_user_id',p_courier_user_id,'order_ids',to_jsonb(p_order_ids)));

  INSERT INTO public.vortex_delivery_courier_presence(store_id,courier_user_id,status,updated_at)
  VALUES (p_store_id,p_courier_user_id,'available',now())
  ON CONFLICT (store_id,courier_user_id) DO NOTHING;

  RETURN jsonb_build_object('success',true,'route_id',v_route_id,'status','assigned','order_count',cardinality(p_order_ids));
END;
$function$;

-- A central de rotas não pode consultar códigos de confirmação dos clientes.
REVOKE ALL ON FUNCTION public.rpc_get_delivery_route_codes(uuid,uuid) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.rpc_create_delivery_route(uuid,uuid,text[]) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.rpc_create_delivery_route(uuid,uuid,text[]) TO authenticated;

-- Baixa manual atualiza o pedido, a parada, o histórico e a disponibilidade do motoboy
-- na mesma transação usada pelo painel do estabelecimento.
CREATE OR REPLACE FUNCTION public.rpc_mark_delivery_manual(p_store_id uuid,p_order_id text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $function$
DECLARE
  v_order public.vortex_kds_orders%ROWTYPE;
  v_route_id uuid;
  v_stop_id uuid;
  v_route_courier uuid;
  v_courier_user_id uuid;
BEGIN
  IF auth.uid() IS NULL
     OR NOT public.vortex_user_has_permission(p_store_id,'delivery.manual_finish') THEN
    RAISE EXCEPTION 'Seu perfil não pode finalizar entregas manualmente.';
  END IF;

  SELECT * INTO v_order
  FROM public.vortex_kds_orders
  WHERE store_id=p_store_id AND id=p_order_id
    AND COALESCE(origin,'') ILIKE '%Delivery%'
  FOR UPDATE;

  IF NOT FOUND OR v_order.status IN ('finished','cancelled') THEN
    RETURN jsonb_build_object('success',false,'message','Pedido não encontrado, cancelado ou já finalizado.');
  END IF;
  IF v_order.status<>'delivering' THEN
    RETURN jsonb_build_object('success',false,'message','Somente pedidos que já estão em rota podem ser finalizados manualmente.');
  END IF;

  v_courier_user_id:=v_order.courier_member_id;

  UPDATE public.vortex_kds_orders
  SET status='finished',updated_at=now()
  WHERE store_id=p_store_id AND id=p_order_id;

  UPDATE public.vortex_delivery_verifications
  SET is_active=false,consumed_at=COALESCE(consumed_at,now())
  WHERE store_id=p_store_id AND order_id=p_order_id;

  UPDATE public.vortex_delivery_route_stops s
  SET status='delivered',
      delivered_at=now(),
      delivered_by_user_id=COALESCE(v_courier_user_id,r.courier_user_id,auth.uid()),
      updated_at=now()
  FROM public.vortex_delivery_routes r
  WHERE s.store_id=p_store_id AND s.order_id=p_order_id
    AND s.route_id=r.id AND r.store_id=s.store_id
    AND s.status IN ('assigned','in_progress','occurrence')
  RETURNING s.route_id,s.id,r.courier_user_id
  INTO v_route_id,v_stop_id,v_route_courier;

  IF v_route_id IS NOT NULL THEN
    INSERT INTO public.vortex_delivery_route_events(
      store_id,route_id,stop_id,order_id,actor_user_id,event_type,details
    ) VALUES (
      p_store_id,v_route_id,v_stop_id,p_order_id,auth.uid(),'delivery_confirmed',
      jsonb_build_object('confirmed_at',now(),'method','manual_by_store',
        'confirmed_by_user_id',auth.uid(),'courier_user_id',COALESCE(v_courier_user_id,v_route_courier))
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
      WHERE store_id=p_store_id
        AND courier_user_id=COALESCE(v_route_courier,v_courier_user_id);
    END IF;
  END IF;

  RETURN jsonb_build_object('success',true,'message','Entrega finalizada manualmente e sincronizada com a rota.');
END;
$function$;

-- Atualização segura da forma/situação de pagamento, inclusive depois do despacho.
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
BEGIN
  IF auth.uid() IS NULL
     OR NOT public.vortex_user_has_permission(p_store_id,'delivery.dispatch_manage') THEN
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
    IF p_payment_status NOT IN ('paid','pending') THEN
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
      jsonb_build_object('payment_method',v_method,'payment_status',v_status,'updated_at',now())
    );
  END IF;

  RETURN jsonb_build_object('success',true,'payment_method',v_method,'payment_status',v_status);
END;
$function$;

-- Consulta compacta para a tela do estabelecimento, sem expor códigos.
CREATE OR REPLACE FUNCTION public.rpc_get_delivery_payment_statuses(p_store_id uuid)
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
    RAISE EXCEPTION 'Seu perfil não pode consultar os pagamentos de delivery.';
  END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'order_id',o.id,'payment_method',o.payment,'payment_status',o.payment_status,
    'cash_given',o.cashgiven,'change',o.change
  ) ORDER BY o.updated_at DESC),'[]'::jsonb)
  INTO v_result
  FROM public.vortex_kds_orders o
  WHERE o.store_id=p_store_id
    AND COALESCE(o.origin,'') ILIKE '%Delivery%'
    AND o.status NOT IN ('finished','cancelled');
  RETURN v_result;
END;
$function$;

-- O motoboy consulta somente as próprias rotas; recebe situação do Pix e se o
-- pedido veio do checkout online, nunca o código de confirmação.
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
          'customer_name',regexp_replace(COALESCE(o.client,''),' \\([^()]*\\)$',''),
          'customer_phone',COALESCE((regexp_match(COALESCE(o.client,''),'\\(([^()]*)\\)$'))[1],''),
          'address',o.address,'items',o.items,'payment_method',o.payment,
          'payment_status',o.payment_status,
          'requires_customer_code',COALESCE(o.origin,'') ILIKE '%online%',
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

REVOKE ALL ON FUNCTION public.rpc_mark_delivery_manual(uuid,text) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.rpc_update_delivery_payment(uuid,text,text,text,numeric,numeric) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.rpc_get_delivery_payment_statuses(uuid) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.rpc_get_my_delivery_routes(uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.rpc_mark_delivery_manual(uuid,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_update_delivery_payment(uuid,text,text,text,numeric,numeric) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_get_delivery_payment_statuses(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_get_my_delivery_routes(uuid) TO authenticated;

COMMIT;
