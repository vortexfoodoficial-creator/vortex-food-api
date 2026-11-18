-- Etapa 5: edição segura de paradas e prazos da rota.
-- Migração aditiva. Não executar automaticamente; revisar e aplicar manualmente no Supabase.

BEGIN;

CREATE OR REPLACE FUNCTION public.rpc_update_delivery_route_stops(
  p_store_id uuid,
  p_route_id uuid,
  p_expected_version integer,
  p_order_ids text[]
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $function$
DECLARE
  v_route public.vortex_delivery_routes%ROWTYPE;
  v_courier_name text;
  v_existing_count integer;
  v_valid_count integer;
  v_order_id text;
  v_sequence integer := 0;
  v_previous_ids text[];
BEGIN
  IF auth.uid() IS NULL
     OR NOT public.vortex_user_has_permission(p_store_id,'delivery.dispatch_manage') THEN
    RAISE EXCEPTION 'Seu perfil não pode editar as paradas desta rota.';
  END IF;

  IF p_expected_version IS NULL OR p_order_ids IS NULL
     OR cardinality(p_order_ids) < 1 OR cardinality(p_order_ids) > 20
     OR array_position(p_order_ids,NULL) IS NOT NULL
     OR EXISTS (SELECT 1 FROM unnest(p_order_ids) AS x(order_id)
                GROUP BY x.order_id HAVING count(*) > 1) THEN
    RAISE EXCEPTION 'Informe entre 1 e 20 pedidos diferentes e uma versão válida da rota.';
  END IF;

  SELECT * INTO v_route
  FROM public.vortex_delivery_routes
  WHERE store_id=p_store_id AND id=p_route_id
  FOR UPDATE;

  IF NOT FOUND OR v_route.status<>'assigned' THEN
    RAISE EXCEPTION 'Somente rotas que ainda aguardam saída podem ter paradas adicionadas, removidas ou reordenadas.';
  END IF;
  IF v_route.route_version<>p_expected_version THEN
    RAISE EXCEPTION 'A rota foi atualizada por outra pessoa. Atualize a central antes de tentar novamente.';
  END IF;

  SELECT COALESCE(NULLIF(display_name,''),'Motoboy')
  INTO v_courier_name
  FROM public.vortex_store_members
  WHERE store_id=p_store_id AND user_id=v_route.courier_user_id
    AND status='active' AND profile_key='delivery';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'A conta do motoboy não está mais ativa neste estabelecimento.';
  END IF;

  SELECT count(*) INTO v_existing_count
  FROM public.vortex_delivery_route_stops
  WHERE store_id=p_store_id AND route_id=p_route_id
    AND status NOT IN ('cancelled','returned');
  IF EXISTS (
    SELECT 1 FROM public.vortex_delivery_route_stops
    WHERE store_id=p_store_id AND route_id=p_route_id
      AND status IN ('in_progress','occurrence','delivered','returned')
  ) THEN
    RAISE EXCEPTION 'Esta rota contém uma parada iniciada ou encerrada e não pode ser reorganizada.';
  END IF;

  PERFORM 1
  FROM public.vortex_kds_orders o
  WHERE o.store_id=p_store_id AND o.id=ANY(p_order_ids)
  ORDER BY o.id
  FOR UPDATE;

  SELECT count(*) INTO v_valid_count
  FROM public.vortex_kds_orders o
  WHERE o.store_id=p_store_id AND o.id=ANY(p_order_ids)
    AND COALESCE(o.origin,'') ILIKE '%Delivery%'
    AND o.status NOT IN ('finished','cancelled')
    AND (o.courier_member_id IS NULL OR o.courier_member_id=v_route.courier_user_id)
    AND (COALESCE(o.courier,'')='' OR o.courier=v_courier_name)
    AND NOT EXISTS (
      SELECT 1 FROM public.vortex_delivery_route_stops other_stop
      JOIN public.vortex_delivery_routes other_route
        ON other_route.store_id=other_stop.store_id AND other_route.id=other_stop.route_id
      WHERE other_stop.store_id=p_store_id AND other_stop.order_id=o.id
        AND other_stop.route_id<>p_route_id
        AND other_stop.status IN ('assigned','in_progress','occurrence')
        AND other_route.status IN ('assigned','in_route')
    );

  IF v_valid_count<>cardinality(p_order_ids) THEN
    RAISE EXCEPTION 'Um ou mais pedidos não estão disponíveis, não são delivery ou pertencem a outra rota.';
  END IF;

  SELECT COALESCE(array_agg(order_id ORDER BY sequence_number),'{}'::text[])
  INTO v_previous_ids
  FROM public.vortex_delivery_route_stops
  WHERE store_id=p_store_id AND route_id=p_route_id
    AND status='assigned';

  -- Paradas removidas são mantidas no histórico e marcadas como canceladas.
  UPDATE public.vortex_delivery_route_stops s
  SET status='cancelled',updated_at=now()
  WHERE s.store_id=p_store_id AND s.route_id=p_route_id
    AND s.status='assigned' AND NOT (s.order_id=ANY(p_order_ids));

  UPDATE public.vortex_kds_orders o
  SET courier_member_id=NULL,courier='',updated_at=now()
  WHERE o.store_id=p_store_id AND o.id=ANY(COALESCE(v_previous_ids,'{}'::text[]))
    AND NOT (o.id=ANY(p_order_ids))
    AND o.courier_member_id=v_route.courier_user_id;

  -- Libera temporariamente as posições para permitir qualquer permutação sem colidir com a constraint UNIQUE.
  UPDATE public.vortex_delivery_route_stops
  SET sequence_number=sequence_number+1000,updated_at=now()
  WHERE store_id=p_store_id AND route_id=p_route_id;

  FOREACH v_order_id IN ARRAY p_order_ids LOOP
    v_sequence:=v_sequence+1;
    IF EXISTS (
      SELECT 1 FROM public.vortex_delivery_route_stops
      WHERE store_id=p_store_id AND route_id=p_route_id AND order_id=v_order_id
    ) THEN
      UPDATE public.vortex_delivery_route_stops
      SET sequence_number=v_sequence,status='assigned',updated_at=now()
      WHERE store_id=p_store_id AND route_id=p_route_id AND order_id=v_order_id;
    ELSE
      INSERT INTO public.vortex_delivery_route_stops(
        store_id,route_id,order_id,sequence_number,status
      ) VALUES (p_store_id,p_route_id,v_order_id,v_sequence,'assigned');
    END IF;

    UPDATE public.vortex_kds_orders
    SET courier_member_id=v_route.courier_user_id,courier=v_courier_name,updated_at=now()
    WHERE store_id=p_store_id AND id=v_order_id;
  END LOOP;

  UPDATE public.vortex_delivery_routes
  SET route_version=route_version+1,updated_at=now()
  WHERE store_id=p_store_id AND id=p_route_id;

  INSERT INTO public.vortex_delivery_route_events(
    store_id,route_id,actor_user_id,event_type,details
  ) VALUES (
    p_store_id,p_route_id,auth.uid(),'route_stops_updated',
    jsonb_build_object(
      'previous_order_ids',COALESCE(v_previous_ids,'{}'::text[]),
      'new_order_ids',p_order_ids,
      'added_order_ids',ARRAY(SELECT x FROM unnest(p_order_ids) x WHERE NOT (x=ANY(COALESCE(v_previous_ids,'{}'::text[])))),
      'removed_order_ids',ARRAY(SELECT x FROM unnest(COALESCE(v_previous_ids,'{}'::text[])) x WHERE NOT (x=ANY(p_order_ids)))
    )
  );

  RETURN jsonb_build_object('success',true,'route_id',p_route_id,
    'route_version',v_route.route_version+1,'stop_count',cardinality(p_order_ids));
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpc_set_delivery_stop_deadline(
  p_store_id uuid,
  p_route_id uuid,
  p_order_id text,
  p_expected_version integer,
  p_promised_delivery_at timestamptz
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $function$
DECLARE
  v_route public.vortex_delivery_routes%ROWTYPE;
  v_stop public.vortex_delivery_route_stops%ROWTYPE;
  v_previous_deadline timestamptz;
BEGIN
  IF auth.uid() IS NULL
     OR NOT public.vortex_user_has_permission(p_store_id,'delivery.dispatch_manage') THEN
    RAISE EXCEPTION 'Seu perfil não pode alterar o prazo desta entrega.';
  END IF;
  IF p_expected_version IS NULL OR
     (p_promised_delivery_at IS NOT NULL AND
      (p_promised_delivery_at<now()-interval '1 day' OR p_promised_delivery_at>now()+interval '30 days')) THEN
    RAISE EXCEPTION 'Prazo ou versão informados são inválidos.';
  END IF;

  SELECT * INTO v_route
  FROM public.vortex_delivery_routes
  WHERE store_id=p_store_id AND id=p_route_id
    AND status IN ('assigned','in_route')
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Rota ativa não encontrada.'; END IF;
  IF v_route.route_version<>p_expected_version THEN
    RAISE EXCEPTION 'A rota foi atualizada por outra pessoa. Atualize a central antes de alterar o prazo.';
  END IF;

  SELECT * INTO v_stop
  FROM public.vortex_delivery_route_stops
  WHERE store_id=p_store_id AND route_id=p_route_id
    AND order_id=p_order_id AND status IN ('assigned','in_progress','occurrence')
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Parada ativa não encontrada nesta rota.'; END IF;

  v_previous_deadline:=v_stop.promised_delivery_at;
  UPDATE public.vortex_delivery_route_stops
  SET promised_delivery_at=p_promised_delivery_at,updated_at=now()
  WHERE store_id=p_store_id AND id=v_stop.id;

  UPDATE public.vortex_delivery_routes
  SET route_version=route_version+1,updated_at=now()
  WHERE store_id=p_store_id AND id=p_route_id;

  INSERT INTO public.vortex_delivery_route_events(
    store_id,route_id,stop_id,order_id,actor_user_id,event_type,details
  ) VALUES (
    p_store_id,p_route_id,v_stop.id,p_order_id,auth.uid(),'delivery_deadline_updated',
    jsonb_build_object('previous_deadline',v_previous_deadline,
      'new_deadline',p_promised_delivery_at)
  );

  RETURN jsonb_build_object('success',true,'route_id',p_route_id,
    'route_version',v_route.route_version+1,'order_id',p_order_id,
    'promised_delivery_at',p_promised_delivery_at);
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_update_delivery_route_stops(uuid,uuid,integer,text[]) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.rpc_set_delivery_stop_deadline(uuid,uuid,text,integer,timestamptz) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.rpc_update_delivery_route_stops(uuid,uuid,integer,text[]) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_set_delivery_stop_deadline(uuid,uuid,text,integer,timestamptz) TO authenticated;

COMMIT;
