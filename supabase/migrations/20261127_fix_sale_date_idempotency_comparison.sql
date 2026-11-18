-- Corrige compatibilidade entre a coluna date (texto em instalações existentes)
-- e a variável date da RPC, sem alterar nem apagar vendas antigas.
BEGIN;

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
       OR v_existing.date::text IS DISTINCT FROM v_date::text
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

COMMIT;
