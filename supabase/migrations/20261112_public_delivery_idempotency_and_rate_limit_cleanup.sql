-- VORTEX FOOD: idempotência robusta do checkout público de delivery
-- e retenção periódica da tabela interna de rate limit.
-- Aplicar depois de 20261111_public_qr_security_hardening.sql.

BEGIN;

-- Índice para a remoção eficiente de janelas antigas.
CREATE INDEX IF NOT EXISTS vortex_public_rate_limits_window_started_idx
  ON public.vortex_public_rate_limits (window_started_at);

-- A função pública serializa primeiro pelo identificador do checkout.
-- Reenvios do mesmo request_id recuperam a confirmação existente, mesmo se
-- chegarem simultaneamente com dados de telefone diferentes.
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

  IF NOT public.rpc_get_public_delivery_enabled(p_store_id) THEN
    RAISE EXCEPTION 'Este estabelecimento não está aceitando pedidos online no momento.';
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

  v_phone_bucket := md5(
    regexp_replace(left(COALESCE(p_client_phone, ''), 30), '\\D', '', 'g')
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

-- Limpeza limitada e segura: remove somente contadores de rate limit cujo
-- período terminou há mais de 48 horas. Nenhum pedido/venda/código é afetado.
CREATE OR REPLACE FUNCTION public.rpc_cleanup_public_rate_limits()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $function$
DECLARE
  v_deleted integer;
BEGIN
  WITH expired AS (
    SELECT ctid
    FROM public.vortex_public_rate_limits
    WHERE window_started_at < now() - interval '48 hours'
    ORDER BY window_started_at
    LIMIT 5000
  )
  DELETE FROM public.vortex_public_rate_limits r
  USING expired e
  WHERE r.ctid = e.ctid;

  GET DIAGNOSTICS v_deleted = ROW_COUNT;
  RETURN v_deleted;
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_cleanup_public_rate_limits() FROM PUBLIC, anon, authenticated, service_role;

-- Agenda a limpeza de hora em hora somente se pg_cron já estiver instalado.
-- Não instala extensão nem interrompe a migração quando pg_cron não existe.
DO $block$
DECLARE
  v_job_id bigint;
BEGIN
  IF EXISTS (SELECT 1 FROM pg_catalog.pg_extension WHERE extname = 'pg_cron')
     AND pg_catalog.to_regnamespace('cron') IS NOT NULL THEN

    FOR v_job_id IN EXECUTE
      'SELECT jobid FROM cron.job WHERE jobname = $1'
      USING 'vortex-public-rate-limits-cleanup'
    LOOP
      EXECUTE 'SELECT cron.unschedule($1)' USING v_job_id;
    END LOOP;

    EXECUTE
      'SELECT cron.schedule($1, $2, $3)'
      USING
        'vortex-public-rate-limits-cleanup',
        '17 * * * *',
        'SELECT public.rpc_cleanup_public_rate_limits();';
  END IF;
END;
$block$;

COMMIT;
