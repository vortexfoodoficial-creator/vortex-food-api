-- Lista sessões autenticadas do próprio usuário sem expor auth.sessions diretamente.
BEGIN;

CREATE OR REPLACE FUNCTION public.rpc_get_my_auth_sessions()
RETURNS TABLE (
  session_id uuid,
  created_at timestamptz,
  updated_at timestamptz,
  user_agent text,
  ip_address text,
  not_after timestamptz,
  is_current boolean
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $$
  SELECT
    s.id,
    s.created_at,
    s.updated_at,
    s.user_agent,
    s.ip::text,
    s.not_after,
    s.id = NULLIF(auth.jwt()->>'session_id', '')::uuid
  FROM auth.sessions AS s
  WHERE s.user_id = auth.uid()
  ORDER BY s.updated_at DESC NULLS LAST
  LIMIT 50;
$$;

REVOKE ALL ON FUNCTION public.rpc_get_my_auth_sessions() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_get_my_auth_sessions() TO authenticated, service_role;

COMMIT;
