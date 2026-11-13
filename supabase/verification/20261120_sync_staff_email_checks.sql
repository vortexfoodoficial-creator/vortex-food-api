-- Verificação da sincronização de e-mail de autenticação com o cadastro da equipe.
SELECT column_name, data_type
FROM information_schema.columns
WHERE table_schema='public' AND table_name='vortex_store_members'
  AND column_name='auth_email';

SELECT p.proname,
       p.prosecdef AS security_definer,
       has_function_privilege('anon', p.oid, 'EXECUTE') AS anon_execute,
       has_function_privilege('authenticated', p.oid, 'EXECUTE') AS authenticated_execute,
       has_function_privilege('service_role', p.oid, 'EXECUTE') AS service_role_execute
FROM pg_proc p
JOIN pg_namespace n ON n.oid=p.pronamespace
WHERE n.nspname='public' AND p.proname='rpc_sync_my_auth_email';

-- Verifica se os e-mails de autenticação foram inicializados para os membros existentes.
SELECT count(*) AS members_with_email,
       count(*) FILTER (WHERE m.auth_email IS NOT NULL) AS members_with_synced_auth_email,
       count(*) FILTER (WHERE m.auth_email IS DISTINCT FROM lower(u.email)) AS members_with_email_mismatch
FROM public.vortex_store_members m
JOIN auth.users u ON u.id=m.user_id;
