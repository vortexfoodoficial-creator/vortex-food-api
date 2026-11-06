-- VORTEX FOOD: ajustes de idempotência, rate limit e disponibilidade pública.
-- Aplicar depois de 20261112_public_delivery_idempotency_and_rate_limit_cleanup.sql.
-- Mantém as assinaturas públicas usadas pelo frontend e não altera dados operacionais.

BEGIN;

-- 1) Delivery: recuperar checkout existente antes de verificar se o delivery
-- continua habilitado. Normalizar telefone usando somente dígitos.
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
  v_phone_bucket text;
  v_existing public.vortex_kds_orders%ROWTYPE;
  v_code text;
BEGIN
  IF p_store_id IS NULL OR p_request_id IS NULL THEN
    RAISE EXCEPTION 'Estabelecimento ou identificador do pedido inválido.';
  END IF;

  -- Mesmo request_id, mesmo estabelecimento: apenas uma execução pode criar.
  PERFORM pg_advisory_xact_lock(
    hashtext(p_store_id::text),
    hashtext(p_request_id::text)
  );

  SELECT *
  INTO v_existing
  FROM public.vortex_kds_orders
  WHERE store_id = p_store_id
    AND public_request_id = p_request_id
  LIMIT 1;

  IF FOUND THEN
    SELECT code
    INTO v_code
    FROM public.vortex_delivery_verifications
    WHERE store_id = p_store_id
      AND order_id = v_existing.id
      AND is_active = true
      AND consumed_at IS NULL
      AND expires_at > now();

    RETURN jsonb_build_object(
      'success', true,
      'duplicate', true,
      'order_id', v_existing.id,
      'display_id', COALESCE(v_existing."displayId", ''),
      'total', v_existing.total,
      'code', COALESCE(v_code, '')
    );
  END IF;

  IF NOT public.rpc_get_public_delivery_enabled(p_store_id) THEN
    RAISE EXCEPTION 'Este estabelecimento não está aceitando pedidos online no momento.';
  END IF;

  v_phone_bucket := md5(
    regexp_replace(left(COALESCE(p_client_phone, ''), 30), '[^0-9]', '', 'g')
  );

  IF NOT public.vortex_public_rate_limit_allow(
    p_store_id, 'delivery-order:store', 300, 60
  ) OR NOT public.vortex_public_rate_limit_allow(
    p_store_id, 'delivery-order:phone:' || v_phone_bucket, 5, 60
  ) THEN
    RAISE EXCEPTION 'Muitos pedidos enviados em pouco tempo. Aguarde um instante e tente novamente.';
  END IF;

  RETURN public._vortex_rpc_create_public_delivery_order_unchecked_20261111(
    p_store_id,
    p_client_name,
    p_client_phone,
    p_address,
    p_payment,
    p_cash_given,
    p_observation,
    p_items,
    p_request_id
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_create_public_delivery_order(
  uuid, text, text, text, text, numeric, text, jsonb, uuid
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpc_create_public_delivery_order(
  uuid, text, text, text, text, numeric, text, jsonb, uuid
) TO anon, authenticated, service_role;

-- 2) Pedido de mesa: serializar pelo token do checkout e devolver um pedido
-- já criado antes de consumir qualquer contador de rate limit.
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
  v_table_count integer;
  v_existing public.vortex_kds_orders%ROWTYPE;
BEGIN
  v_table_count := public.rpc_get_public_table_count(p_store_id);
  IF v_table_count IS NULL OR p_table_number IS NULL
     OR p_table_number < 1 OR p_table_number > v_table_count THEN
    RAISE EXCEPTION 'Esta mesa não está cadastrada neste estabelecimento.';
  END IF;
  IF p_request_id IS NULL THEN
    RAISE EXCEPTION 'Pedido público inválido.';
  END IF;

  -- Serializa reenvios do mesmo token, inclusive quando chegam juntos.
  PERFORM pg_advisory_xact_lock(
    hashtext(p_store_id::text),
    hashtext(p_request_id::text)
  );

  SELECT *
  INTO v_existing
  FROM public.vortex_kds_orders
  WHERE store_id = p_store_id
    AND public_request_id = p_request_id
  LIMIT 1;

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
    RAISE EXCEPTION 'Pedido público inválido ou atendimento desativado.';
  END IF;

  IF NOT public.vortex_public_rate_limit_allow(
    p_store_id, 'table-order:store', 300, 60
  ) OR NOT public.vortex_public_rate_limit_allow(
    p_store_id, 'table-order:table:' || p_table_number::text, 8, 60
  ) THEN
    RAISE EXCEPTION 'Muitos pedidos enviados em pouco tempo. Aguarde um instante e tente novamente.';
  END IF;

  RETURN public._vortex_rpc_create_public_table_order_unchecked_20261111(
    p_store_id, p_table_number, p_client_name, p_observation, p_items, p_request_id
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_create_public_table_order(
  uuid, integer, text, text, jsonb, uuid
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpc_create_public_table_order(
  uuid, integer, text, text, jsonb, uuid
) TO anon, authenticated, service_role;

-- 3) Solicitação de mesa: localizar solicitação pendente idêntica sob o mesmo
-- bloqueio usado pela função original antes de consumir o rate limit.
CREATE OR REPLACE FUNCTION public.rpc_create_public_table_request(
  p_store_id uuid,
  p_table_number integer,
  p_request_type text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $function$
DECLARE
  v_table_count integer;
  v_request_id uuid;
BEGIN
  v_table_count := public.rpc_get_public_table_count(p_store_id);
  IF v_table_count IS NULL OR p_table_number IS NULL
     OR p_table_number < 1 OR p_table_number > v_table_count THEN
    RAISE EXCEPTION 'Esta mesa não está cadastrada neste estabelecimento.';
  END IF;

  IF p_request_type IS NULL
     OR p_request_type NOT IN ('call_waiter', 'request_bill') THEN
    RAISE EXCEPTION 'Tipo de solicitação inválido.';
  END IF;

  -- Usa a mesma chave de bloqueio da implementação original.
  PERFORM pg_advisory_xact_lock(hashtext(p_store_id::text), p_table_number);

  SELECT r.id
  INTO v_request_id
  FROM public.vortex_public_table_requests AS r
  WHERE r.store_id = p_store_id
    AND r.table_number = p_table_number
    AND r.request_type = p_request_type
    AND r.status = 'pending'
    AND r.created_at > now() - interval '20 seconds'
  ORDER BY r.created_at DESC
  LIMIT 1;

  IF v_request_id IS NOT NULL THEN
    RETURN jsonb_build_object('success', true, 'request_id', v_request_id);
  END IF;

  IF NOT public.rpc_get_public_qr_enabled(p_store_id) THEN
    RAISE EXCEPTION 'Solicitação pública inválida ou desativada.';
  END IF;

  IF NOT public.vortex_public_rate_limit_allow(
    p_store_id, 'table-request:store', 300, 60
  ) OR NOT public.vortex_public_rate_limit_allow(
    p_store_id, 'table-request:table:' || p_table_number::text, 5, 30
  ) THEN
    RAISE EXCEPTION 'Muitas solicitações em pouco tempo. Aguarde um instante e tente novamente.';
  END IF;

  RETURN public._vortex_rpc_create_public_table_request_unchecked_20261111(
    p_store_id, p_table_number, p_request_type
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_create_public_table_request(
  uuid, integer, text
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpc_create_public_table_request(
  uuid, integer, text
) TO anon, authenticated, service_role;

-- 4) Disponibilidade pública: lojas inativas nunca aparecem como habilitadas.
CREATE OR REPLACE FUNCTION public.rpc_get_public_delivery_enabled(p_store_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $function$
  SELECT COALESCE((
    SELECT d.delivery_enabled
    FROM public.vortex_stores AS s
    LEFT JOIN public.vortex_public_delivery_settings AS d
      ON d.store_id = s.id
    WHERE s.id = p_store_id
      AND s.status = 'active'
  ), false);
$function$;

REVOKE ALL ON FUNCTION public.rpc_get_public_delivery_enabled(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpc_get_public_delivery_enabled(uuid)
  TO anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.rpc_get_public_qr_enabled(p_store_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $function$
  SELECT COALESCE((
    SELECT q.qr_enabled
    FROM public.vortex_stores AS s
    LEFT JOIN public.vortex_public_store_settings AS q
      ON q.store_id = s.id
    WHERE s.id = p_store_id
      AND s.status = 'active'
  ), false);
$function$;

REVOKE ALL ON FUNCTION public.rpc_get_public_qr_enabled(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpc_get_public_qr_enabled(uuid)
  TO anon, authenticated, service_role;

COMMIT;
