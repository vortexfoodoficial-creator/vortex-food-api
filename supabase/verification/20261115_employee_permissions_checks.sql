-- VORTEX FOOD: verificações pós-migração de permissões por funcionário.
-- Executar no SQL Editor do Supabase somente DEPOIS de aplicar:
-- 1) 20261114_employee_permissions_foundation.sql
-- 2) 20261115_employee_permission_rls_and_secure_operations.sql
-- Todas as consultas abaixo são somente leitura.

-- 1. RLS ativo nas tabelas protegidas.
SELECT
  c.relname AS tabela,
  c.relrowsecurity AS rls_ativo,
  c.relforcerowsecurity AS rls_forcado
FROM pg_class c
JOIN pg_namespace n ON n.oid=c.relnamespace
WHERE n.nspname='public'
  AND c.relname IN (
    'cash_shifts','vortex_financial','vortex_integrations','vortex_kds',
    'vortex_kds_orders','vortex_sales','vortex_sales_history',
    'vortex_stock_items','vortex_stock_movements','vortex_store_settings',
    'vortex_store_documents','vortex_public_delivery_settings',
    'vortex_public_store_settings','vortex_public_table_requests',
    'vortex_subscriptions','vortex_stores'
  )
ORDER BY c.relname;

-- 2. Políticas instaladas: conferir que as tabelas operacionais usam permissões específicas.
SELECT schemaname,tablename,policyname,cmd,roles,qual,with_check
FROM pg_policies
WHERE schemaname='public'
  AND tablename IN (
    'cash_shifts','vortex_financial','vortex_integrations','vortex_kds',
    'vortex_kds_orders','vortex_sales','vortex_sales_history',
    'vortex_stock_items','vortex_stock_movements','vortex_store_settings',
    'vortex_store_documents','vortex_public_delivery_settings',
    'vortex_public_store_settings','vortex_public_table_requests',
    'vortex_subscriptions','vortex_stores'
  )
ORDER BY tablename,policyname;

-- 3. Privilégios diretos. Nenhuma tabela operacional deve ter acesso anônimo.
SELECT
  table_name,
  has_table_privilege('anon','public.'||table_name,'SELECT') AS anon_select,
  has_table_privilege('anon','public.'||table_name,'INSERT') AS anon_insert,
  has_table_privilege('authenticated','public.'||table_name,'SELECT') AS authenticated_select,
  has_table_privilege('authenticated','public.'||table_name,'INSERT') AS authenticated_insert,
  has_table_privilege('authenticated','public.'||table_name,'UPDATE') AS authenticated_update,
  has_table_privilege('authenticated','public.'||table_name,'DELETE') AS authenticated_delete
FROM (VALUES
  ('cash_shifts'),('vortex_financial'),('vortex_integrations'),
  ('vortex_kds_orders'),('vortex_sales_history'),('vortex_stock_items'),
  ('vortex_stock_movements'),('vortex_store_documents'),('vortex_stores')
) AS t(table_name)
ORDER BY table_name;

-- 4. Funções críticas: SECURITY DEFINER, search_path e execução por anon/authenticated.
SELECT
  p.proname AS funcao,
  p.prosecdef AS security_definer,
  p.proconfig AS configuracao,
  has_function_privilege('anon',p.oid,'EXECUTE') AS anon_execute,
  has_function_privilege('authenticated',p.oid,'EXECUTE') AS authenticated_execute,
  has_function_privilege('service_role',p.oid,'EXECUTE') AS service_role_execute
FROM pg_proc p
JOIN pg_namespace n ON n.oid=p.pronamespace
WHERE n.nspname='public'
  AND p.proname IN (
    'rpc_get_my_permissions','rpc_accept_staff_invitation',
    'rpc_admin_replace_member_permissions','rpc_create_sale',
    'rpc_update_kds_order_status','rpc_update_delivery_order',
    'rpc_close_cash_shift','rpc_record_cash_movement',
    'rpc_consume_stock_for_order','rpc_consume_stock_for_order_secure',
    'rpc_cancel_order','rpc_set_public_qr_enabled',
    'rpc_set_public_delivery_enabled','rpc_confirm_delivery_code',
    'rpc_mark_delivery_manual','rpc_get_stock_items',
    'rpc_save_stock_items','rpc_adjust_stock_item',
    'rpc_get_integrations','rpc_get_kds_orders',
    'rpc_save_store_document','rpc_get_store_document',
    'rpc_get_store_operational_settings','rpc_get_my_store_context'
  )
ORDER BY p.proname;

-- 5. Perfis e permissões-base cadastrados.
SELECT
  p.profile_key,
  p.label,
  COUNT(*) FILTER (WHERE pp.allowed) AS permissoes_liberadas
FROM public.vortex_permission_profiles p
LEFT JOIN public.vortex_profile_permissions pp ON pp.profile_key=p.profile_key
GROUP BY p.profile_key,p.label
ORDER BY p.profile_key;

-- 6. Colunas de auditoria e vínculo de entregador.
SELECT table_name,column_name,data_type
FROM information_schema.columns
WHERE table_schema='public'
  AND (
    (table_name='vortex_kds_orders' AND column_name IN ('courier_member_id','created_by','updated_by'))
    OR (table_name='cash_shifts' AND column_name IN ('opened_by','closed_by','updated_by'))
    OR (table_name='vortex_sales_history' AND column_name IN ('created_by','updated_by','cancelled_by'))
  )
ORDER BY table_name,column_name;

-- 7. Contagem da trilha de auditoria de permissões (não deve ser zero depois de alterar permissões).
SELECT event_type,COUNT(*) AS quantidade,MAX(created_at) AS ultimo_evento
FROM public.vortex_permission_audit_log
GROUP BY event_type
ORDER BY event_type;


-- 8. A função de auditoria deve preservar o autor original em atualizações.
SELECT
  position($needle$jsonb_set(v_new,'{created_by}',COALESCE(v_old->'created_by','null'::jsonb),true)$needle$ in
    pg_get_functiondef('public.vortex_set_actor_audit_fields()'::regprocedure)
  ) > 0 AS created_by_immutable_on_update;
