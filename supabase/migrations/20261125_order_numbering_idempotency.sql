-- VORTEX FOOD: numeração amigável atômica por loja/dia e gravações idempotentes.
-- A migração preserva os registros existentes e não altera chaves primárias.
-- NÃO executar sem backup confirmado e autorização explícita do usuário.

BEGIN;

DO $preflight$
BEGIN
  IF to_regclass('public.vortex_sales_history') IS NULL
     OR to_regclass('public.vortex_kds_orders') IS NULL
     OR to_regclass('public.vortex_stores') IS NULL THEN
    RAISE EXCEPTION 'Tabelas operacionais esperadas não encontradas. Migração cancelada.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='public' AND table_name='vortex_sales_history' AND column_name='display_id'
  ) OR NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='public' AND table_name='vortex_kds_orders' AND column_name='displayId'
  ) THEN
    RAISE EXCEPTION 'Colunas de exibição ausentes. Aplique primeiro a migração 20261124. Migração cancelada.';
  END IF;

  IF to_regprocedure('public.vortex_user_has_store_access(uuid)') IS NULL
     OR to_regprocedure('public.vortex_user_has_permission(uuid,text)') IS NULL THEN
    RAISE EXCEPTION 'Funções de autorização esperadas não encontradas. Migração cancelada.';
  END IF;
END;
$preflight$;

-- Preenche apenas números de exibição ausentes. IDs técnicos não são alterados.
WITH all_ids AS (
  SELECT store_id,id,date,MIN(updated_at) AS sort_at
  FROM (
    SELECT store_id,id,date,updated_at FROM public.vortex_sales_history
    UNION ALL
    SELECT store_id,id,date,updated_at FROM public.vortex_kds_orders
  ) AS source
  GROUP BY store_id,id,date
),
existing_display AS (
  SELECT store_id,id,date,MAX(display_num) AS display_num
  FROM (
    SELECT store_id,id,date,
      CASE WHEN display_id ~ '^[0-9]{1,18}$' THEN display_id::bigint END AS display_num
    FROM public.vortex_sales_history
    UNION ALL
    SELECT store_id,id,date,
      CASE WHEN "displayId" ~ '^[0-9]{1,18}$' THEN "displayId"::bigint END AS display_num
    FROM public.vortex_kds_orders
  ) AS source
  GROUP BY store_id,id,date
),
date_max AS (
  SELECT store_id,date,MAX(display_num) AS max_num
  FROM (
    SELECT store_id,date,display_num
    FROM existing_display
    WHERE display_num IS NOT NULL
    UNION ALL
    SELECT store_id,date,
      CASE WHEN id ~ '^[0-9]{1,18}$' THEN id::bigint END AS display_num
    FROM all_ids
  ) AS source
  GROUP BY store_id,date
),
numbered AS (
  SELECT a.store_id,a.id,a.date,e.display_num,
    CASE
      WHEN e.display_num IS NOT NULL THEN e.display_num
      WHEN a.id ~ '^[0-9]{1,18}$' THEN a.id::bigint
      ELSE COALESCE(m.max_num,0) +
        SUM(CASE WHEN e.display_num IS NULL AND a.id !~ '^[0-9]{1,18}$' THEN 1 ELSE 0 END)
        OVER (PARTITION BY a.store_id,a.date ORDER BY a.sort_at NULLS LAST,a.id
              ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
    END AS assigned_display
  FROM all_ids a
  LEFT JOIN existing_display e
    ON e.store_id=a.store_id AND e.id=a.id AND e.date=a.date
  LEFT JOIN date_max m
    ON m.store_id=a.store_id AND m.date=a.date
),
display_map AS (
  SELECT store_id,id,date,assigned_display::text AS display_id
  FROM numbered
)
UPDATE public.vortex_sales_history AS s
SET display_id=m.display_id
FROM display_map AS m
WHERE s.store_id=m.store_id AND s.id=m.id AND s.date=m.date
  AND (s.display_id IS NULL OR BTRIM(s.display_id)='');

WITH all_ids AS (
  SELECT store_id,id,date,MIN(updated_at) AS sort_at
  FROM (
    SELECT store_id,id,date,updated_at FROM public.vortex_sales_history
    UNION ALL
    SELECT store_id,id,date,updated_at FROM public.vortex_kds_orders
  ) AS source
  GROUP BY store_id,id,date
),
existing_display AS (
  SELECT store_id,id,date,MAX(display_num) AS display_num
  FROM (
    SELECT store_id,id,date,
      CASE WHEN display_id ~ '^[0-9]{1,18}$' THEN display_id::bigint END AS display_num
    FROM public.vortex_sales_history
    UNION ALL
    SELECT store_id,id,date,
      CASE WHEN "displayId" ~ '^[0-9]{1,18}$' THEN "displayId"::bigint END AS display_num
    FROM public.vortex_kds_orders
  ) AS source
  GROUP BY store_id,id,date
),
date_max AS (
  SELECT store_id,date,MAX(display_num) AS max_num
  FROM (
    SELECT store_id,date,display_num FROM existing_display WHERE display_num IS NOT NULL
    UNION ALL
    SELECT store_id,date,CASE WHEN id ~ '^[0-9]{1,18}$' THEN id::bigint END FROM all_ids
  ) AS source
  GROUP BY store_id,date
),
numbered AS (
  SELECT a.store_id,a.id,a.date,e.display_num,
    CASE
      WHEN e.display_num IS NOT NULL THEN e.display_num
      WHEN a.id ~ '^[0-9]{1,18}$' THEN a.id::bigint
      ELSE COALESCE(m.max_num,0) +
        SUM(CASE WHEN e.display_num IS NULL AND a.id !~ '^[0-9]{1,18}$' THEN 1 ELSE 0 END)
        OVER (PARTITION BY a.store_id,a.date ORDER BY a.sort_at NULLS LAST,a.id
              ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
    END AS assigned_display
  FROM all_ids a
  LEFT JOIN existing_display e
    ON e.store_id=a.store_id AND e.id=a.id AND e.date=a.date
  LEFT JOIN date_max m
    ON m.store_id=a.store_id AND m.date=a.date
),
display_map AS (
  SELECT store_id,id,date,assigned_display::text AS display_id
  FROM numbered
)
UPDATE public.vortex_kds_orders AS o
SET "displayId"=m.display_id
FROM display_map AS m
WHERE o.store_id=m.store_id AND o.id=m.id AND o.date=m.date
  AND (o."displayId" IS NULL OR BTRIM(o."displayId")='');

CREATE TABLE IF NOT EXISTS public.vortex_order_display_counters (
  store_id uuid NOT NULL REFERENCES public.vortex_stores(id) ON DELETE CASCADE,
  order_date date NOT NULL,
  last_number bigint NOT NULL DEFAULT 0 CHECK (last_number >= 0),
  PRIMARY KEY (store_id,order_date)
);

ALTER TABLE public.vortex_order_display_counters ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.vortex_order_display_counters FROM PUBLIC,anon,authenticated;

CREATE OR REPLACE FUNCTION public.rpc_next_order_display_number(
  p_store_id uuid,
  p_origin text
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog,public,auth
AS $function$
DECLARE
  v_origin text := lower(btrim(COALESCE(p_origin,'')));
  v_order_date date := (now() AT TIME ZONE 'America/Sao_Paulo')::date;
  v_max bigint := 0;
  v_next bigint;
BEGIN
  IF auth.uid() IS NULL OR NOT public.vortex_user_has_store_access(p_store_id) THEN
    RAISE EXCEPTION 'Acesso não autorizado.';
  END IF;

  IF v_origin IN ('mesa','mesas','comanda','tables') THEN
    IF NOT public.vortex_user_has_permission(p_store_id,'tables.open') THEN
      RAISE EXCEPTION 'Seu perfil não pode abrir comandas ou enviar pedidos de mesa.';
    END IF;
  ELSIF v_origin IN ('delivery','entrega') THEN
    IF NOT public.vortex_user_has_permission(p_store_id,'delivery.manage') THEN
      RAISE EXCEPTION 'Seu perfil não pode registrar pedidos de delivery.';
    END IF;
  ELSIF v_origin IN ('pdv','balcao','balcão') THEN
    IF NOT public.vortex_user_has_permission(p_store_id,'pdv.sell') THEN
      RAISE EXCEPTION 'Seu perfil não pode registrar vendas no PDV.';
    END IF;
  ELSE
    RAISE EXCEPTION 'Origem de pedido inválida.';
  END IF;

  SELECT GREATEST(
    COALESCE((
      SELECT MAX(display_id::bigint)
      FROM public.vortex_sales_history
      WHERE store_id=p_store_id AND date=v_order_date
        AND display_id ~ '^[0-9]{1,18}$'
    ),0),
    COALESCE((
      SELECT MAX("displayId"::bigint)
      FROM public.vortex_kds_orders
      WHERE store_id=p_store_id AND date=v_order_date
        AND "displayId" ~ '^[0-9]{1,18}$'
    ),0),
    COALESCE((
      SELECT MAX(id::bigint)
      FROM public.vortex_sales_history
      WHERE store_id=p_store_id AND date=v_order_date
        AND id ~ '^[0-9]{1,18}$'
    ),0),
    COALESCE((
      SELECT MAX(id::bigint)
      FROM public.vortex_kds_orders
      WHERE store_id=p_store_id AND date=v_order_date
        AND id ~ '^[0-9]{1,18}$'
    ),0)
  )
  INTO v_max;

  INSERT INTO public.vortex_order_display_counters AS counter(store_id,order_date,last_number)
  VALUES (p_store_id,v_order_date,v_max+1)
  ON CONFLICT (store_id,order_date)
  DO UPDATE SET last_number=GREATEST(counter.last_number,v_max)+1
  RETURNING last_number INTO v_next;

  RETURN jsonb_build_object(
    'success',true,
    'display_id',v_next::text,
    'order_date',v_order_date
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_next_order_display_number(uuid,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.rpc_next_order_display_number(uuid,text) TO authenticated;

-- Gravação de venda idempotente: uma repetição do mesmo pedido retorna sucesso
-- sem recriar a venda nem reverter status/estorno já aplicados.
CREATE OR REPLACE FUNCTION public.rpc_create_sale(p_store_id uuid,p_sale jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog,public,auth
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
  v_client text;
  v_payment text;
  v_date date;
  v_time text;
  v_existing public.vortex_sales_history%ROWTYPE;
  v_inserted integer;
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
  v_client := left(COALESCE(p_sale->>'client','Cliente Balcão'),180);
  v_payment := left(COALESCE(p_sale->>'pay_method',p_sale->>'payMethod',p_sale->>'paymentMethod','PIX'),80);
  v_date := COALESCE(NULLIF(p_sale->>'date','')::date,current_date);
  v_time := left(COALESCE(p_sale->>'time',to_char(now() AT TIME ZONE 'America/Sao_Paulo','HH24:MI')),20);

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
    p_store_id,v_id,v_display_id,v_client,left(v_channel,80),
    v_total,v_subtotal,v_discount,v_payment,v_payment,
    v_status,v_financial_status,v_date,v_time,v_items,now()
  )
  ON CONFLICT (store_id,id) DO NOTHING;

  GET DIAGNOSTICS v_inserted = ROW_COUNT;
  IF v_inserted=0 THEN
    SELECT * INTO v_existing
    FROM public.vortex_sales_history
    WHERE store_id=p_store_id AND id=v_id;

    IF NOT FOUND
       OR v_existing.client IS DISTINCT FROM v_client
       OR v_existing.channel IS DISTINCT FROM left(v_channel,80)
       OR v_existing.total IS DISTINCT FROM v_total
       OR v_existing.subtotal IS DISTINCT FROM v_subtotal
       OR v_existing.discount IS DISTINCT FROM v_discount
       OR v_existing.pay_method IS DISTINCT FROM v_payment
       OR v_existing.date IS DISTINCT FROM v_date
       OR v_existing.time IS DISTINCT FROM v_time
       OR v_existing.items IS DISTINCT FROM v_items THEN
      RAISE EXCEPTION 'Este identificador já pertence a outra venda. O registro existente foi preservado.';
    END IF;

    IF (v_existing.display_id IS NULL OR BTRIM(v_existing.display_id)='')
       AND v_display_id IS NOT NULL THEN
      UPDATE public.vortex_sales_history
      SET display_id=v_display_id
      WHERE store_id=p_store_id AND id=v_id;
    END IF;

    RETURN jsonb_build_object(
      'success',true,
      'sale_id',v_id,
      'display_id',COALESCE(NULLIF(v_existing.display_id,''),v_display_id),
      'idempotent',true
    );
  END IF;

  RETURN jsonb_build_object('success',true,'sale_id',v_id,'display_id',v_display_id,'idempotent',false);
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_create_sale(uuid,jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.rpc_create_sale(uuid,jsonb) TO authenticated;

-- Gravação KDS idempotente: não reinicia status de pedido já em preparo/pronto.
CREATE OR REPLACE FUNCTION public.rpc_create_kds_order(p_store_id uuid,p_order jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog,public,auth
AS $function$
DECLARE
  v_order_id text;
  v_display_id text;
  v_code text;
  v_origin text;
  v_total numeric;
  v_items jsonb;
  v_status text;
  v_client text;
  v_address text;
  v_payment text;
  v_cashgiven numeric;
  v_change numeric;
  v_time text;
  v_date date;
  v_observation text;
  v_existing public.vortex_kds_orders%ROWTYPE;
  v_inserted integer;
BEGIN
  IF auth.uid() IS NULL OR NOT public.vortex_user_has_store_access(p_store_id) THEN
    RAISE EXCEPTION 'Acesso não autorizado.';
  END IF;
  IF jsonb_typeof(p_order) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'Dados do pedido inválidos.';
  END IF;

  v_order_id := NULLIF(BTRIM(p_order->>'id'),'');
  v_display_id := NULLIF(BTRIM(COALESCE(p_order->>'displayId',p_order->>'displayid')),'');
  v_code := NULLIF(BTRIM(COALESCE(p_order->>'code',p_order->>'displayId',p_order->>'displayid')),'');
  v_origin := COALESCE(NULLIF(BTRIM(p_order->>'origin'),''),'Balcão');
  v_total := COALESCE(NULLIF(p_order->>'total','')::numeric,0);
  v_items := COALESCE(p_order->'items','[]'::jsonb);
  v_status := COALESCE(NULLIF(p_order->>'status',''),'new');
  v_client := left(COALESCE(NULLIF(p_order->>'client',''),'Cliente'),180);
  v_address := left(COALESCE(p_order->>'address',''),500);
  v_payment := left(COALESCE(p_order->>'payment',p_order->>'payMethod','Dinheiro'),80);
  v_cashgiven := COALESCE(NULLIF(p_order->>'cashgiven','')::numeric,0);
  v_change := COALESCE(NULLIF(p_order->>'change','')::numeric,0);
  v_time := left(COALESCE(p_order->>'time',''),20);
  v_date := COALESCE(NULLIF(p_order->>'date','')::date,current_date);
  v_observation := left(COALESCE(p_order->>'observation',''),2000);

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

  INSERT INTO public.vortex_kds_orders(
    store_id,id,origin,client,address,payment,cashgiven,change,
    time,date,items,total,observation,status,code,"displayId",updated_at
  ) VALUES (
    p_store_id,v_order_id,left(v_origin,80),v_client,v_address,v_payment,
    v_cashgiven,v_change,v_time,v_date,v_items,v_total,v_observation,
    v_status,COALESCE(v_code,''),v_display_id,now()
  )
  ON CONFLICT (store_id,id) DO NOTHING;

  GET DIAGNOSTICS v_inserted = ROW_COUNT;
  IF v_inserted=0 THEN
    SELECT * INTO v_existing
    FROM public.vortex_kds_orders
    WHERE store_id=p_store_id AND id=v_order_id;

    IF NOT FOUND
       OR v_existing.origin IS DISTINCT FROM left(v_origin,80)
       OR v_existing.client IS DISTINCT FROM v_client
       OR v_existing.address IS DISTINCT FROM v_address
       OR v_existing.payment IS DISTINCT FROM v_payment
       OR v_existing.cashgiven IS DISTINCT FROM v_cashgiven
       OR v_existing.change IS DISTINCT FROM v_change
       OR v_existing.time IS DISTINCT FROM v_time
       OR v_existing.date IS DISTINCT FROM v_date
       OR v_existing.items IS DISTINCT FROM v_items
       OR v_existing.total IS DISTINCT FROM v_total
       OR v_existing.observation IS DISTINCT FROM v_observation THEN
      RAISE EXCEPTION 'Este identificador já pertence a outro pedido. O registro existente foi preservado.';
    END IF;

    IF (v_existing."displayId" IS NULL OR BTRIM(v_existing."displayId")='')
       AND v_display_id IS NOT NULL THEN
      UPDATE public.vortex_kds_orders
      SET "displayId"=v_display_id
      WHERE store_id=p_store_id AND id=v_order_id;
    END IF;
    IF (v_existing.code IS NULL OR BTRIM(v_existing.code)='')
       AND v_code IS NOT NULL THEN
      UPDATE public.vortex_kds_orders
      SET code=v_code
      WHERE store_id=p_store_id AND id=v_order_id;
    END IF;

    RETURN jsonb_build_object(
      'success',true,
      'order_id',v_order_id,
      'display_id',COALESCE(NULLIF(v_existing."displayId",''),v_display_id),
      'idempotent',true
    );
  END IF;

  RETURN jsonb_build_object('success',true,'order_id',v_order_id,'display_id',v_display_id,'idempotent',false);
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_create_kds_order(uuid,jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.rpc_create_kds_order(uuid,jsonb) TO authenticated;


-- A TV também recebe o número amigável: nunca expõe IDs técnicos UUID.
-- Usa o displayId salvo; para registros antigos tenta o código legado.
CREATE OR REPLACE FUNCTION public.rpc_get_kds_tv_feed(p_device_token text)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog,public,auth
AS $function$
DECLARE
  v_device_id uuid;
  v_store_id uuid;
  v_profile text;
  v_orders jsonb;
BEGIN
  IF p_device_token IS NULL
     OR length(p_device_token) < 32
     OR length(p_device_token) > 256 THEN
    RETURN jsonb_build_object('authorized',false,'reason','invalid_token');
  END IF;

  UPDATE public.vortex_kds_tv_devices AS d
  SET last_seen_at=now()
  WHERE d.token_hash=extensions.digest(p_device_token,'sha256')
    AND d.is_active=true
    AND d.revoked_at IS NULL
  RETURNING d.id,d.store_id,d.profile
    INTO v_device_id,v_store_id,v_profile;

  IF v_device_id IS NULL THEN
    IF EXISTS (
      SELECT 1 FROM public.vortex_kds_tv_devices AS d
      WHERE d.token_hash=extensions.digest(p_device_token,'sha256')
        AND (d.is_active=false OR d.revoked_at IS NOT NULL)
    ) THEN
      RETURN jsonb_build_object('authorized',false,'reason','revoked');
    END IF;
    RETURN jsonb_build_object('authorized',false,'reason','invalid_token');
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.vortex_stores AS s
    WHERE s.id=v_store_id AND s.status='active'
  ) THEN
    RETURN jsonb_build_object('authorized',false,'reason','store_unavailable');
  END IF;

  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'id',o.id,
        'displayId',COALESCE(
          NULLIF(o."displayId",''),
          NULLIF(o.code,''),
          CASE WHEN o.id ~ '^[0-9]{1,18}$' THEN o.id ELSE '—' END
        ),
        'status',o.status,
        'date',o.date,
        'time',o.time,
        'origin',o.origin,
        'observation',CASE WHEN v_profile='kitchen' THEN NULLIF(left(COALESCE(o.observation,''),500),'') ELSE NULL END,
        'items',
          COALESCE((
            SELECT jsonb_agg(
              CASE WHEN v_profile='kitchen' THEN
                jsonb_build_object(
                  'name',left(COALESCE(NULLIF(x.value->>'name',''),'Item'),160),
                  'quantity',
                    CASE jsonb_typeof(x.value->'qty')
                      WHEN 'number' THEN x.value->'qty'
                      WHEN 'string' THEN to_jsonb(left(x.value->>'qty',12))
                      ELSE '1'::jsonb
                    END,
                  'category',left(COALESCE(x.value->>'category',''),80)
                )
              ELSE
                jsonb_build_object(
                  'name',left(COALESCE(NULLIF(x.value->>'name',''),'Item'),160),
                  'quantity',
                    CASE jsonb_typeof(x.value->'qty')
                      WHEN 'number' THEN x.value->'qty'
                      WHEN 'string' THEN to_jsonb(left(x.value->>'qty',12))
                      ELSE '1'::jsonb
                    END
                )
              END
              ORDER BY x.ordinality
            )
            FROM jsonb_array_elements(
              CASE WHEN jsonb_typeof(o.items)='array' THEN o.items ELSE '[]'::jsonb END
            ) WITH ORDINALITY AS x(value,ordinality)
            WHERE jsonb_typeof(x.value)='object'
          ),'[]'::jsonb)
      )
      ORDER BY o.date DESC NULLS LAST,o.time DESC NULLS LAST,o.updated_at DESC NULLS LAST
    ),
    '[]'::jsonb
  )
  INTO v_orders
  FROM (
    SELECT id,"displayId",code,status,date,time,origin,observation,items,updated_at
    FROM public.vortex_kds_orders
    WHERE store_id=v_store_id
      AND COALESCE(status,'') NOT IN ('finished','completed','cancelled')
    ORDER BY date DESC NULLS LAST,time DESC NULLS LAST,updated_at DESC NULLS LAST
    LIMIT 100
  ) AS o;

  RETURN jsonb_build_object(
    'authorized',true,
    'profile',v_profile,
    'orders',v_orders,
    'server_time',now()
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_get_kds_tv_feed(text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_get_kds_tv_feed(text) TO anon,authenticated;

COMMIT;
 THEN o.id ELSE '—' END
        ),
        'status',o.status,
        'date',o.date,
        'time',o.time,
        'origin',o.origin,
        'observation',CASE WHEN v_profile='kitchen' THEN NULLIF(left(COALESCE(o.observation,''),500),'') ELSE NULL END,
        'items',
          COALESCE((
            SELECT jsonb_agg(
              CASE WHEN v_profile='kitchen' THEN
                jsonb_build_object(
                  'name',left(COALESCE(NULLIF(x.value->>'name',''),'Item'),160),
                  'quantity',
                    CASE jsonb_typeof(x.value->'qty')
                      WHEN 'number' THEN x.value->'qty'
                      WHEN 'string' THEN to_jsonb(left(x.value->>'qty',12))
                      ELSE '1'::jsonb
                    END,
                  'category',left(COALESCE(x.value->>'category',''),80)
                )
              ELSE
                jsonb_build_object(
                  'name',left(COALESCE(NULLIF(x.value->>'name',''),'Item'),160),
                  'quantity',
                    CASE jsonb_typeof(x.value->'qty')
                      WHEN 'number' THEN x.value->'qty'
                      WHEN 'string' THEN to_jsonb(left(x.value->>'qty',12))
                      ELSE '1'::jsonb
                    END
                )
              END
              ORDER BY x.ordinality
            )
            FROM jsonb_array_elements(
              CASE WHEN jsonb_typeof(o.items)='array' THEN o.items ELSE '[]'::jsonb END
            ) WITH ORDINALITY AS x(value,ordinality)
            WHERE jsonb_typeof(x.value)='object'
          ),'[]'::jsonb)
      )
      ORDER BY o.date DESC NULLS LAST,o.time DESC NULLS LAST,o.updated_at DESC NULLS LAST
    ),
    '[]'::jsonb
  )
  INTO v_orders
  FROM (
    SELECT id,"displayId",code,status,date,time,origin,observation,items,updated_at
    FROM public.vortex_kds_orders
    WHERE store_id=v_store_id
      AND COALESCE(status,'') NOT IN ('finished','completed','cancelled')
    ORDER BY date DESC NULLS LAST,time DESC NULLS LAST,updated_at DESC NULLS LAST
    LIMIT 100
  ) AS o;

  RETURN jsonb_build_object(
    'authorized',true,
    'profile',v_profile,
    'orders',v_orders,
    'server_time',now()
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_get_kds_tv_feed(text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_get_kds_tv_feed(text) TO anon,authenticated;

COMMIT;
