-- VORTEX FOOD: centraliza a criação de pedidos KDS em RPC segura.
-- Bloqueia INSERT direto autenticado para impedir contorno das validações de venda/permissão.

BEGIN;

CREATE OR REPLACE FUNCTION public.rpc_create_kds_order(
  p_store_id uuid,
  p_order jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $function$
DECLARE
  v_order_id text;
  v_origin text;
  v_total numeric;
  v_items jsonb;
  v_status text;
BEGIN
  IF auth.uid() IS NULL OR NOT public.vortex_user_has_store_access(p_store_id) THEN
    RAISE EXCEPTION 'Acesso não autorizado.';
  END IF;

  IF jsonb_typeof(p_order) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'Dados do pedido inválidos.';
  END IF;

  v_order_id := NULLIF(BTRIM(p_order->>'id'),'');
  v_origin := COALESCE(NULLIF(BTRIM(p_order->>'origin'),''),'Balcão');
  v_total := COALESCE(NULLIF(p_order->>'total','')::numeric,0);
  v_items := COALESCE(p_order->'items','[]'::jsonb);
  v_status := COALESCE(NULLIF(p_order->>'status',''),'new');

  IF v_order_id IS NULL OR length(v_order_id)>120 OR v_total<0 THEN
    RAISE EXCEPTION 'Identificação ou valor do pedido inválido.';
  END IF;
  IF jsonb_typeof(v_items) IS DISTINCT FROM 'array' THEN
    RAISE EXCEPTION 'Os itens do pedido precisam estar em uma lista válida.';
  END IF;
  IF v_status NOT IN ('new','received') THEN
    RAISE EXCEPTION 'Status inicial de pedido inválido.';
  END IF;

  IF v_origin ILIKE '%delivery%' THEN
    IF NOT public.vortex_user_has_permission(p_store_id,'delivery.manage') THEN
      RAISE EXCEPTION 'Seu perfil não pode registrar este pedido de delivery.';
    END IF;
  ELSIF v_origin ILIKE '%mesa%' THEN
    IF NOT (
         public.vortex_user_has_permission(p_store_id,'tables.open')
         OR public.vortex_user_has_permission(p_store_id,'tables.close')
       ) THEN
      RAISE EXCEPTION 'Seu perfil não pode registrar este pedido de mesa.';
    END IF;
  ELSE
    IF NOT public.vortex_user_has_permission(p_store_id,'pdv.sell') THEN
      RAISE EXCEPTION 'Seu perfil não pode registrar este pedido no PDV.';
    END IF;
  END IF;

  INSERT INTO public.vortex_kds_orders (
    store_id,id,origin,client,address,payment,cashgiven,change,
    time,date,items,total,observation,status,code,updated_at
  ) VALUES (
    p_store_id,
    v_order_id,
    left(v_origin,80),
    left(COALESCE(NULLIF(p_order->>'client',''),'Cliente'),180),
    left(COALESCE(p_order->>'address',''),500),
    left(COALESCE(p_order->>'payment',p_order->>'payMethod','Dinheiro'),80),
    COALESCE(NULLIF(p_order->>'cashgiven','')::numeric,0),
    COALESCE(NULLIF(p_order->>'change','')::numeric,0),
    left(COALESCE(p_order->>'time',''),20),
    COALESCE(NULLIF(p_order->>'date','')::date,current_date),
    v_items,
    v_total,
    left(COALESCE(p_order->>'observation',''),2000),
    v_status,
    '',
    now()
  );

  RETURN jsonb_build_object('success',true,'order_id',v_order_id);
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_create_kds_order(uuid,jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_create_kds_order(uuid,jsonb) TO authenticated;

DROP POLICY IF EXISTS vortex_kds_orders_permission_insert ON public.vortex_kds_orders;
REVOKE INSERT ON TABLE public.vortex_kds_orders FROM anon, authenticated;

COMMIT;
