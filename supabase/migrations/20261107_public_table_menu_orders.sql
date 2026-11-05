-- VORTEX FOOD: cardapio publico por mesa e envio seguro de pedidos ao KDS.
-- Executar somente depois de 20261105_store_data_isolation.sql e 20261106_public_qr_requests.sql.
-- O cliente nunca recebe acesso direto às tabelas internas ou aos documentos completos da loja.

BEGIN;

CREATE OR REPLACE FUNCTION public.rpc_get_public_table_menu(p_store_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $function$
DECLARE
  v_store_name text;
  v_catalog jsonb;
  v_products jsonb;
BEGIN
  IF p_store_id IS NULL THEN
    RAISE EXCEPTION 'Estabelecimento inválido.';
  END IF;

  IF NOT public.rpc_get_public_qr_enabled(p_store_id) THEN
    RAISE EXCEPTION 'O cardápio por QR Code está desativado neste estabelecimento.';
  END IF;

  SELECT s.name INTO v_store_name
  FROM public.vortex_stores AS s
  WHERE s.id = p_store_id
    AND s.status = 'active';

  IF v_store_name IS NULL THEN
    RAISE EXCEPTION 'Estabelecimento não encontrado ou inativo.';
  END IF;

  SELECT d.data INTO v_catalog
  FROM public.vortex_store_documents AS d
  WHERE d.store_id = p_store_id
    AND d.document_key = 'catalog';

  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'id', p.value->'id',
      'name', p.value->>'name',
      'description', COALESCE(p.value->>'desc', ''),
      'group', COALESCE(p.value->>'group', ''),
      'image', COALESCE(p.value->>'image', ''),
      'price', COALESCE(NULLIF(p.value->>'price', '')::numeric, 0),
      'isKg', COALESCE((p.value->>'isKg')::boolean, false)
    )
    ORDER BY COALESCE(p.value->>'group', ''), COALESCE(p.value->>'name', '')
  ), '[]'::jsonb)
  INTO v_products
  FROM jsonb_array_elements(
    CASE
      WHEN jsonb_typeof(v_catalog->'products') = 'array' THEN v_catalog->'products'
      ELSE '[]'::jsonb
    END
  ) AS p(value)
  WHERE COALESCE((p.value->>'active')::boolean, true) = true
    AND COALESCE((p.value->>'showTable')::boolean, false) = true
    AND COALESCE(NULLIF(p.value->>'price', '')::numeric, 0) > 0;

  RETURN jsonb_build_object(
    'store_name', v_store_name,
    'products', v_products
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpc_create_public_table_order(
  p_store_id uuid,
  p_table_number integer,
  p_client_name text,
  p_observation text,
  p_items jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $function$
DECLARE
  v_catalog jsonb;
  v_products jsonb;
  v_item jsonb;
  v_product jsonb;
  v_order_items jsonb := '[]'::jsonb;
  v_product_id text;
  v_qty integer;
  v_price numeric(12,2);
  v_total numeric(12,2) := 0;
  v_order_id text;
  v_display_id text;
  v_client_name text;
  v_observation text;
  v_now timestamptz := now();
BEGIN
  IF p_store_id IS NULL OR p_table_number IS NULL OR p_table_number < 1 OR p_table_number > 200 THEN
    RAISE EXCEPTION 'Mesa ou estabelecimento inválido.';
  END IF;

  IF NOT public.rpc_get_public_qr_enabled(p_store_id) THEN
    RAISE EXCEPTION 'O atendimento por QR Code está desativado neste estabelecimento.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.vortex_stores
    WHERE id = p_store_id AND status = 'active'
  ) THEN
    RAISE EXCEPTION 'Estabelecimento não encontrado ou inativo.';
  END IF;

  IF jsonb_typeof(p_items) <> 'array'
     OR jsonb_array_length(p_items) < 1
     OR jsonb_array_length(p_items) > 30 THEN
    RAISE EXCEPTION 'O pedido precisa conter entre 1 e 30 itens.';
  END IF;

  v_client_name := left(trim(COALESCE(p_client_name, '')), 80);
  IF v_client_name = '' THEN
    v_client_name := 'Mesa ' || p_table_number::text;
  END IF;
  v_observation := left(trim(COALESCE(p_observation, '')), 500);

  SELECT d.data INTO v_catalog
  FROM public.vortex_store_documents AS d
  WHERE d.store_id = p_store_id
    AND d.document_key = 'catalog';

  v_products := CASE
    WHEN jsonb_typeof(v_catalog->'products') = 'array' THEN v_catalog->'products'
    ELSE '[]'::jsonb
  END;

  FOR v_item IN SELECT value FROM jsonb_array_elements(p_items)
  LOOP
    v_product_id := v_item->>'id';
    v_qty := (v_item->>'qty')::integer;

    IF v_product_id IS NULL OR v_qty IS NULL OR v_qty < 1 OR v_qty > 30 THEN
      RAISE EXCEPTION 'Produto ou quantidade inválida.';
    END IF;

    SELECT p.value INTO v_product
    FROM jsonb_array_elements(v_products) AS p(value)
    WHERE p.value->>'id' = v_product_id
      AND COALESCE((p.value->>'active')::boolean, true) = true
      AND COALESCE((p.value->>'showTable')::boolean, false) = true
    LIMIT 1;

    IF v_product IS NULL THEN
      RAISE EXCEPTION 'Um dos produtos não está mais disponível no cardápio.';
    END IF;

    v_price := COALESCE(NULLIF(v_product->>'price', '')::numeric, 0);
    IF v_price <= 0 THEN
      RAISE EXCEPTION 'Preço inválido para um dos produtos.';
    END IF;

    v_order_items := v_order_items || jsonb_build_array(jsonb_build_object(
      'id', v_product->'id',
      'name', v_product->>'name',
      'qty', v_qty,
      'price', v_price,
      'total', round(v_price * v_qty, 2)
    ));
    v_total := v_total + (v_price * v_qty);
  END LOOP;

  v_order_id := 'QR-' || replace(gen_random_uuid()::text, '-', '');
  v_display_id := lpad((floor(random() * 9000) + 1000)::integer::text, 4, '0');

  INSERT INTO public.vortex_kds_orders (
    store_id, id, origin, client, address, payment, cashgiven, change,
    time, date, dateformatted, items, total, observation, status, code,
    financial_status, updated_at, "displayId"
  ) VALUES (
    p_store_id,
    v_order_id,
    'Mesa ' || lpad(p_table_number::text, 2, '0'),
    v_client_name,
    'Consumo Local',
    'Comanda de Mesa',
    0,
    0,
    to_char(v_now AT TIME ZONE 'America/Sao_Paulo', 'HH24:MI'),
    (v_now AT TIME ZONE 'America/Sao_Paulo')::date,
    to_char(v_now AT TIME ZONE 'America/Sao_Paulo', 'DD/MM/YYYY'),
    v_order_items,
    round(v_total, 2),
    v_observation,
    'received',
    v_display_id,
    'pending',
    v_now,
    v_display_id
  );

  RETURN jsonb_build_object(
    'success', true,
    'order_id', v_order_id,
    'display_id', v_display_id,
    'total', round(v_total, 2)
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_get_public_table_menu(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpc_get_public_table_menu(uuid) TO anon, authenticated;

REVOKE ALL ON FUNCTION public.rpc_create_public_table_order(uuid, integer, text, text, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpc_create_public_table_order(uuid, integer, text, text, jsonb) TO anon, authenticated;

COMMIT;
