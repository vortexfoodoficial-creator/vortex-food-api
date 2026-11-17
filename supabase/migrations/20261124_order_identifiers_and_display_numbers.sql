-- VORTEX FOOD: identificador técnico único + número amigável de exibição.
-- A migração é aditiva: preserva vendas/pedidos e não altera chaves primárias.
BEGIN;

DO $preflight$
BEGIN
  IF to_regclass('public.vortex_sales_history') IS NULL
     OR to_regclass('public.vortex_kds_orders') IS NULL THEN
    RAISE EXCEPTION 'Tabelas operacionais esperadas não encontradas. Migração cancelada.';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='public' AND table_name='vortex_kds_orders' AND column_name='displayId'
  ) THEN
    RAISE EXCEPTION 'A coluna displayId do KDS não existe. Migração cancelada sem alterar dados.';
  END IF;
  IF to_regprocedure('public.vortex_user_has_store_access(uuid)') IS NULL
     OR to_regprocedure('public.vortex_user_has_permission(uuid,text)') IS NULL THEN
    RAISE EXCEPTION 'Funções de autorização esperadas não encontradas. Migração cancelada.';
  END IF;
END;
$preflight$;

ALTER TABLE public.vortex_sales_history
  ADD COLUMN IF NOT EXISTS display_id text;

CREATE OR REPLACE FUNCTION public.rpc_create_sale(p_store_id uuid,p_sale jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $function$
DECLARE
  v_id text;
  v_display_id text;
  v_channel text;
  v_total numeric;
  v_subtotal numeric;
  v_discount numeric;
  v_status text;
  v_financial_status text;
  v_items jsonb;
  v_items_total numeric := 0;
BEGIN
  IF auth.uid() IS NULL OR NOT public.vortex_user_has_store_access(p_store_id) THEN
    RAISE EXCEPTION 'Acesso não autorizado.';
  END IF;
  IF jsonb_typeof(p_sale) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'Dados da venda inválidos.';
  END IF;

  v_id := NULLIF(BTRIM(p_sale->>'id'),'');
  v_display_id := NULLIF(BTRIM(COALESCE(p_sale->>'display_id',p_sale->>'displayId')),'');
  v_channel := COALESCE(p_sale->>'channel','');
  v_total := COALESCE(NULLIF(p_sale->>'total','')::numeric,0);
  v_subtotal := COALESCE(NULLIF(p_sale->>'subtotal','')::numeric,v_total);
  v_discount := COALESCE(NULLIF(p_sale->>'discount','')::numeric,0);
  v_status := COALESCE(NULLIF(p_sale->>'status',''),'completed');
  v_financial_status := COALESCE(NULLIF(p_sale->>'financial_status',''),'paid');
  v_items := COALESCE(p_sale->'items','[]'::jsonb);

  IF v_id IS NULL OR length(v_id)>120 OR v_channel='' THEN
    RAISE EXCEPTION 'Identificação ou canal da venda inválido.';
  END IF;
  IF v_total<0 OR v_subtotal<0 OR v_discount<0 OR v_discount>v_subtotal THEN
    RAISE EXCEPTION 'Valores da venda inválidos.';
  END IF;
  IF round(v_subtotal-v_discount,2)<>round(v_total,2) THEN
    RAISE EXCEPTION 'O total da venda não corresponde ao subtotal menos o desconto.';
  END IF;
  IF jsonb_typeof(v_items) IS DISTINCT FROM 'array' THEN
    RAISE EXCEPTION 'Os itens da venda precisam estar em uma lista válida.';
  END IF;

  SELECT COALESCE(SUM(
    COALESCE(
      NULLIF(x.item->>'total','')::numeric,
      COALESCE(NULLIF(x.item->>'price','')::numeric,0)
        * COALESCE(NULLIF(x.item->>'qty','')::numeric,NULLIF(x.item->>'quantity','')::numeric,1)
    )
  ),0)
  INTO v_items_total
  FROM jsonb_array_elements(v_items) AS x(item);

  IF round(v_items_total,2)<>round(v_subtotal,2) THEN
    RAISE EXCEPTION 'O subtotal não corresponde à soma dos itens da venda.';
  END IF;
  IF v_status NOT IN ('completed','finished','pending','processing') THEN
    RAISE EXCEPTION 'Status inicial de venda inválido.';
  END IF;
  IF v_financial_status NOT IN ('paid','pending') THEN
    RAISE EXCEPTION 'Situação financeira inicial inválida.';
  END IF;

  IF v_channel ILIKE '%Delivery%' THEN
    IF NOT public.vortex_user_has_permission(p_store_id,'delivery.manage') THEN
      RAISE EXCEPTION 'Seu perfil não pode registrar pedidos de delivery.';
    END IF;
  ELSIF v_channel ILIKE '%Mesa%' THEN
    IF NOT (
      public.vortex_user_has_permission(p_store_id,'tables.open')
      OR public.vortex_user_has_permission(p_store_id,'tables.close')
    ) THEN
      RAISE EXCEPTION 'Seu perfil não pode registrar vendas de mesa.';
    END IF;
  ELSIF NOT public.vortex_user_has_permission(p_store_id,'pdv.sell') THEN
    RAISE EXCEPTION 'Seu perfil não pode registrar vendas no PDV.';
  END IF;

  IF v_discount>0 AND NOT public.vortex_user_has_permission(p_store_id,'pdv.discount') THEN
    RAISE EXCEPTION 'Seu perfil não pode aplicar descontos.';
  END IF;

  INSERT INTO public.vortex_sales_history(
    store_id,id,display_id,client,channel,total,subtotal,discount,
    paymethod,pay_method,status,financial_status,date,time,items,updated_at
  ) VALUES (
    p_store_id,v_id,v_display_id,
    left(COALESCE(p_sale->>'client','Cliente Balcão'),180),
    left(v_channel,80),
    v_total,v_subtotal,v_discount,
    left(COALESCE(p_sale->>'pay_method',p_sale->>'payMethod',p_sale->>'paymentMethod','PIX'),80),
    left(COALESCE(p_sale->>'pay_method',p_sale->>'payMethod',p_sale->>'paymentMethod','PIX'),80),
    v_status,v_financial_status,
    COALESCE(NULLIF(p_sale->>'date','')::date,current_date),
    left(COALESCE(p_sale->>'time',to_char(now() AT TIME ZONE 'America/Sao_Paulo','HH24:MI')),20),
    v_items,now()
  );

  RETURN jsonb_build_object('success',true,'sale_id',v_id,'display_id',v_display_id);
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_create_sale(uuid,jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_create_sale(uuid,jsonb) TO authenticated;

CREATE OR REPLACE FUNCTION public.rpc_create_kds_order(p_store_id uuid,p_order jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $function$
DECLARE
  v_order_id text;
  v_display_id text;
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
  v_display_id := NULLIF(BTRIM(COALESCE(p_order->>'displayId',p_order->>'displayid')),'');
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
    time,date,items,total,observation,status,code,"displayId",updated_at
  ) VALUES (
    p_store_id,v_order_id,left(v_origin,80),
    left(COALESCE(NULLIF(p_order->>'client',''),'Cliente'),180),
    left(COALESCE(p_order->>'address',''),500),
    left(COALESCE(p_order->>'payment',p_order->>'payMethod','Dinheiro'),80),
    COALESCE(NULLIF(p_order->>'cashgiven','')::numeric,0),
    COALESCE(NULLIF(p_order->>'change','')::numeric,0),
    left(COALESCE(p_order->>'time',''),20),
    COALESCE(NULLIF(p_order->>'date','')::date,current_date),
    v_items,v_total,left(COALESCE(p_order->>'observation',''),2000),
    v_status,'',v_display_id,now()
  );

  RETURN jsonb_build_object('success',true,'order_id',v_order_id,'display_id',v_display_id);
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_create_kds_order(uuid,jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_create_kds_order(uuid,jsonb) TO authenticated;

COMMIT;
