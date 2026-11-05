-- VORTEX FOOD: fluxo público controlado de chamadas e solicitação de conta por QR Code.
-- Executar somente DEPOIS da migração 20261105_store_data_isolation.sql.
-- Clientes podem criar solicitações por RPC; nunca recebem acesso às tabelas internas.

BEGIN;

CREATE TABLE IF NOT EXISTS public.vortex_public_store_settings (
  store_id uuid PRIMARY KEY REFERENCES public.vortex_stores(id) ON DELETE CASCADE,
  qr_enabled boolean NOT NULL DEFAULT false,
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.vortex_public_table_requests (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  store_id uuid NOT NULL REFERENCES public.vortex_stores(id) ON DELETE CASCADE,
  table_number integer NOT NULL CHECK (table_number BETWEEN 1 AND 200),
  request_type text NOT NULL CHECK (request_type IN ('call_waiter', 'request_bill')),
  status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'attended', 'cancelled')),
  created_at timestamptz NOT NULL DEFAULT now(),
  handled_at timestamptz
);

CREATE INDEX IF NOT EXISTS vortex_public_table_requests_store_status_created_idx
  ON public.vortex_public_table_requests (store_id, status, created_at DESC);

ALTER TABLE public.vortex_public_store_settings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.vortex_public_table_requests ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS vortex_public_store_settings_member_access ON public.vortex_public_store_settings;
CREATE POLICY vortex_public_store_settings_member_access
  ON public.vortex_public_store_settings
  FOR ALL TO authenticated
  USING (public.vortex_user_has_store_access(store_id))
  WITH CHECK (public.vortex_user_has_store_access(store_id));

DROP POLICY IF EXISTS vortex_public_table_requests_member_access ON public.vortex_public_table_requests;
CREATE POLICY vortex_public_table_requests_member_access
  ON public.vortex_public_table_requests
  FOR ALL TO authenticated
  USING (public.vortex_user_has_store_access(store_id))
  WITH CHECK (public.vortex_user_has_store_access(store_id));

REVOKE ALL ON TABLE public.vortex_public_store_settings FROM PUBLIC, anon;
REVOKE ALL ON TABLE public.vortex_public_table_requests FROM PUBLIC, anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.vortex_public_store_settings TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.vortex_public_table_requests TO authenticated;

CREATE OR REPLACE FUNCTION public.rpc_set_public_qr_enabled(p_enabled boolean)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $function$
DECLARE
  v_store_id uuid;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Autenticação necessária.';
  END IF;

  SELECT m.store_id INTO v_store_id
  FROM public.vortex_store_members AS m
  WHERE m.user_id = auth.uid()
    AND m.status = 'active'
  ORDER BY m.created_at
  LIMIT 1;

  IF v_store_id IS NULL THEN
    RAISE EXCEPTION 'Estabelecimento ativo não identificado.';
  END IF;

  INSERT INTO public.vortex_public_store_settings (store_id, qr_enabled, updated_at)
  VALUES (v_store_id, COALESCE(p_enabled, false), now())
  ON CONFLICT (store_id)
  DO UPDATE SET qr_enabled = EXCLUDED.qr_enabled, updated_at = now();

  RETURN jsonb_build_object('success', true, 'qr_enabled', COALESCE(p_enabled, false));
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpc_get_public_qr_enabled(p_store_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $function$
  SELECT COALESCE((
    SELECT s.qr_enabled
    FROM public.vortex_public_store_settings AS s
    WHERE s.store_id = p_store_id
  ), false);
$function$;

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
  v_request_id uuid;
BEGIN
  IF p_store_id IS NULL OR p_table_number IS NULL OR p_table_number < 1 OR p_table_number > 200 THEN
    RAISE EXCEPTION 'Mesa ou estabelecimento inválido.';
  END IF;

  IF p_request_type NOT IN ('call_waiter', 'request_bill') THEN
    RAISE EXCEPTION 'Tipo de solicitação inválido.';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.vortex_stores WHERE id = p_store_id) THEN
    RAISE EXCEPTION 'Estabelecimento não encontrado.';
  END IF;

  IF NOT public.rpc_get_public_qr_enabled(p_store_id) THEN
    RAISE EXCEPTION 'O atendimento por QR Code está desativado neste estabelecimento.';
  END IF;

  -- Evita duplicar toques acidentais no mesmo botão em uma janela curta.
  SELECT r.id INTO v_request_id
  FROM public.vortex_public_table_requests AS r
  WHERE r.store_id = p_store_id
    AND r.table_number = p_table_number
    AND r.request_type = p_request_type
    AND r.status = 'pending'
    AND r.created_at > now() - interval '20 seconds'
  ORDER BY r.created_at DESC
  LIMIT 1;

  IF v_request_id IS NULL THEN
    INSERT INTO public.vortex_public_table_requests
      (store_id, table_number, request_type)
    VALUES
      (p_store_id, p_table_number, p_request_type)
    RETURNING id INTO v_request_id;
  END IF;

  RETURN jsonb_build_object('success', true, 'request_id', v_request_id);
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_set_public_qr_enabled(boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_set_public_qr_enabled(boolean) TO authenticated;

REVOKE ALL ON FUNCTION public.rpc_get_public_qr_enabled(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpc_get_public_qr_enabled(uuid) TO anon, authenticated;

REVOKE ALL ON FUNCTION public.rpc_create_public_table_request(uuid, integer, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpc_create_public_table_request(uuid, integer, text) TO anon, authenticated;

COMMIT;
