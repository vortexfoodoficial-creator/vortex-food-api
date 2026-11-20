-- VORTEX FOOD: preserva a disponibilidade declarada pelo motoboy durante transferências.
-- Substitui somente a RPC de transferência de rota; mantém assinatura e contrato de retorno.
-- Migração aditiva. Revisar e aplicar manualmente no Supabase.

BEGIN;

CREATE OR REPLACE FUNCTION public.rpc_transfer_delivery_route(
  p_store_id uuid,
  p_route_id uuid,
  p_new_courier_user_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $function$
DECLARE
  v_route public.vortex_delivery_routes%ROWTYPE;
  v_old_courier uuid;
  v_new_name text;
BEGIN
  IF auth.uid() IS NULL
     OR NOT public.vortex_user_has_permission(p_store_id,'delivery.dispatch_manage') THEN
    RAISE EXCEPTION 'Seu perfil não pode transferir rotas.';
  END IF;
  IF p_new_courier_user_id IS NULL THEN
    RAISE EXCEPTION 'Selecione o novo motoboy.';
  END IF;

  SELECT * INTO v_route
  FROM public.vortex_delivery_routes
  WHERE store_id=p_store_id AND id=p_route_id
    AND status IN ('assigned','in_route')
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Rota ativa não encontrada.';
  END IF;

  IF v_route.courier_user_id=p_new_courier_user_id THEN
    RAISE EXCEPTION 'A rota já pertence a este motoboy.';
  END IF;

  SELECT COALESCE(NULLIF(m.display_name,''),NULLIF(u.raw_user_meta_data->>'display_name',''),'Motoboy')
  INTO v_new_name
  FROM auth.users u
  JOIN public.vortex_store_members m ON m.user_id=u.id
  WHERE u.id=p_new_courier_user_id
    AND m.store_id=p_store_id
    AND m.status='active'
    AND m.profile_key='delivery'
  FOR UPDATE OF m;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'O novo motoboy não possui conta ativa neste estabelecimento.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.vortex_delivery_routes
    WHERE store_id=p_store_id
      AND courier_user_id=p_new_courier_user_id
      AND status IN ('assigned','in_route')
      AND id<>p_route_id
  ) THEN
    RAISE EXCEPTION 'Este motoboy já possui outra rota ativa.';
  END IF;

  v_old_courier:=v_route.courier_user_id;

  UPDATE public.vortex_delivery_routes
  SET courier_user_id=p_new_courier_user_id,
      route_version=route_version+1,
      updated_at=now()
  WHERE store_id=p_store_id AND id=p_route_id;

  -- Atualiza somente as paradas ainda sob responsabilidade da rota.
  -- Entregas concluídas mantêm o delivered_by_user_id histórico.
  UPDATE public.vortex_kds_orders o
  SET courier_member_id=p_new_courier_user_id,
      courier=v_new_name,
      updated_at=now()
  FROM public.vortex_delivery_route_stops s
  WHERE s.store_id=p_store_id
    AND s.route_id=p_route_id
    AND s.order_id=o.id
    AND o.store_id=s.store_id
    AND s.status IN ('assigned','in_progress','occurrence');

  -- Se a rota já estava na rua, o entregador anterior deixa de aparecer em rota.
  -- Se a rota ainda aguardava saída, não sobrescrevemos a disponibilidade manual dele.
  IF v_route.status='in_route' THEN
    UPDATE public.vortex_delivery_courier_presence
    SET status='available',updated_at=now()
    WHERE store_id=p_store_id
      AND courier_user_id=v_old_courier
      AND NOT EXISTS (
        SELECT 1
        FROM public.vortex_delivery_routes
        WHERE store_id=p_store_id
          AND courier_user_id=v_old_courier
          AND status='in_route'
          AND id<>p_route_id
      );
  END IF;

  -- Uma rota transferida que já estava em andamento exige estado operacional "em rota".
  -- Para rota ainda não iniciada, preserva disponível/pausado/indisponível já escolhido.
  IF v_route.status='in_route' THEN
    INSERT INTO public.vortex_delivery_courier_presence(store_id,courier_user_id,status,updated_at)
    VALUES (p_store_id,p_new_courier_user_id,'in_route',now())
    ON CONFLICT (store_id,courier_user_id)
    DO UPDATE SET status='in_route',updated_at=now();
  ELSE
    INSERT INTO public.vortex_delivery_courier_presence(store_id,courier_user_id,status,updated_at)
    VALUES (p_store_id,p_new_courier_user_id,'available',now())
    ON CONFLICT (store_id,courier_user_id) DO NOTHING;
  END IF;

  INSERT INTO public.vortex_delivery_route_events(
    store_id,route_id,actor_user_id,event_type,details
  ) VALUES (
    p_store_id,p_route_id,auth.uid(),'route_transferred',
    jsonb_build_object(
      'previous_courier_user_id',v_old_courier,
      'new_courier_user_id',p_new_courier_user_id,
      'new_courier_name',v_new_name,
      'route_status',v_route.status,
      'route_version',v_route.route_version+1
    )
  );

  RETURN jsonb_build_object(
    'success',true,
    'route_id',p_route_id,
    'courier_user_id',p_new_courier_user_id,
    'courier_name',v_new_name,
    'route_version',v_route.route_version+1
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_transfer_delivery_route(uuid,uuid,uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.rpc_transfer_delivery_route(uuid,uuid,uuid) TO authenticated;

COMMIT;
