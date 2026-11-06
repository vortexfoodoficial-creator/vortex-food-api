-- VORTEX FOOD: reforço dos fluxos públicos de QR Code e delivery.
-- Executar uma única vez depois das migrações 20261106 a 20261110.
-- Mantém as assinaturas RPC usadas pelo frontend e encapsula as funções atuais.

BEGIN;

-- Quantidade de mesas passa a ser configuração central por estabelecimento.
-- O módulo autenticado fará a migração inicial do valor local para este documento.
CREATE OR REPLACE FUNCTION public.rpc_get_public_table_count(p_store_id uuid)
RETURNS integer
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $function$
  SELECT CASE
    WHEN d.data->>'totalTablesCount' ~ '^[0-9]{1,3}$'
      THEN LEAST(200, GREATEST(1, (d.data->>'totalTablesCount')::integer))
    ELSE 10
  END
  FROM public.vortex_stores s
  LEFT JOIN public.vortex_store_documents d
    ON d.store_id = s.id AND d.document_key = 'table_settings'
  WHERE s.id = p_store_id AND s.status = 'active';
$function$;

REVOKE ALL ON FUNCTION public.rpc_get_public_table_count(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpc_get_public_table_count(uuid) TO anon, authenticated;

-- Tabela interna para limitar chamadas públicas sem expor IP ou dados de clientes.
CREATE TABLE IF NOT EXISTS public.vortex_public_rate_limits (
  store_id uuid NOT NULL REFERENCES public.vortex_stores(id) ON DELETE CASCADE,
  bucket_key text NOT NULL,
  window_started_at timestamptz NOT NULL DEFAULT now(),
  request_count integer NOT NULL DEFAULT 0 CHECK (request_count >= 0),
  PRIMARY KEY (store_id, bucket_key)
);

ALTER TABLE public.vortex_public_rate_limits ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.vortex_public_rate_limits FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.vortex_public_rate_limit_allow(
  p_store_id uuid,
  p_bucket_key text,
  p_max_requests integer,
  p_window_seconds integer
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $function$
DECLARE
  v_count integer;
  v_window timestamptz;
BEGIN
  IF p_store_id IS NULL OR p_bucket_key IS NULL
     OR p_max_requests < 1 OR p_window_seconds < 1 THEN
    RETURN false;
  END IF;

  INSERT INTO public.vortex_public_rate_limits
    (store_id, bucket_key, window_started_at, request_count)
  VALUES
    (p_store_id, left(p_bucket_key, 120), now(), 1)
  ON CONFLICT (store_id, bucket_key)
  DO UPDATE SET
    window_started_at = CASE
      WHEN public.vortex_public_rate_limits.window_started_at
           <= now() - make_interval(secs => p_window_seconds)
        THEN now()
      ELSE public.vortex_public_rate_limits.window_started_at
    END,
    request_count = CASE
      WHEN public.vortex_public_rate_limits.window_started_at
           <= now() - make_interval(secs => p_window_seconds)
        THEN 1
      ELSE public.vortex_public_rate_limits.request_count + 1
    END
  RETURNING request_count, window_started_at INTO v_count, v_window;

  RETURN v_count <= p_max_requests;
END;
$function$;

REVOKE ALL ON FUNCTION public.vortex_public_rate_limit_allow(uuid, text, integer, integer)
  FROM PUBLIC, anon, authenticated, service_role;

-- Preserva a implementação validada de cada RPC, mas coloca validação de mesa
-- e limite de frequência antes de permitir que ela seja executada.
ALTER FUNCTION public.rpc_create_public_table_request(uuid, integer, text)
  RENAME TO _vortex_rpc_create_public_table_request_unchecked_20261111;

REVOKE ALL ON FUNCTION public._vortex_rpc_create_public_table_request_unchecked_20261111(uuid, integer, text)
  FROM PUBLIC, anon, authenticated, service_role;

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
BEGIN
  v_table_count := public.rpc_get_public_table_count(p_store_id);
  IF v_table_count IS NULL OR p_table_number IS NULL
     OR p_table_number < 1 OR p_table_number > v_table_count THEN
    RAISE EXCEPTION 'Esta mesa não está cadastrada neste estabelecimento.';
  END IF;
  IF p_request_type NOT IN ('call_waiter', 'request_bill')
     OR NOT public.rpc_get_public_qr_enabled(p_store_id) THEN
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

REVOKE ALL ON FUNCTION public.rpc_create_public_table_request(uuid, integer, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpc_create_public_table_request(uuid, integer, text)
  TO anon, authenticated, service_role;

ALTER FUNCTION public.rpc_create_public_table_order(uuid, integer, text, text, jsonb, uuid)
  RENAME TO _vortex_rpc_create_public_table_order_unchecked_20261111;

REVOKE ALL ON FUNCTION public._vortex_rpc_create_public_table_order_unchecked_20261111(uuid, integer, text, text, jsonb, uuid)
  FROM PUBLIC, anon, authenticated, service_role;

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
BEGIN
  v_table_count := public.rpc_get_public_table_count(p_store_id);
  IF v_table_count IS NULL OR p_table_number IS NULL
     OR p_table_number < 1 OR p_table_number > v_table_count THEN
    RAISE EXCEPTION 'Esta mesa não está cadastrada neste estabelecimento.';
  END IF;
  IF p_request_id IS NULL OR NOT public.rpc_get_public_qr_enabled(p_store_id) THEN
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

REVOKE ALL ON FUNCTION public.rpc_create_public_table_order(uuid, integer, text, text, jsonb, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpc_create_public_table_order(uuid, integer, text, text, jsonb, uuid)
  TO anon, authenticated, service_role;

ALTER FUNCTION public.rpc_create_public_delivery_order(
  uuid, text, text, text, text, numeric, text, jsonb, uuid
) RENAME TO _vortex_rpc_create_public_delivery_order_unchecked_20261111;

REVOKE ALL ON FUNCTION public._vortex_rpc_create_public_delivery_order_unchecked_20261111(
  uuid, text, text, text, text, numeric, text, jsonb, uuid
) FROM PUBLIC, anon, authenticated, service_role;

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
BEGIN
  IF NOT public.rpc_get_public_delivery_enabled(p_store_id) THEN
    RAISE EXCEPTION 'Este estabelecimento não está aceitando pedidos online no momento.';
  END IF;

  v_phone_bucket := md5(regexp_replace(left(COALESCE(p_client_phone, ''), 30), '\D', '', 'g'));

  IF NOT public.vortex_public_rate_limit_allow(
    p_store_id, 'delivery-order:store', 300, 60
  ) OR NOT public.vortex_public_rate_limit_allow(
    p_store_id, 'delivery-order:phone:' || v_phone_bucket, 5, 60
  ) THEN
    RAISE EXCEPTION 'Muitos pedidos enviados em pouco tempo. Aguarde um instante e tente novamente.';
  END IF;

  RETURN public._vortex_rpc_create_public_delivery_order_unchecked_20261111(
    p_store_id, p_client_name, p_client_phone, p_address, p_payment,
    p_cash_given, p_observation, p_items, p_request_id
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_create_public_delivery_order(
  uuid, text, text, text, text, numeric, text, jsonb, uuid
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpc_create_public_delivery_order(
  uuid, text, text, text, text, numeric, text, jsonb, uuid
) TO anon, authenticated, service_role;

COMMIT;
