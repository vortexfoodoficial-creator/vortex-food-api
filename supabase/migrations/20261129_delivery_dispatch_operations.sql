-- VORTEX FOOD: operações centrais de despacho de rotas.
-- Migração aditiva; não remove nem reescreve pedidos existentes.
-- Revisar e executar manualmente no Supabase.

BEGIN;

INSERT INTO public.vortex_permission_catalog(permission_key,module_key,action_key,label,description)
VALUES
  ('delivery.dispatch_view','delivery','dispatch_view','Visualizar central de rotas','Acompanhar rotas, paradas e disponibilidade dos motoboys.'),
  ('delivery.dispatch_manage','delivery','dispatch_manage','Gerenciar despacho','Transferir rotas, tratar ocorrências e cancelar rotas ainda não iniciadas.')
ON CONFLICT (permission_key) DO UPDATE
SET module_key=EXCLUDED.module_key,action_key=EXCLUDED.action_key,
    label=EXCLUDED.label,description=EXCLUDED.description;

INSERT INTO public.vortex_profile_permissions(profile_key,permission_key,allowed)
VALUES
  ('owner','delivery.dispatch_view',true),
  ('owner','delivery.dispatch_manage',true),
  ('administrator','delivery.dispatch_view',true),
  ('administrator','delivery.dispatch_manage',true),
  ('manager','delivery.dispatch_view',true),
  ('manager','delivery.dispatch_manage',true),
  ('attendant','delivery.dispatch_view',false),
  ('attendant','delivery.dispatch_manage',false),
  ('delivery','delivery.dispatch_view',false),
  ('delivery','delivery.dispatch_manage',false)
ON CONFLICT (profile_key,permission_key) DO UPDATE SET allowed=EXCLUDED.allowed;

-- Consulta da central: somente dados operacionais, sem dados financeiros completos.
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
      'courier_name',COALESCE(NULLIF(u.raw_user_meta_data->>'display_name',''),'Motoboy'),
      'assigned_at',r.assigned_at,'started_at',r.started_at,
      'completed_at',r.completed_at,'cancelled_at',r.cancelled_at,
      'presence_status',COALESCE(cp.status,'unavailable'),
      'presence_updated_at',cp.updated_at,
      'stop_count',COALESCE(stats.stop_count,0),
      'delivered_count',COALESCE(stats.delivered_count,0),
      'occurrence_count',COALESCE(stats.occurrence_count,0),
      'returned_count',COALESCE(stats.returned_count,0),
      'stops',COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'stop_id',s.id,'order_id',s.order_id,
          'sequence_number',s.sequence_number,'status',s.status,
          'occurrence_type',s.occurrence_type,'occurrence_notes',s.occurrence_notes,
          'occurrence_at',s.occurrence_at,'promised_delivery_at',s.promised_delivery_at,
          'started_at',s.started_at,'delivered_at',s.delivered_at,
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
  LEFT JOIN public.vortex_delivery_courier_presence cp
    ON cp.store_id=r.store_id AND cp.courier_user_id=r.courier_user_id
  LEFT JOIN LATERAL (
    SELECT count(*)::integer AS stop_count,
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

-- Disponibilidade de todos os motoboys ativos do estabelecimento, mesmo sem rota.
CREATE OR REPLACE FUNCTION public.rpc_get_delivery_dispatch_couriers(p_store_id uuid)
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
    RAISE EXCEPTION 'Seu perfil não pode visualizar a disponibilidade dos motoboys.';
  END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'user_id',m.user_id,
    'name',COALESCE(NULLIF(u.raw_user_meta_data->>'display_name',''),'Motoboy'),
    'phone',COALESCE(u.phone,u.raw_user_meta_data->>'phone',''),
    'presence_status',COALESCE(cp.status,'unavailable'),
    'presence_updated_at',cp.updated_at,
    'active_route_id',r.id,
    'route_status',r.status
  ) ORDER BY
    CASE COALESCE(cp.status,'unavailable')
      WHEN 'available' THEN 0 WHEN 'in_route' THEN 1 WHEN 'paused' THEN 2 ELSE 3 END,
    COALESCE(NULLIF(u.raw_user_meta_data->>'display_name',''),'Motoboy')
  ),'[]'::jsonb)
  INTO v_result
  FROM public.vortex_store_members m
  JOIN auth.users u ON u.id=m.user_id
  LEFT JOIN public.vortex_delivery_courier_presence cp
    ON cp.store_id=m.store_id AND cp.courier_user_id=m.user_id
  LEFT JOIN public.vortex_delivery_routes r
    ON r.store_id=m.store_id AND r.courier_user_id=m.user_id
    AND r.status IN ('assigned','in_route')
  WHERE m.store_id=p_store_id AND m.status='active'
    AND m.profile_key='delivery';

  RETURN v_result;
END;
$function$;

-- Transferência preserva a rota e a sequência; pode ocorrer durante o trajeto.
CREATE OR REPLACE FUNCTION public.rpc_transfer_delivery_route(
  p_store_id uuid,p_route_id uuid,p_new_courier_user_id uuid
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
  IF NOT FOUND THEN RAISE EXCEPTION 'Rota ativa não encontrada.'; END IF;

  IF v_route.courier_user_id=p_new_courier_user_id THEN
    RAISE EXCEPTION 'A rota já pertence a este motoboy.';
  END IF;

  SELECT COALESCE(NULLIF(u.raw_user_meta_data->>'display_name',''),'Motoboy')
  INTO v_new_name
  FROM auth.users u
  JOIN public.vortex_store_members m ON m.user_id=u.id
  WHERE u.id=p_new_courier_user_id AND m.store_id=p_store_id
    AND m.status='active' AND m.profile_key='delivery';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'O novo motoboy não possui conta ativa neste estabelecimento.';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.vortex_delivery_routes
    WHERE store_id=p_store_id AND courier_user_id=p_new_courier_user_id
      AND status IN ('assigned','in_route') AND id<>p_route_id
  ) THEN
    RAISE EXCEPTION 'Este motoboy já possui outra rota ativa.';
  END IF;

  v_old_courier:=v_route.courier_user_id;
  UPDATE public.vortex_delivery_routes
  SET courier_user_id=p_new_courier_user_id,
      route_version=route_version+1,updated_at=now()
  WHERE store_id=p_store_id AND id=p_route_id;

  UPDATE public.vortex_kds_orders o
  SET courier_member_id=p_new_courier_user_id,courier=v_new_name,updated_at=now()
  FROM public.vortex_delivery_route_stops s
  WHERE s.store_id=p_store_id AND s.route_id=p_route_id
    AND s.order_id=o.id AND o.store_id=s.store_id
    AND s.status IN ('assigned','in_progress','occurrence');

  UPDATE public.vortex_delivery_courier_presence
  SET status=CASE WHEN EXISTS (
      SELECT 1 FROM public.vortex_delivery_routes
      WHERE store_id=p_store_id AND courier_user_id=v_old_courier AND status='in_route'
    ) THEN 'in_route' ELSE 'available' END,
    updated_at=now()
  WHERE store_id=p_store_id AND courier_user_id=v_old_courier;

  INSERT INTO public.vortex_delivery_courier_presence(store_id,courier_user_id,status,updated_at)
  VALUES (p_store_id,p_new_courier_user_id,
    CASE WHEN v_route.status='in_route' THEN 'in_route' ELSE 'available' END,now())
  ON CONFLICT (store_id,courier_user_id)
  DO UPDATE SET status=EXCLUDED.status,updated_at=now();

  INSERT INTO public.vortex_delivery_route_events(
    store_id,route_id,actor_user_id,event_type,details
  ) VALUES (
    p_store_id,p_route_id,auth.uid(),'route_transferred',
    jsonb_build_object('previous_courier_user_id',v_old_courier,
      'new_courier_user_id',p_new_courier_user_id,
      'new_courier_name',v_new_name,'route_status',v_route.status,
      'route_version',v_route.route_version+1)
  );

  RETURN jsonb_build_object('success',true,'route_id',p_route_id,
    'courier_user_id',p_new_courier_user_id,'courier_name',v_new_name,
    'route_version',v_route.route_version+1);
END;
$function$;

-- Resolve ocorrência: retry devolve a parada à execução; returned registra retorno
-- sem declarar o pedido como entregue nem alterar seu status comercial.
CREATE OR REPLACE FUNCTION public.rpc_resolve_delivery_occurrence(
  p_store_id uuid,p_route_id uuid,p_order_id text,p_resolution text,p_notes text DEFAULT ''
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $function$
DECLARE
  v_route public.vortex_delivery_routes%ROWTYPE;
  v_stop public.vortex_delivery_route_stops%ROWTYPE;
  v_new_status text;
BEGIN
  IF auth.uid() IS NULL
     OR NOT public.vortex_user_has_permission(p_store_id,'delivery.dispatch_manage') THEN
    RAISE EXCEPTION 'Seu perfil não pode resolver ocorrências.';
  END IF;
  IF p_resolution NOT IN ('retry','returned')
     OR length(COALESCE(p_notes,''))>1000 THEN
    RAISE EXCEPTION 'Resolução ou observação inválida.';
  END IF;

  SELECT * INTO v_route FROM public.vortex_delivery_routes
  WHERE store_id=p_store_id AND id=p_route_id AND status='in_route'
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Rota em andamento não encontrada.'; END IF;

  SELECT * INTO v_stop FROM public.vortex_delivery_route_stops
  WHERE store_id=p_store_id AND route_id=p_route_id
    AND order_id=p_order_id AND status='occurrence'
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Ocorrência pendente não encontrada.'; END IF;

  v_new_status:=CASE WHEN p_resolution='retry' THEN 'in_progress' ELSE 'returned' END;
  UPDATE public.vortex_delivery_route_stops
  SET status=v_new_status,
      occurrence_notes=CASE WHEN COALESCE(p_notes,'')='' THEN occurrence_notes ELSE left(p_notes,1000) END,
      updated_at=now()
  WHERE store_id=p_store_id AND id=v_stop.id;

  INSERT INTO public.vortex_delivery_route_events(
    store_id,route_id,stop_id,order_id,actor_user_id,event_type,details
  ) VALUES (
    p_store_id,p_route_id,v_stop.id,p_order_id,auth.uid(),
    CASE WHEN p_resolution='retry' THEN 'occurrence_retry' ELSE 'delivery_returned' END,
    jsonb_build_object('previous_occurrence',v_stop.occurrence_type,
      'resolution',p_resolution,'notes',left(COALESCE(p_notes,''),1000))
  );

  IF p_resolution='returned' AND NOT EXISTS (
    SELECT 1 FROM public.vortex_delivery_route_stops
    WHERE store_id=p_store_id AND route_id=p_route_id
      AND status IN ('assigned','in_progress','occurrence')
  ) THEN
    UPDATE public.vortex_delivery_routes
    SET status='completed',completed_at=now(),updated_at=now()
    WHERE store_id=p_store_id AND id=p_route_id;
    UPDATE public.vortex_delivery_courier_presence
    SET status='available',updated_at=now()
    WHERE store_id=p_store_id AND courier_user_id=v_route.courier_user_id;
  END IF;

  RETURN jsonb_build_object('success',true,'stop_status',v_new_status);
END;
$function$;

-- Cancelamento só antes da saída: evita apagar uma rota que já está na rua.
CREATE OR REPLACE FUNCTION public.rpc_cancel_delivery_route(
  p_store_id uuid,p_route_id uuid,p_reason text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $function$
DECLARE
  v_route public.vortex_delivery_routes%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL
     OR NOT public.vortex_user_has_permission(p_store_id,'delivery.dispatch_manage') THEN
    RAISE EXCEPTION 'Seu perfil não pode cancelar rotas.';
  END IF;
  IF length(trim(COALESCE(p_reason,'')))<3 OR length(p_reason)>500 THEN
    RAISE EXCEPTION 'Informe um motivo de cancelamento (3 a 500 caracteres).';
  END IF;

  SELECT * INTO v_route FROM public.vortex_delivery_routes
  WHERE store_id=p_store_id AND id=p_route_id AND status='assigned'
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Somente rotas ainda não iniciadas podem ser canceladas por esta operação.';
  END IF;

  UPDATE public.vortex_delivery_routes
  SET status='cancelled',cancelled_at=now(),updated_at=now(),
      route_version=route_version+1
  WHERE store_id=p_store_id AND id=p_route_id;

  UPDATE public.vortex_delivery_route_stops
  SET status='cancelled',updated_at=now()
  WHERE store_id=p_store_id AND route_id=p_route_id AND status='assigned';

  UPDATE public.vortex_kds_orders o
  SET courier_member_id=NULL,courier='',updated_at=now()
  FROM public.vortex_delivery_route_stops s
  WHERE s.store_id=p_store_id AND s.route_id=p_route_id
    AND s.order_id=o.id AND o.store_id=s.store_id
    AND s.status='cancelled';

  UPDATE public.vortex_delivery_courier_presence
  SET status='available',updated_at=now()
  WHERE store_id=p_store_id AND courier_user_id=v_route.courier_user_id
    AND NOT EXISTS (
      SELECT 1 FROM public.vortex_delivery_routes
      WHERE store_id=p_store_id AND courier_user_id=v_route.courier_user_id
        AND status='in_route'
    );

  INSERT INTO public.vortex_delivery_route_events(
    store_id,route_id,actor_user_id,event_type,details
  ) VALUES (
    p_store_id,p_route_id,auth.uid(),'route_cancelled',
    jsonb_build_object('reason',trim(p_reason),'previous_status',v_route.status)
  );

  RETURN jsonb_build_object('success',true,'route_id',p_route_id,'status','cancelled');
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_get_delivery_dispatch_routes(uuid) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.rpc_get_delivery_dispatch_couriers(uuid) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.rpc_transfer_delivery_route(uuid,uuid,uuid) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.rpc_resolve_delivery_occurrence(uuid,uuid,text,text,text) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.rpc_cancel_delivery_route(uuid,uuid,text) FROM PUBLIC,anon;

GRANT EXECUTE ON FUNCTION public.rpc_get_delivery_dispatch_routes(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_get_delivery_dispatch_couriers(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_transfer_delivery_route(uuid,uuid,uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_resolve_delivery_occurrence(uuid,uuid,text,text,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_cancel_delivery_route(uuid,uuid,text) TO authenticated;

COMMIT;
