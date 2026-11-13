-- Verificação da migração 20261119_account_session_management.sql
SELECT p.proname,
       p.prosecdef AS security_definer,
       has_function_privilege('anon', p.oid, 'EXECUTE') AS anon_execute,
       has_function_privilege('authenticated', p.oid, 'EXECUTE') AS authenticated_execute,
       has_function_privilege('service_role', p.oid, 'EXECUTE') AS service_role_execute
FROM pg_proc p
JOIN pg_namespace n ON n.oid=p.pronamespace
WHERE n.nspname='public' AND p.proname='rpc_get_my_auth_sessions';

-- Confirma os campos usados pelo RPC na versão instalada do Supabase Auth.
SELECT column_name, data_type
FROM information_schema.columns
WHERE table_schema='auth' AND table_name='sessions'
  AND column_name IN ('id','user_id','created_at','updated_at','user_agent','ip','not_after')
ORDER BY column_name;
