-- Histórico de segurança por conta, sem exposição direta das tabelas ao navegador.
BEGIN;

CREATE TABLE IF NOT EXISTS public.vortex_account_security_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  store_id uuid NOT NULL REFERENCES public.vortex_stores(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  event_type text NOT NULL CHECK (event_type IN (
    'account_email_change_requested',
    'account_email_changed',
    'account_password_changed',
    'account_other_sessions_signed_out'
  )),
  details jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS vortex_account_security_events_user_created_idx
  ON public.vortex_account_security_events(user_id, created_at DESC);

ALTER TABLE public.vortex_account_security_events ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.vortex_account_security_events FROM PUBLIC, anon, authenticated;
GRANT ALL ON TABLE public.vortex_account_security_events TO service_role;

CREATE OR REPLACE FUNCTION public.rpc_log_account_security_event(
  p_event_type text,
  p_details jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_store_id uuid;
  v_details jsonb := '{}'::jsonb;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Sessão inválida.';
  END IF;

  IF p_event_type NOT IN (
    'account_email_change_requested',
    'account_email_changed',
    'account_password_changed',
    'account_other_sessions_signed_out'
  ) THEN
    RAISE EXCEPTION 'Tipo de evento inválido.';
  END IF;

  SELECT m.store_id INTO v_store_id
  FROM public.vortex_store_members AS m
  WHERE m.user_id = v_user_id AND m.status = 'active'
  LIMIT 1;

  IF v_store_id IS NULL THEN
    RAISE EXCEPTION 'Não existe vínculo ativo com um estabelecimento.';
  END IF;

  -- Apenas metadados estritamente necessários são aceitos; nunca guardar senha,
  -- token, código de confirmação ou qualquer credencial.
  IF p_event_type = 'account_email_change_requested' THEN
    v_details := jsonb_build_object(
      'new_email',
      left(COALESCE(p_details->>'new_email', ''), 254)
    );
  END IF;

  INSERT INTO public.vortex_account_security_events(store_id, user_id, event_type, details)
  VALUES (v_store_id, v_user_id, p_event_type, v_details);

  RETURN jsonb_build_object('success', true);
END;
$$;

CREATE OR REPLACE FUNCTION public.rpc_get_account_security_events(
  p_limit integer DEFAULT 20
)
RETURNS TABLE (
  id uuid,
  event_type text,
  details jsonb,
  created_at timestamptz
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $$
  SELECT e.id, e.event_type, e.details, e.created_at
  FROM public.vortex_account_security_events AS e
  WHERE e.user_id = auth.uid()
    AND e.store_id IN (
      SELECT m.store_id
      FROM public.vortex_store_members AS m
      WHERE m.user_id = auth.uid() AND m.status = 'active'
    )
  ORDER BY e.created_at DESC
  LIMIT GREATEST(1, LEAST(COALESCE(p_limit, 20), 50));
$$;

REVOKE ALL ON FUNCTION public.rpc_log_account_security_event(text, jsonb) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.rpc_get_account_security_events(integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_log_account_security_event(text, jsonb) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.rpc_get_account_security_events(integer) TO authenticated, service_role;

COMMIT;
