-- VORTEX FOOD: confirmação privada de entrega por código de seis dígitos.
-- Executar depois das migrações de isolamento e de pedidos públicos já aplicadas.

BEGIN;

CREATE SCHEMA IF NOT EXISTS extensions;
CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;

CREATE TABLE IF NOT EXISTS public.vortex_delivery_verifications (
  store_id uuid NOT NULL REFERENCES public.vortex_stores(id) ON DELETE CASCADE,
  order_id text NOT NULL,
  code text NOT NULL CHECK (code ~ '^[0-9]{6}$'),
  access_token_hash text NOT NULL,
  attempt_count integer NOT NULL DEFAULT 0 CHECK (attempt_count >= 0),
  locked_until timestamptz,
  expires_at timestamptz NOT NULL,
  consumed_at timestamptz,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT vortex_delivery_verifications_pkey PRIMARY KEY (store_id, order_id)
);

CREATE UNIQUE INDEX IF NOT EXISTS vortex_delivery_verifications_active_code_unique
  ON public.vortex_delivery_verifications (store_id, code)
  WHERE is_active = true;

CREATE INDEX IF NOT EXISTS vortex_delivery_verifications_expiration_idx
  ON public.vortex_delivery_verifications (store_id, expires_at)
  WHERE is_active = true;

ALTER TABLE public.vortex_delivery_verifications ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.vortex_delivery_verifications FROM PUBLIC, anon, authenticated;

-- Apaga códigos antigos expostos no registro administrativo dos pedidos Delivery.
-- O campo code de pedidos de mesa permanece preservado.
UPDATE public.vortex_kds_orders
SET code = ''
WHERE origin ILIKE '%Delivery%'
  AND code IS NOT NULL;

CREATE OR REPLACE FUNCTION public.rpc_issue_delivery_verification(p_store_id uuid, p_order_id text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, extensions
AS $function$
DECLARE
  v_origin text;
  v_status text;
  v_random bytea;
  v_number bigint;
  v_code text;
  v_token text;
  v_expires_at timestamptz;
  v_attempt integer;
BEGIN
  IF auth.uid() IS NULL OR NOT public.vortex_user_has_store_access(p_store_id) THEN
    RAISE EXCEPTION 'Acesso não autorizado a este estabelecimento.';
  END IF;

  SELECT origin, status INTO v_origin, v_status
  FROM public.vortex_kds_orders
  WHERE store_id = p_store_id AND id = p_order_id
  FOR UPDATE;

  IF NOT FOUND OR COALESCE(v_origin, '') NOT ILIKE '%Delivery%' THEN
    RAISE EXCEPTION 'Pedido de delivery não encontrado neste estabelecimento.';
  END IF;
  IF v_status IN ('finished', 'cancelled') THEN
    RAISE EXCEPTION 'Não é possível gerar código para um pedido já finalizado ou cancelado.';
  END IF;

  UPDATE public.vortex_delivery_verifications
  SET is_active = false
  WHERE store_id = p_store_id AND is_active = true AND expires_at <= now();

  v_expires_at := now() + interval '48 hours';

  FOR v_attempt IN 1..30 LOOP
    v_random := gen_random_bytes(4);
    v_number :=
      (get_byte(v_random, 0)::bigint * 16777216
       + get_byte(v_random, 1)::bigint * 65536
       + get_byte(v_random, 2)::bigint * 256
       + get_byte(v_random, 3)::bigint) % 1000000;
    v_code := lpad(v_number::text, 6, '0');
    v_token := encode(gen_random_bytes(32), 'hex');

    BEGIN
      INSERT INTO public.vortex_delivery_verifications (
        store_id, order_id, code, access_token_hash, attempt_count,
        locked_until, expires_at, consumed_at, is_active, created_at
      ) VALUES (
        p_store_id, p_order_id, v_code, md5(v_token), 0,
        NULL, v_expires_at, NULL, true, now()
      )
      ON CONFLICT (store_id, order_id) DO UPDATE
      SET code = EXCLUDED.code,
          access_token_hash = EXCLUDED.access_token_hash,
          attempt_count = 0,
          locked_until = NULL,
          expires_at = EXCLUDED.expires_at,
          consumed_at = NULL,
          is_active = true,
          created_at = now();

      RETURN jsonb_build_object('success', true, 'access_token', v_token, 'expires_at', v_expires_at);
    EXCEPTION WHEN unique_violation THEN
      NULL;
    END;
  END LOOP;

  RAISE EXCEPTION 'Não foi possível gerar um código exclusivo. Tente novamente.';
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpc_get_delivery_code(p_store_id uuid, p_order_id text, p_access_token text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $function$
DECLARE
  v_code text;
  v_expires_at timestamptz;
BEGIN
  IF p_store_id IS NULL OR COALESCE(p_order_id, '') = ''
     OR COALESCE(p_access_token, '') !~ '^[a-f0-9]{64}$' THEN
    RETURN jsonb_build_object('success', false, 'message', 'Link de acesso inválido.');
  END IF;

  SELECT code, expires_at INTO v_code, v_expires_at
  FROM public.vortex_delivery_verifications
  WHERE store_id = p_store_id
    AND order_id = p_order_id
    AND access_token_hash = md5(p_access_token)
    AND is_active = true
    AND consumed_at IS NULL
    AND expires_at > now();

  IF v_code IS NULL THEN
    RETURN jsonb_build_object('success', false, 'message', 'Este link expirou ou já foi utilizado. Solicite um novo link ao estabelecimento.');
  END IF;

  RETURN jsonb_build_object('success', true, 'code', v_code, 'expires_at', v_expires_at);
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpc_confirm_delivery_code(p_store_id uuid, p_order_id text, p_code text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $function$
DECLARE
  v_verification public.vortex_delivery_verifications%ROWTYPE;
  v_origin text;
  v_status text;
  v_attempts integer;
BEGIN
  IF auth.uid() IS NULL OR NOT public.vortex_user_has_store_access(p_store_id) THEN
    RAISE EXCEPTION 'Acesso não autorizado a este estabelecimento.';
  END IF;

  SELECT * INTO v_verification
  FROM public.vortex_delivery_verifications
  WHERE store_id = p_store_id AND order_id = p_order_id
  FOR UPDATE;

  IF NOT FOUND OR NOT v_verification.is_active
     OR v_verification.consumed_at IS NOT NULL
     OR v_verification.expires_at <= now() THEN
    RETURN jsonb_build_object('success', false, 'message', 'Código inexistente, expirado ou já utilizado.');
  END IF;

  IF v_verification.locked_until IS NOT NULL AND v_verification.locked_until > now() THEN
    RETURN jsonb_build_object('success', false, 'message', 'Muitas tentativas incorretas. Aguarde 15 minutos antes de tentar novamente.');
  END IF;

  IF v_verification.attempt_count >= 5 THEN
    UPDATE public.vortex_delivery_verifications
    SET attempt_count = 0, locked_until = NULL
    WHERE store_id = p_store_id AND order_id = p_order_id;
    v_verification.attempt_count := 0;
  END IF;

  SELECT origin, status INTO v_origin, v_status
  FROM public.vortex_kds_orders
  WHERE store_id = p_store_id AND id = p_order_id
  FOR UPDATE;

  IF NOT FOUND OR COALESCE(v_origin, '') NOT ILIKE '%Delivery%' OR v_status <> 'delivering' THEN
    RETURN jsonb_build_object('success', false, 'message', 'Este pedido não está em rota de entrega.');
  END IF;

  IF COALESCE(p_code, '') !~ '^[0-9]{6}$' OR p_code <> v_verification.code THEN
    v_attempts := v_verification.attempt_count + 1;
    UPDATE public.vortex_delivery_verifications
    SET attempt_count = v_attempts,
        locked_until = CASE WHEN v_attempts >= 5 THEN now() + interval '15 minutes' ELSE NULL END
    WHERE store_id = p_store_id AND order_id = p_order_id;
    RETURN jsonb_build_object(
      'success', false,
      'message', CASE WHEN v_attempts >= 5
        THEN 'Limite de tentativas atingido. Aguarde 15 minutos.'
        ELSE 'Código incorreto. Confira os seis números e tente novamente.' END
    );
  END IF;

  UPDATE public.vortex_delivery_verifications
  SET is_active = false, consumed_at = now()
  WHERE store_id = p_store_id AND order_id = p_order_id;

  UPDATE public.vortex_kds_orders
  SET status = 'finished', updated_at = now()
  WHERE store_id = p_store_id AND id = p_order_id;

  RETURN jsonb_build_object('success', true, 'message', 'Entrega confirmada com sucesso.');
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpc_mark_delivery_manual(p_store_id uuid, p_order_id text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $function$
DECLARE
  v_updated_id text;
BEGIN
  IF auth.uid() IS NULL OR NOT public.vortex_user_has_store_access(p_store_id) THEN
    RAISE EXCEPTION 'Acesso não autorizado a este estabelecimento.';
  END IF;

  UPDATE public.vortex_kds_orders
  SET status = 'finished', updated_at = now()
  WHERE store_id = p_store_id
    AND id = p_order_id
    AND origin ILIKE '%Delivery%'
    AND status NOT IN ('finished', 'cancelled')
  RETURNING id INTO v_updated_id;

  IF v_updated_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'message', 'Pedido não encontrado ou já finalizado.');
  END IF;

  UPDATE public.vortex_delivery_verifications
  SET is_active = false, consumed_at = COALESCE(consumed_at, now())
  WHERE store_id = p_store_id AND order_id = p_order_id;

  RETURN jsonb_build_object('success', true, 'message', 'Pedido marcado como entregue manualmente.');
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_issue_delivery_verification(uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.rpc_get_delivery_code(uuid, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.rpc_confirm_delivery_code(uuid, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.rpc_mark_delivery_manual(uuid, text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.rpc_issue_delivery_verification(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_get_delivery_code(uuid, text, text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_confirm_delivery_code(uuid, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_mark_delivery_manual(uuid, text) TO authenticated;

COMMIT;
