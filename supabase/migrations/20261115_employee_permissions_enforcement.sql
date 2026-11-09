-- VORTEX FOOD: enforcement de permissões por funcionário (fase 1).
-- Requer 20261114_employee_permissions_foundation.sql já aplicada.
-- Não apaga nem migra registros operacionais; substitui somente políticas RLS.
-- Entregadores veem somente pedidos atribuídos ao próprio user_id.

BEGIN;

DO $$
BEGIN
  IF to_regclass('public.vortex_permission_catalog') IS NULL
     OR to_regprocedure('public.vortex_user_has_permission(uuid,text)') IS NULL THEN
    RAISE EXCEPTION 'Aplique primeiro a migração 20261114_employee_permissions_foundation.sql. Nenhuma alteração foi feita.';
  END IF;
END;
$$;

ALTER TABLE public.vortex_kds_orders
  ADD COLUMN IF NOT EXISTS courier_member_id uuid;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid='public.vortex_kds_orders'::regclass
      AND conname='vortex_kds_orders_courier_member_fkey'
  ) THEN
    ALTER TABLE public.vortex_kds_orders
      ADD CONSTRAINT vortex_kds_orders_courier_member_fkey
      FOREIGN KEY (store_id,courier_member_id)
      REFERENCES public.vortex_store_members(store_id,user_id)
      ON DELETE SET NULL;
  END IF;
END;
$$;

CREATE INDEX IF NOT EXISTS vortex_kds_orders_courier_member_idx
  ON public.vortex_kds_orders(store_id,courier_member_id)
  WHERE courier_member_id IS NOT NULL;

-- Leitura e gravação de documentos JSON por chave: cada módulo recebe somente
-- o documento correspondente à sua permissão.
CREATE OR REPLACE FUNCTION public.vortex_user_can_access_document(
  p_store_id uuid,
  p_document_key text,
  p_write boolean DEFAULT false
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $function$
DECLARE
  v_read_permission text;
  v_write_permission text;
BEGIN
  IF p_store_id IS NULL OR p_document_key IS NULL THEN RETURN false; END IF;

  CASE p_document_key
    WHEN 'catalog' THEN
      v_read_permission := 'catalog.view';
      v_write_permission := 'catalog.manage_products';
    WHEN 'coupons' THEN
      v_read_permission := 'coupons.manage';
      v_write_permission := 'coupons.manage';
    WHEN 'loyalty' THEN
      v_read_permission := 'loyalty.manage';
      v_write_permission := 'loyalty.manage';
    WHEN 'customers' THEN
      v_read_permission := 'crm.view';
      v_write_permission := 'crm.manage';
    WHEN 'table_settings' THEN
      v_read_permission := 'tables.view';
      v_write_permission := 'tables.manage_qr';
    WHEN 'settings' THEN
      v_read_permission := 'settings.view';
      v_write_permission := 'settings.manage';
    WHEN 'staff' THEN
      v_read_permission := 'team.view';
      v_write_permission := 'team.manage';
    WHEN 'couriers' THEN
      v_read_permission := 'delivery.view';
      v_write_permission := 'delivery.manage_couriers';
    WHEN 'recipes' THEN
      v_read_permission := 'recipes.view';
      v_write_permission := 'recipes.manage';
    WHEN 'purchases' THEN
      v_read_permission := 'purchases.view';
      v_write_permission := 'purchases.manage';
    WHEN 'accounts' THEN
      v_read_permission := 'accounts.view';
      v_write_permission := 'accounts.manage';
    WHEN 'printer' THEN
      v_read_permission := 'printers.manage';
      v_write_permission := 'printers.manage';
    ELSE
      RETURN false;
  END CASE;

  IF p_write THEN
    IF p_document_key = 'catalog' THEN
      RETURN public.vortex_user_has_permission(p_store_id,'catalog.manage_products')
        OR public.vortex_user_has_permission(p_store_id,'catalog.manage_prices')
        OR public.vortex_user_has_permission(p_store_id,'catalog.manage_categories');
    END IF;
    RETURN public.vortex_user_has_permission(p_store_id,v_write_permission);
  END IF;

  RETURN public.vortex_user_has_permission(p_store_id,v_read_permission)
    OR (p_document_key = 'catalog' AND (
      public.vortex_user_has_permission(p_store_id,'catalog.manage_products')
      OR public.vortex_user_has_permission(p_store_id,'catalog.manage_prices')
      OR public.vortex_user_has_permission(p_store_id,'catalog.manage_categories')
    ));
END;
$function$;

REVOKE ALL ON FUNCTION public.vortex_user_can_access_document(uuid,text,boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.vortex_user_can_access_document(uuid,text,boolean) TO authenticated;

-- Substitui a política ampla de documento por autorização por chave e ação.
DROP POLICY IF EXISTS vortex_store_documents_store_isolation ON public.vortex_store_documents;
DROP POLICY IF EXISTS vortex_store_documents_permission_select ON public.vortex_store_documents;
DROP POLICY IF EXISTS vortex_store_documents_permission_insert ON public.vortex_store_documents;
DROP POLICY IF EXISTS vortex_store_documents_permission_update ON public.vortex_store_documents;
DROP POLICY IF EXISTS vortex_store_documents_permission_delete ON public.vortex_store_documents;

CREATE POLICY vortex_store_documents_permission_select
ON public.vortex_store_documents FOR SELECT TO authenticated
USING (public.vortex_user_can_access_document(store_id,document_key,false));

CREATE POLICY vortex_store_documents_permission_insert
ON public.vortex_store_documents FOR INSERT TO authenticated
WITH CHECK (public.vortex_user_can_access_document(store_id,document_key,true));

CREATE POLICY vortex_store_documents_permission_update
ON public.vortex_store_documents FOR UPDATE TO authenticated
USING (public.vortex_user_can_access_document(store_id,document_key,true))
WITH CHECK (public.vortex_user_can_access_document(store_id,document_key,true));

CREATE POLICY vortex_store_documents_permission_delete
ON public.vortex_store_documents FOR DELETE TO authenticated
USING (public.vortex_user_can_access_document(store_id,document_key,true));

-- Policies operacionais: cada comando tem permissão própria; nega por padrão.
DO $policies$
DECLARE
  v_table text;
  v_select text;
  v_insert text;
  v_update text;
  v_delete text;
  v_extra_select text := '';
BEGIN
  FOR v_table,v_select,v_insert,v_update,v_delete IN
    SELECT * FROM (VALUES
      ('cash_shifts',
       'cash.view','cash.open','cash.move OR public.vortex_user_has_permission(store_id,''cash.close'')','false'),
      ('vortex_financial',
       'finance.view','finance.create','finance.edit','finance.delete'),
      ('vortex_integrations',
       'integrations.manage','integrations.manage','integrations.manage','integrations.manage'),
      ('vortex_kds',
       'kds.view','kds.update_status','kds.update_status OR public.vortex_user_has_permission(store_id,''kds.cancel'')','false'),
      ('vortex_kds_orders',
       'kds.view OR public.vortex_user_has_permission(store_id,''delivery.view'') OR public.vortex_user_has_permission(store_id,''pdv.history'') OR public.vortex_user_has_permission(store_id,''tables.view'')',
       'pdv.sell OR public.vortex_user_has_permission(store_id,''tables.open'') OR public.vortex_user_has_permission(store_id,''delivery.manage'')',
       'kds.update_status OR public.vortex_user_has_permission(store_id,''delivery.manage'') OR public.vortex_user_has_permission(store_id,''tables.close'')',
       'pdv.cancel OR public.vortex_user_has_permission(store_id,''kds.cancel'') OR public.vortex_user_has_permission(store_id,''delivery.manual_finish'')'),
      ('vortex_sales',
       'pdv.history','pdv.sell','pdv.sell OR public.vortex_user_has_permission(store_id,''pdv.cancel'')','pdv.cancel'),
      ('vortex_sales_history',
       'pdv.history OR public.vortex_user_has_permission(store_id,''finance.view'') OR public.vortex_user_has_permission(store_id,''reports.financial'')',
       'pdv.sell','pdv.cancel OR public.vortex_user_has_permission(store_id,''finance.edit'')','pdv.cancel OR public.vortex_user_has_permission(store_id,''finance.delete'')'),
      ('vortex_stock_items',
       'stock.view OR public.vortex_user_has_permission(store_id,''stock.manage_items'') OR public.vortex_user_has_permission(store_id,''stock.adjust'')',
       'stock.manage_items','stock.manage_items OR public.vortex_user_has_permission(store_id,''stock.adjust'')','stock.manage_items'),
      ('vortex_stock_movements',
       'stock.view OR public.vortex_user_has_permission(store_id,''stock.view_costs'')',
       'stock.adjust OR public.vortex_user_has_permission(store_id,''stock.consume'')',
       'false','false'),
      ('vortex_store_settings',
       'settings.view OR public.vortex_user_has_permission(store_id,''settings.manage'')',
       'settings.manage','settings.manage','false'),
      ('vortex_public_delivery_settings',
       'delivery.view OR public.vortex_user_has_permission(store_id,''delivery.manage'')',
       'delivery.manage','delivery.manage','delivery.manage'),
      ('vortex_public_store_settings',
       'tables.view OR public.vortex_user_has_permission(store_id,''tables.manage_qr'')',
       'tables.manage_qr','tables.manage_qr','tables.manage_qr'),
      ('vortex_public_table_requests',
       'tables.attend_requests','false','tables.attend_requests','false')
    ) AS policy_map(table_name,select_expr,insert_expr,update_expr,delete_expr)
  LOOP
    IF to_regclass('public.'||v_table) IS NULL THEN
      RAISE EXCEPTION 'Tabela operacional esperada não existe: %',v_table;
    END IF;

    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY',v_table);

    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I',v_table||'_store_isolation',v_table);
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I',v_table||'_permission_select',v_table);
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I',v_table||'_permission_insert',v_table);
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I',v_table||'_permission_update',v_table);
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I',v_table||'_permission_delete',v_table);

    IF v_table='vortex_kds_orders' THEN
      v_extra_select := ' AND (NOT EXISTS (
        SELECT 1 FROM public.vortex_store_members m
        WHERE m.store_id='||quote_literal('')||'::uuid
      ))';
      -- O filtro real de entregador é aplicado sem depender de dados do cliente:
      -- perfil delivery só lê pedidos cujo courier_member_id seja o próprio usuário.
      v_select := '('||v_select||') AND (
        NOT EXISTS (SELECT 1 FROM public.vortex_store_members m
          WHERE m.store_id = vortex_kds_orders.store_id
            AND m.user_id = auth.uid()
            AND m.status = ''active''
            AND m.profile_key = ''delivery'')
        OR courier_member_id = auth.uid()
      )';
    END IF;

    EXECUTE format(
      'CREATE POLICY %I ON public.%I FOR SELECT TO authenticated USING (public.vortex_user_has_permission(store_id,%L) OR (%s))',
      v_table||'_permission_select',v_table,'__never__',v_select
    );
    -- O ramo __never__ sempre retorna falso; expressões de permissão são avaliadas
    -- por helper para que cada ação tenha a chave individual correta.
    EXECUTE format('DROP POLICY %I ON public.%I',v_table||'_permission_select',v_table);
    EXECUTE format(
      'CREATE POLICY %I ON public.%I FOR SELECT TO authenticated USING (%s)',
      v_table||'_permission_select',v_table,
      replace(v_select,' OR ',' OR public.vortex_user_has_permission(store_id,''')
    );
    -- As expressões já contêm chamadas explícitas; substituição textual não é
    -- segura para compor SQL. A política é montada abaixo por expressão validada.
    EXECUTE format('DROP POLICY %I ON public.%I',v_table||'_permission_select',v_table);

    EXECUTE format(
      'CREATE POLICY %I ON public.%I FOR SELECT TO authenticated USING (%s)',
      v_table||'_permission_select',v_table,
      CASE v_table
        WHEN 'cash_shifts' THEN 'public.vortex_user_has_permission(store_id,''cash.view'')'
        WHEN 'vortex_financial' THEN 'public.vortex_user_has_permission(store_id,''finance.view'')'
        WHEN 'vortex_integrations' THEN 'public.vortex_user_has_permission(store_id,''integrations.manage'')'
        WHEN 'vortex_kds' THEN 'public.vortex_user_has_permission(store_id,''kds.view'')'
        WHEN 'vortex_kds_orders' THEN '('||v_select||')'
        WHEN 'vortex_sales' THEN 'public.vortex_user_has_permission(store_id,''pdv.history'')'
        WHEN 'vortex_sales_history' THEN 'public.vortex_user_has_permission(store_id,''pdv.history'') OR public.vortex_user_has_permission(store_id,''finance.view'') OR public.vortex_user_has_permission(store_id,''reports.financial'')'
        WHEN 'vortex_stock_items' THEN 'public.vortex_user_has_permission(store_id,''stock.view'') OR public.vortex_user_has_permission(store_id,''stock.manage_items'') OR public.vortex_user_has_permission(store_id,''stock.adjust'')'
        WHEN 'vortex_stock_movements' THEN 'public.vortex_user_has_permission(store_id,''stock.view'') OR public.vortex_user_has_permission(store_id,''stock.view_costs'')'
        WHEN 'vortex_store_settings' THEN 'public.vortex_user_has_permission(store_id,''settings.view'') OR public.vortex_user_has_permission(store_id,''settings.manage'')'
        WHEN 'vortex_public_delivery_settings' THEN 'public.vortex_user_has_permission(store_id,''delivery.view'') OR public.vortex_user_has_permission(store_id,''delivery.manage'')'
        WHEN 'vortex_public_store_settings' THEN 'public.vortex_user_has_permission(store_id,''tables.view'') OR public.vortex_user_has_permission(store_id,''tables.manage_qr'')'
        WHEN 'vortex_public_table_requests' THEN 'public.vortex_user_has_permission(store_id,''tables.attend_requests'')'
      END
    );

    EXECUTE format(
      'CREATE POLICY %I ON public.%I FOR INSERT TO authenticated WITH CHECK (%s)',
      v_table||'_permission_insert',v_table,
      CASE v_table
        WHEN 'cash_shifts' THEN 'public.vortex_user_has_permission(store_id,''cash.open'')'
        WHEN 'vortex_financial' THEN 'public.vortex_user_has_permission(store_id,''finance.create'')'
        WHEN 'vortex_integrations' THEN 'public.vortex_user_has_permission(store_id,''integrations.manage'')'
        WHEN 'vortex_kds' THEN 'public.vortex_user_has_permission(store_id,''kds.update_status'')'
        WHEN 'vortex_kds_orders' THEN 'public.vortex_user_has_permission(store_id,''pdv.sell'') OR public.vortex_user_has_permission(store_id,''tables.open'') OR public.vortex_user_has_permission(store_id,''delivery.manage'')'
        WHEN 'vortex_sales' THEN 'public.vortex_user_has_permission(store_id,''pdv.sell'')'
        WHEN 'vortex_sales_history' THEN 'public.vortex_user_has_permission(store_id,''pdv.sell'')'
        WHEN 'vortex_stock_items' THEN 'public.vortex_user_has_permission(store_id,''stock.manage_items'')'
        WHEN 'vortex_stock_movements' THEN 'public.vortex_user_has_permission(store_id,''stock.adjust'') OR public.vortex_user_has_permission(store_id,''stock.consume'')'
        WHEN 'vortex_store_settings' THEN 'public.vortex_user_has_permission(store_id,''settings.manage'')'
        WHEN 'vortex_public_delivery_settings' THEN 'public.vortex_user_has_permission(store_id,''delivery.manage'')'
        WHEN 'vortex_public_store_settings' THEN 'public.vortex_user_has_permission(store_id,''tables.manage_qr'')'
        WHEN 'vortex_public_table_requests' THEN 'false'
      END
    );

    EXECUTE format(
      'CREATE POLICY %I ON public.%I FOR UPDATE TO authenticated USING (%s) WITH CHECK (%s)',
      v_table||'_permission_update',v_table,
      CASE v_table
        WHEN 'cash_shifts' THEN 'public.vortex_user_has_permission(store_id,''cash.move'') OR public.vortex_user_has_permission(store_id,''cash.close'')'
        WHEN 'vortex_financial' THEN 'public.vortex_user_has_permission(store_id,''finance.edit'')'
        WHEN 'vortex_integrations' THEN 'public.vortex_user_has_permission(store_id,''integrations.manage'')'
        WHEN 'vortex_kds' THEN 'public.vortex_user_has_permission(store_id,''kds.update_status'') OR public.vortex_user_has_permission(store_id,''kds.cancel'')'
        WHEN 'vortex_kds_orders' THEN 'public.vortex_user_has_permission(store_id,''kds.update_status'') OR public.vortex_user_has_permission(store_id,''delivery.manage'') OR public.vortex_user_has_permission(store_id,''tables.close'')'
        WHEN 'vortex_sales' THEN 'public.vortex_user_has_permission(store_id,''pdv.sell'') OR public.vortex_user_has_permission(store_id,''pdv.cancel'')'
        WHEN 'vortex_sales_history' THEN 'public.vortex_user_has_permission(store_id,''pdv.cancel'') OR public.vortex_user_has_permission(store_id,''finance.edit'')'
        WHEN 'vortex_stock_items' THEN 'public.vortex_user_has_permission(store_id,''stock.manage_items'') OR public.vortex_user_has_permission(store_id,''stock.adjust'')'
        WHEN 'vortex_stock_movements' THEN 'false'
        WHEN 'vortex_store_settings' THEN 'public.vortex_user_has_permission(store_id,''settings.manage'')'
        WHEN 'vortex_public_delivery_settings' THEN 'public.vortex_user_has_permission(store_id,''delivery.manage'')'
        WHEN 'vortex_public_store_settings' THEN 'public.vortex_user_has_permission(store_id,''tables.manage_qr'')'
        WHEN 'vortex_public_table_requests' THEN 'public.vortex_user_has_permission(store_id,''tables.attend_requests'')'
      END,
      CASE v_table
        WHEN 'cash_shifts' THEN 'public.vortex_user_has_permission(store_id,''cash.move'') OR public.vortex_user_has_permission(store_id,''cash.close'')'
        WHEN 'vortex_financial' THEN 'public.vortex_user_has_permission(store_id,''finance.edit'')'
        WHEN 'vortex_integrations' THEN 'public.vortex_user_has_permission(store_id,''integrations.manage'')'
        WHEN 'vortex_kds' THEN 'public.vortex_user_has_permission(store_id,''kds.update_status'') OR public.vortex_user_has_permission(store_id,''kds.cancel'')'
        WHEN 'vortex_kds_orders' THEN 'public.vortex_user_has_permission(store_id,''kds.update_status'') OR public.vortex_user_has_permission(store_id,''delivery.manage'') OR public.vortex_user_has_permission(store_id,''tables.close'')'
        WHEN 'vortex_sales' THEN 'public.vortex_user_has_permission(store_id,''pdv.sell'') OR public.vortex_user_has_permission(store_id,''pdv.cancel'')'
        WHEN 'vortex_sales_history' THEN 'public.vortex_user_has_permission(store_id,''pdv.cancel'') OR public.vortex_user_has_permission(store_id,''finance.edit'')'
        WHEN 'vortex_stock_items' THEN 'public.vortex_user_has_permission(store_id,''stock.manage_items'') OR public.vortex_user_has_permission(store_id,''stock.adjust'')'
        WHEN 'vortex_stock_movements' THEN 'false'
        WHEN 'vortex_store_settings' THEN 'public.vortex_user_has_permission(store_id,''settings.manage'')'
        WHEN 'vortex_public_delivery_settings' THEN 'public.vortex_user_has_permission(store_id,''delivery.manage'')'
        WHEN 'vortex_public_store_settings' THEN 'public.vortex_user_has_permission(store_id,''tables.manage_qr'')'
        WHEN 'vortex_public_table_requests' THEN 'public.vortex_user_has_permission(store_id,''tables.attend_requests'')'
      END
    );

    EXECUTE format(
      'CREATE POLICY %I ON public.%I FOR DELETE TO authenticated USING (%s)',
      v_table||'_permission_delete',v_table,
      CASE v_table
        WHEN 'cash_shifts' THEN 'false'
        WHEN 'vortex_financial' THEN 'public.vortex_user_has_permission(store_id,''finance.delete'')'
        WHEN 'vortex_integrations' THEN 'public.vortex_user_has_permission(store_id,''integrations.manage'')'
        WHEN 'vortex_kds' THEN 'false'
        WHEN 'vortex_kds_orders' THEN 'public.vortex_user_has_permission(store_id,''pdv.cancel'') OR public.vortex_user_has_permission(store_id,''kds.cancel'') OR public.vortex_user_has_permission(store_id,''delivery.manual_finish'')'
        WHEN 'vortex_sales' THEN 'public.vortex_user_has_permission(store_id,''pdv.cancel'')'
        WHEN 'vortex_sales_history' THEN 'public.vortex_user_has_permission(store_id,''pdv.cancel'') OR public.vortex_user_has_permission(store_id,''finance.delete'')'
        WHEN 'vortex_stock_items' THEN 'public.vortex_user_has_permission(store_id,''stock.manage_items'')'
        WHEN 'vortex_stock_movements' THEN 'false'
        WHEN 'vortex_store_settings' THEN 'false'
        WHEN 'vortex_public_delivery_settings' THEN 'public.vortex_user_has_permission(store_id,''delivery.manage'')'
        WHEN 'vortex_public_store_settings' THEN 'public.vortex_user_has_permission(store_id,''tables.manage_qr'')'
        WHEN 'vortex_public_table_requests' THEN 'false'
      END
    );
  END LOOP;
END;
$policies$;

-- A tabela de assinaturas é visível apenas para quem tem permissão de assinatura.
DROP POLICY IF EXISTS vortex_subscriptions_member_select ON public.vortex_subscriptions;
DROP POLICY IF EXISTS vortex_subscriptions_permission_select ON public.vortex_subscriptions;
CREATE POLICY vortex_subscriptions_permission_select
ON public.vortex_subscriptions FOR SELECT TO authenticated
USING (public.vortex_user_has_permission(store_id,'subscription.view')
  OR EXISTS (SELECT 1 FROM public.vortex_store_members m
    WHERE m.store_id=vortex_subscriptions.store_id
      AND m.user_id=auth.uid() AND m.role='owner' AND m.status='active'));

COMMIT;
