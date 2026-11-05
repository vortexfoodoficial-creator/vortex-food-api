-- VORTEX FOOD: idempotencia transacional do consumo de estoque e pedidos publicos por QR.
-- Executar depois das migracoes 20261105, 20261106 e 20261107.

BEGIN;

-- 1) Pedidos publicos: um mesmo token so pode gerar um pedido por estabelecimento.
ALTER TABLE public.vortex_kds_orders
  ADD COLUMN IF NOT EXISTS public_request_id uuid;

CREATE UNIQUE INDEX IF NOT EXISTS vortex_kds_orders_public_request_unique
  ON public.vortex_kds_orders (store_id, public_request_id)
  WHERE public_request_id IS NOT NULL;

-- Remove a versao anterior para que nao exista um caminho publico sem token idempotente.
DROP FUNCTION IF EXISTS public.rpc_create_public_table_order(uuid, integer, text, text, jsonb);

CREATE OR REPLACE FUNCTION public.rpc_create_public_table_order(
  p_store_id uuid,
  p_table_number integer,
  p_client_name text,
  p_observation text,
  p_items jsonb,
  p_request_id uuid
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
  v_existing public.vortex_kds_orders%ROWTYPE;
BEGIN
  IF p_store_id IS NULL OR p_request_id IS NULL
     OR p_table_number IS NULL OR p_table_number < 1 OR p_table_number > 200 THEN
    RAISE EXCEPTION 'Mesa, estabelecimento ou identificador do pedido inválido.';
  END IF;

  -- Repetir a mesma solicitacao (por exemplo, apos timeout) devolve o pedido original.
  SELECT * INTO v_existing
  FROM public.vortex_kds_orders
  WHERE store_id = p_store_id AND public_request_id = p_request_id;

  IF FOUND THEN
    RETURN jsonb_build_object(
      'success', true,
      'duplicate', true,
      'order_id', v_existing.id,
      'display_id', COALESCE(v_existing."displayId", v_existing.code),
      'total', v_existing.total
    );
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

  -- Limita envios independentes em sequência na mesma mesa.
  -- Repetições do mesmo token já retornaram o pedido original acima.
  PERFORM pg_advisory_xact_lock(hashtext(p_store_id::text), p_table_number);
  IF EXISTS (
    SELECT 1
    FROM public.vortex_kds_orders
    WHERE store_id = p_store_id
      AND origin = 'Mesa ' || lpad(p_table_number::text, 2, '0')
      AND created_at > v_now - interval '2 seconds'
  ) THEN
    RAISE EXCEPTION 'Aguarde alguns segundos antes de enviar outro pedido desta mesa.';
  END IF;

  IF jsonb_typeof(p_items) IS DISTINCT FROM 'array' THEN
    RAISE EXCEPTION 'O pedido precisa ser enviado em formato de lista.';
  END IF;

  IF jsonb_array_length(p_items) < 1 OR jsonb_array_length(p_items) > 30 THEN
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
      AND COALESCE((p.value->>'isKg')::boolean, false) = false
      AND COALESCE((p.value->>'isVariable')::boolean, false) = false
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
    financial_status, updated_at, "displayId", public_request_id
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
    v_display_id,
    p_request_id
  )
  ON CONFLICT (store_id, public_request_id)
    WHERE public_request_id IS NOT NULL
  DO NOTHING;

  IF NOT FOUND THEN
    SELECT * INTO v_existing
    FROM public.vortex_kds_orders
    WHERE store_id = p_store_id AND public_request_id = p_request_id;

    RETURN jsonb_build_object(
      'success', true,
      'duplicate', true,
      'order_id', v_existing.id,
      'display_id', COALESCE(v_existing."displayId", v_existing.code),
      'total', v_existing.total
    );
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'duplicate', false,
    'order_id', v_order_id,
    'display_id', v_display_id,
    'total', round(v_total, 2)
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_create_public_table_order(uuid, integer, text, text, jsonb, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpc_create_public_table_order(uuid, integer, text, text, jsonb, uuid) TO anon, authenticated;

-- 2) Consumo de estoque: registra a movimentacao e desconta o saldo na mesma transacao.
-- A chave unica (store_id, idempotency_key) impede que duas telas descontem o mesmo consumo.
CREATE OR REPLACE FUNCTION public.rpc_consume_stock_for_order(
  p_store_id uuid,
  p_order_id text,
  p_movements jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $function$
DECLARE
  v_entry jsonb;
  v_movement_id text;
  v_item_id text;
  v_item_name text;
  v_type text;
  v_qty numeric(14,4);
  v_reason text;
  v_key text;
  v_inserted_id text;
  v_processed integer := 0;
BEGIN
  IF auth.uid() IS NULL OR NOT public.vortex_user_has_store_access(p_store_id) THEN
    RAISE EXCEPTION 'Acesso não autorizado a este estabelecimento.';
  END IF;

  IF COALESCE(trim(p_order_id), '') = '' OR jsonb_typeof(p_movements) IS DISTINCT FROM 'array' THEN
    RAISE EXCEPTION 'Pedido ou lista de movimentações inválida.';
  END IF;

  IF jsonb_array_length(p_movements) > 500 THEN
    RAISE EXCEPTION 'Quantidade de movimentações acima do limite.';
  END IF;

  FOR v_entry IN SELECT value FROM jsonb_array_elements(p_movements)
  LOOP
    v_movement_id := COALESCE(NULLIF(v_entry->>'id', ''), replace(gen_random_uuid()::text, '-', ''));
    v_item_id := NULLIF(v_entry->>'item_id', '');
    v_item_name := COALESCE(v_entry->>'item_name', '');
    v_type := COALESCE(NULLIF(v_entry->>'type', ''), 'consumption');
    v_qty := (v_entry->>'qty')::numeric;
    v_reason := COALESCE(v_entry->>'reason', '');
    v_key := NULLIF(v_entry->>'idempotency_key', '');

    IF v_item_id IS NULL OR v_key IS NULL OR v_qty IS NULL OR v_qty <= 0
       OR v_type <> 'consumption' THEN
      RAISE EXCEPTION 'Movimentação de estoque inválida.';
    END IF;

    INSERT INTO public.vortex_stock_movements (
      store_id, id, order_id, item_id, item_name, type, qty, reason, idempotency_key, created_at
    ) VALUES (
      p_store_id, v_movement_id, p_order_id, v_item_id, v_item_name,
      v_type, v_qty, v_reason, v_key, now()
    )
    ON CONFLICT (store_id, idempotency_key) DO NOTHING
    RETURNING id INTO v_inserted_id;

    IF v_inserted_id IS NOT NULL THEN
      UPDATE public.vortex_stock_items
      SET qty = GREATEST(0, COALESCE(qty, 0) - v_qty),
          updated_at = now()
      WHERE store_id = p_store_id
        AND id = v_item_id;

      IF NOT FOUND THEN
        RAISE EXCEPTION 'Insumo % não encontrado neste estabelecimento.', v_item_id;
      END IF;

      v_processed := v_processed + 1;
    END IF;

    v_inserted_id := NULL;
  END LOOP;

  RETURN jsonb_build_object('success', true, 'processed', v_processed);
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_consume_stock_for_order(uuid, text, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_consume_stock_for_order(uuid, text, jsonb) TO authenticated;

COMMIT;
