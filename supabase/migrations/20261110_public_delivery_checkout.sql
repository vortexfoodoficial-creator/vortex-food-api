-- VORTEX FOOD: cardápio público de delivery com código exibido somente ao cliente no checkout.
-- Executar depois da migração 20261109_delivery_verification_codes.sql.
-- Não altera os fluxos existentes de QR Code de mesa.

BEGIN;

CREATE TABLE IF NOT EXISTS public.vortex_public_delivery_settings (
  store_id uuid PRIMARY KEY REFERENCES public.vortex_stores(id) ON DELETE CASCADE,
  delivery_enabled boolean NOT NULL DEFAULT false,
  updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.vortex_public_delivery_settings ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS vortex_public_delivery_settings_member_access ON public.vortex_public_delivery_settings;
CREATE POLICY vortex_public_delivery_settings_member_access
  ON public.vortex_public_delivery_settings
  FOR ALL TO authenticated
  USING (public.vortex_user_has_store_access(store_id))
  WITH CHECK (public.vortex_user_has_store_access(store_id));

REVOKE ALL ON TABLE public.vortex_public_delivery_settings FROM PUBLIC, anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.vortex_public_delivery_settings TO authenticated;

-- O código é devolvido apenas pela RPC de checkout ao navegador que acabou de enviar o pedido.
-- Nenhuma rotina administrativa devolve o código ou um link para consultá-lo.
ALTER TABLE public.vortex_delivery_verifications
  ALTER COLUMN access_token_hash DROP NOT NULL;

DROP FUNCTION IF EXISTS public.rpc_issue_delivery_verification(uuid, text);
DROP FUNCTION IF EXISTS public.rpc_get_delivery_code(uuid, text, text);

CREATE OR REPLACE FUNCTION public.rpc_set_public_delivery_enabled(p_enabled boolean)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $function$
DECLARE
  v_store_id uuid;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Entre na sua conta para alterar o cardápio público.';
  END IF;

  SELECT store_id INTO v_store_id
  FROM public.vortex_store_members
  WHERE user_id = auth.uid() AND status = 'active'
  ORDER BY created_at
  LIMIT 1;

  IF v_store_id IS NULL THEN
    RAISE EXCEPTION 'Estabelecimento ativo não encontrado.';
  END IF;

  INSERT INTO public.vortex_public_delivery_settings (store_id, delivery_enabled, updated_at)
  VALUES (v_store_id, COALESCE(p_enabled, false), now())
  ON CONFLICT (store_id)
  DO UPDATE SET delivery_enabled = EXCLUDED.delivery_enabled, updated_at = now();

  RETURN jsonb_build_object('success', true, 'delivery_enabled', COALESCE(p_enabled, false));
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpc_get_public_delivery_enabled(p_store_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $function$
  SELECT COALESCE((
    SELECT delivery_enabled
    FROM public.vortex_public_delivery_settings
    WHERE store_id = p_store_id
  ), false);
$function$;

CREATE OR REPLACE FUNCTION public.rpc_get_public_delivery_menu(p_store_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $function$
DECLARE
  v_store_name text;
  v_setting_name text;
  v_phone text;
  v_address text;
  v_catalog jsonb;
  v_products jsonb;
BEGIN
  IF p_store_id IS NULL OR NOT public.rpc_get_public_delivery_enabled(p_store_id) THEN
    RAISE EXCEPTION 'O cardápio de delivery está temporariamente indisponível.';
  END IF;

  SELECT s.name INTO v_store_name
  FROM public.vortex_stores s
  WHERE s.id = p_store_id AND s.status = 'active';

  IF v_store_name IS NULL THEN
    RAISE EXCEPTION 'Estabelecimento não encontrado ou inativo.';
  END IF;

  SELECT store_name, phone, store_address
  INTO v_setting_name, v_phone, v_address
  FROM public.vortex_store_settings
  WHERE store_id = p_store_id
  ORDER BY id
  LIMIT 1;

  SELECT data INTO v_catalog
  FROM public.vortex_store_documents
  WHERE store_id = p_store_id AND document_key = 'catalog';

  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'id', p.value->'id',
      'name', p.value->>'name',
      'description', COALESCE(p.value->>'desc', ''),
      'group', COALESCE(p.value->>'group', ''),
      'image', COALESCE(p.value->>'image', ''),
      'price', COALESCE(NULLIF(p.value->>'price', '')::numeric, 0),
      'isKg', COALESCE((p.value->>'isKg')::boolean, false),
      'isVariable', COALESCE((p.value->>'isVariable')::boolean, false)
    )
    ORDER BY COALESCE(p.value->>'group', ''), COALESCE(p.value->>'name', '')
  ), '[]'::jsonb)
  INTO v_products
  FROM jsonb_array_elements(
    CASE WHEN jsonb_typeof(v_catalog->'products') = 'array'
      THEN v_catalog->'products' ELSE '[]'::jsonb END
  ) p(value)
  WHERE COALESCE((p.value->>'active')::boolean, true) = true
    AND COALESCE((p.value->>'showDelivery')::boolean, true) = true
    AND COALESCE((p.value->>'isKg')::boolean, false) = false
    AND COALESCE((p.value->>'isVariable')::boolean, false) = false
    AND COALESCE(NULLIF(p.value->>'price', '')::numeric, 0) > 0;

  RETURN jsonb_build_object(
    'store_name', COALESCE(NULLIF(v_setting_name, ''), v_store_name, 'Estabelecimento'),
    'store_phone', COALESCE(v_phone, ''),
    'store_address', COALESCE(v_address, ''),
    'products', v_products
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpc_create_public_delivery_order(
  p_store_id uuid,
  p_client_name text,
  p_client_phone text,
  p_address text,
  p_payment text,
  p_cash_given numeric,
  p_observation text,
  p_items jsonb,
  p_request_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, extensions
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
  v_client_phone text;
  v_address text;
  v_payment text;
  v_cash_given numeric(12,2) := 0;
  v_change numeric(12,2) := 0;
  v_observation text;
  v_now timestamptz := now();
  v_local_now timestamp;
  v_code text;
  v_random bytea;
  v_number bigint;
  v_attempt integer;
  v_existing public.vortex_kds_orders%ROWTYPE;
BEGIN
  IF p_store_id IS NULL OR p_request_id IS NULL THEN
    RAISE EXCEPTION 'Estabelecimento ou identificador do pedido inválido.';
  END IF;
  IF NOT public.rpc_get_public_delivery_enabled(p_store_id) THEN
    RAISE EXCEPTION 'Este estabelecimento não está aceitando pedidos online no momento.';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.vortex_stores WHERE id = p_store_id AND status = 'active') THEN
    RAISE EXCEPTION 'Estabelecimento não encontrado ou inativo.';
  END IF;

  -- Reenvio do mesmo checkout retorna o pedido e o mesmo código, sem duplicar venda.
  SELECT * INTO v_existing
  FROM public.vortex_kds_orders
  WHERE store_id = p_store_id AND public_request_id = p_request_id;
  IF FOUND THEN
    SELECT code INTO v_code
    FROM public.vortex_delivery_verifications
    WHERE store_id = p_store_id AND order_id = v_existing.id
      AND is_active = true AND consumed_at IS NULL AND expires_at > now();
    RETURN jsonb_build_object(
      'success', true, 'duplicate', true,
      'order_id', v_existing.id,
      'display_id', COALESCE(v_existing."displayId", ''),
      'total', v_existing.total,
      'code', COALESCE(v_code, '')
    );
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext(p_store_id::text), hashtext(COALESCE(p_client_phone, '')));
  SELECT * INTO v_existing
  FROM public.vortex_kds_orders
  WHERE store_id = p_store_id AND public_request_id = p_request_id;
  IF FOUND THEN
    SELECT code INTO v_code
    FROM public.vortex_delivery_verifications
    WHERE store_id = p_store_id AND order_id = v_existing.id
      AND is_active = true AND consumed_at IS NULL AND expires_at > now();
    RETURN jsonb_build_object(
      'success', true, 'duplicate', true,
      'order_id', v_existing.id,
      'display_id', COALESCE(v_existing."displayId", ''),
      'total', v_existing.total,
      'code', COALESCE(v_code, '')
    );
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.vortex_kds_orders
    WHERE store_id = p_store_id
      AND origin ILIKE '%Delivery%'
      AND regexp_replace(client, '^.*\\(([^()]*)\\)$', '\\1') = regexp_replace(COALESCE(p_client_phone, ''), '\\D', '', 'g')
      AND created_at > v_now - interval '3 seconds'
  ) THEN
    RAISE EXCEPTION 'Aguarde alguns segundos antes de enviar outro pedido.';
  END IF;

  IF jsonb_typeof(p_items) IS DISTINCT FROM 'array'
     OR jsonb_array_length(p_items) < 1 OR jsonb_array_length(p_items) > 30 THEN
    RAISE EXCEPTION 'O pedido precisa conter entre 1 e 30 itens.';
  END IF;

  v_client_name := left(trim(COALESCE(p_client_name, '')), 80);
  v_client_phone := left(regexp_replace(COALESCE(p_client_phone, ''), '[^0-9+() -]', '', 'g'), 30);
  v_address := left(trim(COALESCE(p_address, '')), 500);
  v_payment := left(trim(COALESCE(p_payment, '')), 60);
  v_observation := left(trim(COALESCE(p_observation, '')), 500);

  IF v_client_name = '' OR length(regexp_replace(v_client_phone, '\\D', '', 'g')) < 10
     OR v_address = '' OR v_payment NOT IN ('Pix', 'Cartão de Débito', 'Cartão de Crédito', 'Dinheiro') THEN
    RAISE EXCEPTION 'Confira nome, telefone, endereço e forma de pagamento.';
  END IF;

  SELECT data INTO v_catalog
  FROM public.vortex_store_documents
  WHERE store_id = p_store_id AND document_key = 'catalog';
  v_products := CASE WHEN jsonb_typeof(v_catalog->'products') = 'array'
    THEN v_catalog->'products' ELSE '[]'::jsonb END;

  FOR v_item IN SELECT value FROM jsonb_array_elements(p_items)
  LOOP
    v_product_id := v_item->>'id';
    v_qty := (v_item->>'qty')::integer;
    IF v_product_id IS NULL OR v_qty IS NULL OR v_qty < 1 OR v_qty > 30 THEN
      RAISE EXCEPTION 'Produto ou quantidade inválida.';
    END IF;

    SELECT p.value INTO v_product
    FROM jsonb_array_elements(v_products) p(value)
    WHERE p.value->>'id' = v_product_id
      AND COALESCE((p.value->>'active')::boolean, true) = true
      AND COALESCE((p.value->>'showDelivery')::boolean, true) = true
      AND COALESCE((p.value->>'isKg')::boolean, false) = false
      AND COALESCE((p.value->>'isVariable')::boolean, false) = false
    LIMIT 1;
    IF v_product IS NULL THEN
      RAISE EXCEPTION 'Um dos produtos não está mais disponível no cardápio.';
    END IF;

    v_price := COALESCE(NULLIF(v_product->>'price', '')::numeric, 0);
    IF v_price <= 0 THEN RAISE EXCEPTION 'Preço inválido para um dos produtos.'; END IF;
    v_order_items := v_order_items || jsonb_build_array(jsonb_build_object(
      'id', v_product->'id', 'name', v_product->>'name',
      'qty', v_qty, 'price', v_price, 'total', round(v_price * v_qty, 2)
    ));
    v_total := v_total + v_price * v_qty;
  END LOOP;

  IF v_payment = 'Dinheiro' THEN
    v_cash_given := COALESCE(p_cash_given, 0);
    IF v_cash_given < v_total THEN
      RAISE EXCEPTION 'O valor informado para pagamento em dinheiro é insuficiente.';
    END IF;
    v_change := v_cash_given - v_total;
  END IF;

  v_local_now := v_now AT TIME ZONE 'America/Sao_Paulo';
  v_order_id := 'webdeliv-' || replace(gen_random_uuid()::text, '-', '');
  v_display_id := lpad((floor(random() * 9000) + 1000)::integer::text, 4, '0');

  INSERT INTO public.vortex_kds_orders (
    store_id, id, origin, client, address, payment, cashgiven, change,
    time, date, dateformatted, items, total, observation, status, code,
    financial_status, updated_at, "displayId", public_request_id
  ) VALUES (
    p_store_id, v_order_id, 'Delivery Online',
    v_client_name || ' (' || v_client_phone || ')', v_address,
    v_payment, v_cash_given, v_change,
    to_char(v_local_now, 'HH24:MI'), v_local_now::date,
    to_char(v_local_now, 'DD/MM/YYYY'), v_order_items, round(v_total, 2),
    v_observation, 'new', '',
    'paid', v_now, v_display_id, p_request_id
  );

  INSERT INTO public.vortex_sales_history (
    store_id, id, client, channel, total, subtotal, discount, pay_method,
    status, financial_status, date, time, items, updated_at
  ) VALUES (
    p_store_id, v_order_id, v_client_name || ' (' || v_client_phone || ')',
    'Delivery Online', round(v_total, 2), round(v_total, 2), 0,
    v_payment, 'completed', 'paid', v_local_now::date, to_char(v_local_now, 'HH24:MI'),
    v_order_items, v_now
  );

  UPDATE public.vortex_delivery_verifications
  SET is_active = false
  WHERE store_id = p_store_id AND is_active = true AND expires_at <= now();

  FOR v_attempt IN 1..30 LOOP
    v_random := gen_random_bytes(4);
    v_number := (get_byte(v_random, 0)::bigint * 16777216
      + get_byte(v_random, 1)::bigint * 65536
      + get_byte(v_random, 2)::bigint * 256
      + get_byte(v_random, 3)::bigint) % 1000000;
    v_code := lpad(v_number::text, 6, '0');
    BEGIN
      INSERT INTO public.vortex_delivery_verifications (
        store_id, order_id, code, access_token_hash, attempt_count,
        locked_until, expires_at, consumed_at, is_active, created_at
      ) VALUES (
        p_store_id, v_order_id, v_code, NULL, 0, NULL,
        v_now + interval '48 hours', NULL, true, v_now
      );
      RETURN jsonb_build_object(
        'success', true, 'duplicate', false,
        'order_id', v_order_id, 'display_id', v_display_id,
        'total', round(v_total, 2), 'code', v_code
      );
    EXCEPTION WHEN unique_violation THEN
      NULL;
    END;
  END LOOP;

  RAISE EXCEPTION 'Não foi possível gerar o código de entrega. Tente novamente.';
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_set_public_delivery_enabled(boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.rpc_get_public_delivery_enabled(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.rpc_get_public_delivery_menu(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.rpc_create_public_delivery_order(uuid, text, text, text, text, numeric, text, jsonb, uuid) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.rpc_set_public_delivery_enabled(boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_get_public_delivery_enabled(uuid) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_get_public_delivery_menu(uuid) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_create_public_delivery_order(uuid, text, text, text, text, numeric, text, jsonb, uuid) TO anon, authenticated;

COMMIT;
