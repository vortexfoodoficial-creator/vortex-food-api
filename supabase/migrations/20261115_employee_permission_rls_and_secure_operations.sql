-- VORTEX FOOD: aplicação das permissões individuais no banco e nas operações críticas.
-- Aplicar somente depois de 20261114_employee_permissions_foundation.sql.
-- Esta migração não apaga registros; substitui o acesso genérico por políticas por ação.

BEGIN;

-- 1) Campos de auditoria e vínculo opcional entre pedido e entregador com conta.
ALTER TABLE public.cash_shifts
  ADD COLUMN IF NOT EXISTS opened_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS closed_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS updated_by uuid REFERENCES auth.users(id) ON DELETE SET NULL;

ALTER TABLE public.vortex_sales_history
  ADD COLUMN IF NOT EXISTS created_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS updated_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS cancelled_by uuid REFERENCES auth.users(id) ON DELETE SET NULL;

ALTER TABLE public.vortex_sales
  ADD COLUMN IF NOT EXISTS created_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS updated_by uuid REFERENCES auth.users(id) ON DELETE SET NULL;

ALTER TABLE public.vortex_kds
  ADD COLUMN IF NOT EXISTS created_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS updated_by uuid REFERENCES auth.users(id) ON DELETE SET NULL;

ALTER TABLE public.vortex_kds_orders
  ADD COLUMN IF NOT EXISTS created_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS updated_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS courier_member_id uuid REFERENCES auth.users(id) ON DELETE SET NULL;

ALTER TABLE public.vortex_financial
  ADD COLUMN IF NOT EXISTS created_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS updated_by uuid REFERENCES auth.users(id) ON DELETE SET NULL;

ALTER TABLE public.vortex_stock_items
  ADD COLUMN IF NOT EXISTS created_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS updated_by uuid REFERENCES auth.users(id) ON DELETE SET NULL;

ALTER TABLE public.vortex_stock_movements
  ADD COLUMN IF NOT EXISTS created_by uuid REFERENCES auth.users(id) ON DELETE SET NULL;

ALTER TABLE public.vortex_store_documents
  ADD COLUMN IF NOT EXISTS updated_by uuid REFERENCES auth.users(id) ON DELETE SET NULL;

ALTER TABLE public.vortex_store_settings
  ADD COLUMN IF NOT EXISTS updated_by uuid REFERENCES auth.users(id) ON DELETE SET NULL;

ALTER TABLE public.vortex_integrations
  ADD COLUMN IF NOT EXISTS updated_by uuid REFERENCES auth.users(id) ON DELETE SET NULL;

ALTER TABLE public.vortex_public_table_requests
  ADD COLUMN IF NOT EXISTS handled_by uuid REFERENCES auth.users(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS vortex_kds_orders_courier_member_idx
  ON public.vortex_kds_orders(store_id,courier_member_id)
  WHERE courier_member_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS vortex_sales_history_created_by_idx
  ON public.vortex_sales_history(store_id,created_by);
CREATE INDEX IF NOT EXISTS vortex_kds_orders_created_by_idx
  ON public.vortex_kds_orders(store_id,created_by);

-- Trigger comum: o navegador não escolhe quem criou/alterou o registro.
CREATE OR REPLACE FUNCTION public.vortex_set_actor_audit_fields()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public, auth
AS $function$
DECLARE
  v_new jsonb;
  v_old jsonb;
  v_actor jsonb;
  v_display_name text;
BEGIN
  v_new := to_jsonb(NEW);
  v_actor := COALESCE(to_jsonb(auth.uid()),'null'::jsonb);

  IF TG_OP='UPDATE' THEN
    v_old := to_jsonb(OLD);
  END IF;

  IF TG_OP='INSERT' AND v_new ? 'created_by' THEN
    v_new := jsonb_set(v_new,'{created_by}',v_actor,true);
  END IF;
  IF v_new ? 'updated_by' THEN
    v_new := jsonb_set(v_new,'{updated_by}',v_actor,true);
  END IF;
  IF TG_OP='INSERT' AND v_new ? 'opened_by' THEN
    v_new := jsonb_set(v_new,'{opened_by}',v_actor,true);
  END IF;
  IF TG_OP='INSERT' AND v_new ? 'operator' AND auth.uid() IS NOT NULL THEN
    SELECT COALESCE(NULLIF(m.display_name,''),u.email,'Funcionário')
      INTO v_display_name
    FROM public.vortex_store_members AS m
    LEFT JOIN auth.users AS u ON u.id=m.user_id
    WHERE m.user_id=auth.uid() AND m.store_id=(v_new->>'store_id')::uuid AND m.status='active'
    LIMIT 1;
    IF v_display_name IS NOT NULL THEN
      v_new := jsonb_set(v_new,'{operator}',to_jsonb(v_display_name),true);
    END IF;
  END IF;
  IF TG_OP='UPDATE' AND v_new ? 'closed_by'
     AND v_new->>'status'='closed'
     AND COALESCE(v_old->>'status','')<>'closed' THEN
    v_new := jsonb_set(v_new,'{closed_by}',v_actor,true);
  END IF;
  IF TG_OP='UPDATE' AND v_new ? 'handled_by'
     AND v_new->>'status' IN ('attended','cancelled')
     AND COALESCE(v_old->>'status','')='pending' THEN
    v_new := jsonb_set(v_new,'{handled_by}',v_actor,true);
  END IF;

  NEW := jsonb_populate_record(NEW,v_new);
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS vortex_cash_shifts_actor_audit ON public.cash_shifts;
CREATE TRIGGER vortex_cash_shifts_actor_audit
BEFORE INSERT OR UPDATE ON public.cash_shifts
FOR EACH ROW EXECUTE FUNCTION public.vortex_set_actor_audit_fields();

DROP TRIGGER IF EXISTS vortex_sales_history_actor_audit ON public.vortex_sales_history;
CREATE TRIGGER vortex_sales_history_actor_audit
BEFORE INSERT OR UPDATE ON public.vortex_sales_history
FOR EACH ROW EXECUTE FUNCTION public.vortex_set_actor_audit_fields();

DROP TRIGGER IF EXISTS vortex_sales_actor_audit ON public.vortex_sales;
CREATE TRIGGER vortex_sales_actor_audit
BEFORE INSERT OR UPDATE ON public.vortex_sales
FOR EACH ROW EXECUTE FUNCTION public.vortex_set_actor_audit_fields();

DROP TRIGGER IF EXISTS vortex_kds_actor_audit ON public.vortex_kds;
CREATE TRIGGER vortex_kds_actor_audit
BEFORE INSERT OR UPDATE ON public.vortex_kds
FOR EACH ROW EXECUTE FUNCTION public.vortex_set_actor_audit_fields();

DROP TRIGGER IF EXISTS vortex_kds_orders_actor_audit ON public.vortex_kds_orders;
CREATE TRIGGER vortex_kds_orders_actor_audit
BEFORE INSERT OR UPDATE ON public.vortex_kds_orders
FOR EACH ROW EXECUTE FUNCTION public.vortex_set_actor_audit_fields();

DROP TRIGGER IF EXISTS vortex_financial_actor_audit ON public.vortex_financial;
CREATE TRIGGER vortex_financial_actor_audit
BEFORE INSERT OR UPDATE ON public.vortex_financial
FOR EACH ROW EXECUTE FUNCTION public.vortex_set_actor_audit_fields();

DROP TRIGGER IF EXISTS vortex_stock_items_actor_audit ON public.vortex_stock_items;
CREATE TRIGGER vortex_stock_items_actor_audit
BEFORE INSERT OR UPDATE ON public.vortex_stock_items
FOR EACH ROW EXECUTE FUNCTION public.vortex_set_actor_audit_fields();

DROP TRIGGER IF EXISTS vortex_stock_movements_actor_audit ON public.vortex_stock_movements;
CREATE TRIGGER vortex_stock_movements_actor_audit
BEFORE INSERT ON public.vortex_stock_movements
FOR EACH ROW EXECUTE FUNCTION public.vortex_set_actor_audit_fields();

DROP TRIGGER IF EXISTS vortex_store_documents_actor_audit ON public.vortex_store_documents;
CREATE TRIGGER vortex_store_documents_actor_audit
BEFORE INSERT OR UPDATE ON public.vortex_store_documents
FOR EACH ROW EXECUTE FUNCTION public.vortex_set_actor_audit_fields();

DROP TRIGGER IF EXISTS vortex_store_settings_actor_audit ON public.vortex_store_settings;
CREATE TRIGGER vortex_store_settings_actor_audit
BEFORE INSERT OR UPDATE ON public.vortex_store_settings
FOR EACH ROW EXECUTE FUNCTION public.vortex_set_actor_audit_fields();

DROP TRIGGER IF EXISTS vortex_integrations_actor_audit ON public.vortex_integrations;
CREATE TRIGGER vortex_integrations_actor_audit
BEFORE INSERT OR UPDATE ON public.vortex_integrations
FOR EACH ROW EXECUTE FUNCTION public.vortex_set_actor_audit_fields();

DROP TRIGGER IF EXISTS vortex_public_table_requests_actor_audit ON public.vortex_public_table_requests;
CREATE TRIGGER vortex_public_table_requests_actor_audit
BEFORE UPDATE ON public.vortex_public_table_requests
FOR EACH ROW EXECUTE FUNCTION public.vortex_set_actor_audit_fields();

-- 2) Substitui as políticas genéricas de isolamento por permissões de ação.
DO $$
DECLARE
  t text;
  p record;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'cash_shifts','vortex_financial','vortex_integrations','vortex_kds',
    'vortex_kds_orders','vortex_sales','vortex_sales_history',
    'vortex_stock_items','vortex_stock_movements','vortex_store_settings',
    'vortex_store_documents','vortex_public_delivery_settings',
    'vortex_public_store_settings','vortex_public_table_requests'
  ]
  LOOP
    FOR p IN SELECT policyname FROM pg_policies
      WHERE schemaname='public' AND tablename=t
    LOOP
      EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I',p.policyname,t);
    END LOOP;
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY',t);
  END LOOP;
END;
$$;

-- Caixa: leitura, abertura, movimentações e fechamento são ações separadas.
CREATE POLICY cash_shifts_permission_select
ON public.cash_shifts FOR SELECT TO authenticated
USING (public.vortex_user_has_permission(store_id,'cash.view'));

CREATE POLICY cash_shifts_permission_insert
ON public.cash_shifts FOR INSERT TO authenticated
WITH CHECK (public.vortex_user_has_permission(store_id,'cash.open'));

REVOKE UPDATE, DELETE ON TABLE public.cash_shifts FROM authenticated;

-- Financeiro.
CREATE POLICY vortex_financial_permission_select
ON public.vortex_financial FOR SELECT TO authenticated
USING (
  public.vortex_user_has_permission(store_id,'finance.view')
  OR public.vortex_user_has_permission(store_id,'reports.financial')
);
CREATE POLICY vortex_financial_permission_insert
ON public.vortex_financial FOR INSERT TO authenticated
WITH CHECK (public.vortex_user_has_permission(store_id,'finance.create'));
CREATE POLICY vortex_financial_permission_update
ON public.vortex_financial FOR UPDATE TO authenticated
USING (public.vortex_user_has_permission(store_id,'finance.edit'))
WITH CHECK (public.vortex_user_has_permission(store_id,'finance.edit'));
CREATE POLICY vortex_financial_permission_delete
ON public.vortex_financial FOR DELETE TO authenticated
USING (public.vortex_user_has_permission(store_id,'finance.delete'));

-- Integrações: credenciais somente para perfis com acesso explícito.
CREATE POLICY vortex_integrations_permission_select
ON public.vortex_integrations FOR SELECT TO authenticated
USING (public.vortex_user_has_permission(store_id,'integrations.view'));
CREATE POLICY vortex_integrations_permission_insert
ON public.vortex_integrations FOR INSERT TO authenticated
WITH CHECK (public.vortex_user_has_permission(store_id,'integrations.manage'));
CREATE POLICY vortex_integrations_permission_update
ON public.vortex_integrations FOR UPDATE TO authenticated
USING (public.vortex_user_has_permission(store_id,'integrations.manage'))
WITH CHECK (public.vortex_user_has_permission(store_id,'integrations.manage'));
CREATE POLICY vortex_integrations_permission_delete
ON public.vortex_integrations FOR DELETE TO authenticated
USING (public.vortex_user_has_permission(store_id,'integrations.manage'));

-- KDS legado.
CREATE POLICY vortex_kds_permission_select
ON public.vortex_kds FOR SELECT TO authenticated
USING (public.vortex_user_has_permission(store_id,'kds.view'));
CREATE POLICY vortex_kds_permission_insert
ON public.vortex_kds FOR INSERT TO authenticated
WITH CHECK (public.vortex_user_has_permission(store_id,'kds.update_status'));
CREATE POLICY vortex_kds_permission_update
ON public.vortex_kds FOR UPDATE TO authenticated
USING (public.vortex_user_has_permission(store_id,'kds.update_status'))
WITH CHECK (public.vortex_user_has_permission(store_id,'kds.update_status'));
CREATE POLICY vortex_kds_permission_delete
ON public.vortex_kds FOR DELETE TO authenticated
USING (public.vortex_user_has_permission(store_id,'kds.cancel'));

-- Pedidos: leitura por módulo, gravação por fluxo; mudanças de status/courier passam por RPC.
CREATE POLICY vortex_kds_orders_permission_select
ON public.vortex_kds_orders FOR SELECT TO authenticated
USING (
  public.vortex_user_has_permission(store_id,'kds.view')
  OR public.vortex_user_has_permission(store_id,'tables.view')
  OR public.vortex_user_has_permission(store_id,'pdv.history')
  OR public.vortex_user_has_permission(store_id,'delivery.manage')
  OR (
    public.vortex_user_has_permission(store_id,'delivery.view')
    AND courier_member_id=auth.uid()
  )
  OR (
    public.vortex_user_has_permission(store_id,'pdv.view')
    AND created_by=auth.uid()
  )
);
CREATE POLICY vortex_kds_orders_permission_insert
ON public.vortex_kds_orders FOR INSERT TO authenticated
WITH CHECK (
  public.vortex_user_has_permission(store_id,'pdv.sell')
  OR public.vortex_user_has_permission(store_id,'tables.open')
  OR public.vortex_user_has_permission(store_id,'delivery.manage')
);
REVOKE UPDATE, DELETE ON TABLE public.vortex_kds_orders FROM authenticated;

-- Vendas: funcionário consulta os próprios registros; relatórios e gestão têm leitura ampla.
CREATE POLICY vortex_sales_permission_select
ON public.vortex_sales FOR SELECT TO authenticated
USING (
  public.vortex_user_has_permission(store_id,'pdv.history')
  OR public.vortex_user_has_permission(store_id,'reports.view')
  OR public.vortex_user_has_permission(store_id,'finance.view')
  OR (public.vortex_user_has_permission(store_id,'pdv.view') AND created_by=auth.uid())
);
CREATE POLICY vortex_sales_permission_insert
ON public.vortex_sales FOR INSERT TO authenticated
WITH CHECK (public.vortex_user_has_permission(store_id,'pdv.sell'));
REVOKE UPDATE, DELETE ON TABLE public.vortex_sales FROM authenticated;

CREATE POLICY vortex_sales_history_permission_select
ON public.vortex_sales_history FOR SELECT TO authenticated
USING (
  public.vortex_user_has_permission(store_id,'pdv.history')
  OR public.vortex_user_has_permission(store_id,'reports.view')
  OR public.vortex_user_has_permission(store_id,'finance.view')
  OR (public.vortex_user_has_permission(store_id,'cash.view') AND created_by=auth.uid())
  OR (public.vortex_user_has_permission(store_id,'pdv.view') AND created_by=auth.uid())
);
CREATE POLICY vortex_sales_history_permission_insert
ON public.vortex_sales_history FOR INSERT TO authenticated
WITH CHECK (
  public.vortex_user_has_permission(store_id,'pdv.sell')
  OR public.vortex_user_has_permission(store_id,'tables.open')
  OR public.vortex_user_has_permission(store_id,'delivery.manage')
);
REVOKE UPDATE, DELETE ON TABLE public.vortex_sales_history FROM authenticated;

-- Estoque: ajustes e cadastro são diferentes de consulta.
CREATE POLICY vortex_stock_items_permission_select
ON public.vortex_stock_items FOR SELECT TO authenticated
USING (public.vortex_user_has_permission(store_id,'stock.view'));
CREATE POLICY vortex_stock_items_permission_insert
ON public.vortex_stock_items FOR INSERT TO authenticated
WITH CHECK (public.vortex_user_has_permission(store_id,'stock.manage_items'));
CREATE POLICY vortex_stock_items_permission_update
ON public.vortex_stock_items FOR UPDATE TO authenticated
USING (
  public.vortex_user_has_permission(store_id,'stock.manage_items')
  OR public.vortex_user_has_permission(store_id,'stock.adjust')
)
WITH CHECK (
  public.vortex_user_has_permission(store_id,'stock.manage_items')
  OR public.vortex_user_has_permission(store_id,'stock.adjust')
);
CREATE POLICY vortex_stock_items_permission_delete
ON public.vortex_stock_items FOR DELETE TO authenticated
USING (public.vortex_user_has_permission(store_id,'stock.manage_items'));

CREATE POLICY vortex_stock_movements_permission_select
ON public.vortex_stock_movements FOR SELECT TO authenticated
USING (public.vortex_user_has_permission(store_id,'stock.view'));
REVOKE INSERT, UPDATE, DELETE ON TABLE public.vortex_stock_movements FROM authenticated;

-- Configurações do estabelecimento.
CREATE POLICY vortex_store_settings_permission_select
ON public.vortex_store_settings FOR SELECT TO authenticated
USING (public.vortex_user_has_permission(store_id,'settings.view'));
CREATE POLICY vortex_store_settings_permission_insert
ON public.vortex_store_settings FOR INSERT TO authenticated
WITH CHECK (public.vortex_user_has_permission(store_id,'settings.manage'));
CREATE POLICY vortex_store_settings_permission_update
ON public.vortex_store_settings FOR UPDATE TO authenticated
USING (public.vortex_user_has_permission(store_id,'settings.manage'))
WITH CHECK (public.vortex_user_has_permission(store_id,'settings.manage'));
CREATE POLICY vortex_store_settings_permission_delete
ON public.vortex_store_settings FOR DELETE TO authenticated
USING (public.vortex_user_has_permission(store_id,'settings.manage'));

-- Documentos JSON: autorização por chave; chaves desconhecidas são negadas.
CREATE POLICY vortex_store_documents_permission_select
ON public.vortex_store_documents FOR SELECT TO authenticated
USING (
  CASE document_key
    WHEN 'staff' THEN public.vortex_user_has_permission(store_id,'team.view')
    WHEN 'couriers' THEN (
      public.vortex_user_has_permission(store_id,'delivery.manage')
      OR public.vortex_user_has_permission(store_id,'delivery.manage_couriers')
    )
    WHEN 'catalog' THEN (
      public.vortex_user_has_permission(store_id,'catalog.view')
      OR public.vortex_user_has_permission(store_id,'delivery.manage')
    )
    WHEN 'coupons' THEN public.vortex_user_has_permission(store_id,'coupons.manage')
    WHEN 'loyalty' THEN public.vortex_user_has_permission(store_id,'loyalty.manage')
    WHEN 'customers' THEN public.vortex_user_has_permission(store_id,'crm.view')
    WHEN 'table_settings' THEN public.vortex_user_has_permission(store_id,'tables.view')
    WHEN 'settings' THEN public.vortex_user_has_permission(store_id,'settings.view')
    WHEN 'recipes' THEN (
      public.vortex_user_has_permission(store_id,'recipes.view')
      OR public.vortex_user_has_permission(store_id,'reports.view')
    )
    WHEN 'purchases' THEN public.vortex_user_has_permission(store_id,'purchases.view')
    WHEN 'accounts' THEN public.vortex_user_has_permission(store_id,'accounts.view')
    WHEN 'printer' THEN public.vortex_user_has_permission(store_id,'printers.manage')
    ELSE false
  END
);
CREATE POLICY vortex_store_documents_permission_insert
ON public.vortex_store_documents FOR INSERT TO authenticated
WITH CHECK (
  CASE document_key
    WHEN 'staff' THEN public.vortex_user_has_permission(store_id,'team.manage')
    WHEN 'couriers' THEN (
      public.vortex_user_has_permission(store_id,'delivery.manage_couriers')
      OR public.vortex_user_has_permission(store_id,'team.manage')
    )
    WHEN 'catalog' THEN (
      public.vortex_user_has_permission(store_id,'catalog.manage_products')
      OR public.vortex_user_has_permission(store_id,'catalog.manage_prices')
      OR public.vortex_user_has_permission(store_id,'catalog.manage_categories')
    )
    WHEN 'coupons' THEN public.vortex_user_has_permission(store_id,'coupons.manage')
    WHEN 'loyalty' THEN public.vortex_user_has_permission(store_id,'loyalty.manage')
    WHEN 'customers' THEN public.vortex_user_has_permission(store_id,'crm.manage')
    WHEN 'table_settings' THEN public.vortex_user_has_permission(store_id,'tables.manage_qr')
    WHEN 'settings' THEN public.vortex_user_has_permission(store_id,'settings.manage')
    WHEN 'recipes' THEN public.vortex_user_has_permission(store_id,'recipes.manage')
    WHEN 'purchases' THEN public.vortex_user_has_permission(store_id,'purchases.manage')
    WHEN 'accounts' THEN public.vortex_user_has_permission(store_id,'accounts.manage')
    WHEN 'printer' THEN public.vortex_user_has_permission(store_id,'printers.manage')
    ELSE false
  END
);
CREATE POLICY vortex_store_documents_permission_update
ON public.vortex_store_documents FOR UPDATE TO authenticated
USING (
  CASE document_key
    WHEN 'staff' THEN public.vortex_user_has_permission(store_id,'team.manage')
    WHEN 'couriers' THEN (
      public.vortex_user_has_permission(store_id,'delivery.manage_couriers')
      OR public.vortex_user_has_permission(store_id,'team.manage')
    )
    WHEN 'catalog' THEN (
      public.vortex_user_has_permission(store_id,'catalog.manage_products')
      OR public.vortex_user_has_permission(store_id,'catalog.manage_prices')
      OR public.vortex_user_has_permission(store_id,'catalog.manage_categories')
    )
    WHEN 'coupons' THEN public.vortex_user_has_permission(store_id,'coupons.manage')
    WHEN 'loyalty' THEN public.vortex_user_has_permission(store_id,'loyalty.manage')
    WHEN 'customers' THEN public.vortex_user_has_permission(store_id,'crm.manage')
    WHEN 'table_settings' THEN public.vortex_user_has_permission(store_id,'tables.manage_qr')
    WHEN 'settings' THEN public.vortex_user_has_permission(store_id,'settings.manage')
    WHEN 'recipes' THEN public.vortex_user_has_permission(store_id,'recipes.manage')
    WHEN 'purchases' THEN public.vortex_user_has_permission(store_id,'purchases.manage')
    WHEN 'accounts' THEN public.vortex_user_has_permission(store_id,'accounts.manage')
    WHEN 'printer' THEN public.vortex_user_has_permission(store_id,'printers.manage')
    ELSE false
  END
)
WITH CHECK (
  CASE document_key
    WHEN 'staff' THEN public.vortex_user_has_permission(store_id,'team.manage')
    WHEN 'couriers' THEN (
      public.vortex_user_has_permission(store_id,'delivery.manage_couriers')
      OR public.vortex_user_has_permission(store_id,'team.manage')
    )
    WHEN 'catalog' THEN (
      public.vortex_user_has_permission(store_id,'catalog.manage_products')
      OR public.vortex_user_has_permission(store_id,'catalog.manage_prices')
      OR public.vortex_user_has_permission(store_id,'catalog.manage_categories')
    )
    WHEN 'coupons' THEN public.vortex_user_has_permission(store_id,'coupons.manage')
    WHEN 'loyalty' THEN public.vortex_user_has_permission(store_id,'loyalty.manage')
    WHEN 'customers' THEN public.vortex_user_has_permission(store_id,'crm.manage')
    WHEN 'table_settings' THEN public.vortex_user_has_permission(store_id,'tables.manage_qr')
    WHEN 'settings' THEN public.vortex_user_has_permission(store_id,'settings.manage')
    WHEN 'recipes' THEN public.vortex_user_has_permission(store_id,'recipes.manage')
    WHEN 'purchases' THEN public.vortex_user_has_permission(store_id,'purchases.manage')
    WHEN 'accounts' THEN public.vortex_user_has_permission(store_id,'accounts.manage')
    WHEN 'printer' THEN public.vortex_user_has_permission(store_id,'printers.manage')
    ELSE false
  END
);
CREATE POLICY vortex_store_documents_permission_delete
ON public.vortex_store_documents FOR DELETE TO authenticated
USING (
  CASE document_key
    WHEN 'staff' THEN public.vortex_user_has_permission(store_id,'team.manage')
    WHEN 'couriers' THEN (
      public.vortex_user_has_permission(store_id,'delivery.manage_couriers')
      OR public.vortex_user_has_permission(store_id,'team.manage')
    )
    WHEN 'catalog' THEN (
      public.vortex_user_has_permission(store_id,'catalog.manage_products')
      OR public.vortex_user_has_permission(store_id,'catalog.manage_prices')
      OR public.vortex_user_has_permission(store_id,'catalog.manage_categories')
    )
    WHEN 'coupons' THEN public.vortex_user_has_permission(store_id,'coupons.manage')
    WHEN 'loyalty' THEN public.vortex_user_has_permission(store_id,'loyalty.manage')
    WHEN 'customers' THEN public.vortex_user_has_permission(store_id,'crm.manage')
    WHEN 'table_settings' THEN public.vortex_user_has_permission(store_id,'tables.manage_qr')
    WHEN 'settings' THEN public.vortex_user_has_permission(store_id,'settings.manage')
    WHEN 'recipes' THEN public.vortex_user_has_permission(store_id,'recipes.manage')
    WHEN 'purchases' THEN public.vortex_user_has_permission(store_id,'purchases.manage')
    WHEN 'accounts' THEN public.vortex_user_has_permission(store_id,'accounts.manage')
    WHEN 'printer' THEN public.vortex_user_has_permission(store_id,'printers.manage')
    ELSE false
  END
);

-- QR e delivery: leitura administrativa separada; gravação somente por RPC.
CREATE POLICY vortex_public_store_settings_permission_select
ON public.vortex_public_store_settings FOR SELECT TO authenticated
USING (public.vortex_user_has_permission(store_id,'tables.view'));
REVOKE INSERT, UPDATE, DELETE ON TABLE public.vortex_public_store_settings FROM authenticated;

CREATE POLICY vortex_public_delivery_settings_permission_select
ON public.vortex_public_delivery_settings FOR SELECT TO authenticated
USING (public.vortex_user_has_permission(store_id,'delivery.view'));
REVOKE INSERT, UPDATE, DELETE ON TABLE public.vortex_public_delivery_settings FROM authenticated;

CREATE POLICY vortex_public_table_requests_permission_select
ON public.vortex_public_table_requests FOR SELECT TO authenticated
USING (public.vortex_user_has_permission(store_id,'tables.attend_requests'));
CREATE POLICY vortex_public_table_requests_permission_update
ON public.vortex_public_table_requests FOR UPDATE TO authenticated
USING (public.vortex_user_has_permission(store_id,'tables.attend_requests'))
WITH CHECK (public.vortex_user_has_permission(store_id,'tables.attend_requests'));
REVOKE INSERT, DELETE ON TABLE public.vortex_public_table_requests FROM authenticated;

-- Assinatura e dados raiz: leitura limitada, sem escrita direta por funcionários.
DO $ DECLARE p record; BEGIN
  FOR p IN SELECT policyname FROM pg_policies WHERE schemaname='public' AND tablename='vortex_subscriptions'
  LOOP EXECUTE format('DROP POLICY IF EXISTS %I ON public.vortex_subscriptions',p.policyname); END LOOP;
  FOR p IN SELECT policyname FROM pg_policies WHERE schemaname='public' AND tablename='vortex_stores'
  LOOP EXECUTE format('DROP POLICY IF EXISTS %I ON public.vortex_stores',p.policyname); END LOOP;
END; $;
CREATE POLICY vortex_subscriptions_permission_select
ON public.vortex_subscriptions FOR SELECT TO authenticated
USING (public.vortex_user_has_permission(store_id,'subscription.view'));

CREATE POLICY vortex_stores_active_member_select
ON public.vortex_stores FOR SELECT TO authenticated
USING (public.vortex_user_has_store_access(id));

-- 3) RPCs protegidas para operações que não podem ser autorizadas só pela interface.
CREATE OR REPLACE FUNCTION public.rpc_update_kds_order_status(
  p_store_id uuid,
  p_order_id text,
  p_status text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $function$
DECLARE
  v_origin text;
BEGIN
  IF auth.uid() IS NULL OR NOT public.vortex_user_has_store_access(p_store_id) THEN
    RAISE EXCEPTION 'Acesso não autorizado.';
  END IF;

  IF p_status NOT IN ('preparing','ready','finished') THEN
    RAISE EXCEPTION 'Etapa de pedido inválida.';
  END IF;

  SELECT origin INTO v_origin
  FROM public.vortex_kds_orders
  WHERE store_id=p_store_id AND id=p_order_id
  FOR UPDATE;

  IF NOT FOUND THEN RAISE EXCEPTION 'Pedido não encontrado nesta loja.'; END IF;

  IF p_status='finished' AND COALESCE(v_origin,'') ILIKE '%Mesa%' THEN
    IF NOT public.vortex_user_has_permission(p_store_id,'tables.close') THEN
      RAISE EXCEPTION 'Seu perfil não pode fechar esta comanda.';
    END IF;
  ELSIF NOT public.vortex_user_has_permission(p_store_id,'kds.update_status') THEN
    RAISE EXCEPTION 'Seu perfil não pode atualizar o preparo.';
  END IF;

  UPDATE public.vortex_kds_orders
  SET status=p_status, updated_at=now()
  WHERE store_id=p_store_id AND id=p_order_id;

  RETURN jsonb_build_object('success',true,'status',p_status);
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_update_kds_order_status(uuid,text,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_update_kds_order_status(uuid,text,text) TO authenticated;

CREATE OR REPLACE FUNCTION public.rpc_update_delivery_order(
  p_store_id uuid,
  p_order_id text,
  p_status text DEFAULT NULL,
  p_courier text DEFAULT NULL,
  p_update_courier boolean DEFAULT false,
  p_courier_member_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $function$
DECLARE
  v_origin text;
  v_current_status text;
BEGIN
  IF auth.uid() IS NULL OR NOT public.vortex_user_has_store_access(p_store_id) THEN
    RAISE EXCEPTION 'Acesso não autorizado.';
  END IF;

  SELECT origin,status INTO v_origin,v_current_status
  FROM public.vortex_kds_orders
  WHERE store_id=p_store_id AND id=p_order_id
  FOR UPDATE;

  IF NOT FOUND OR COALESCE(v_origin,'') NOT ILIKE '%Delivery%' THEN
    RAISE EXCEPTION 'Pedido de delivery não encontrado.';
  END IF;
  IF v_current_status IN ('finished','cancelled') THEN
    RAISE EXCEPTION 'Este pedido já foi encerrado.';
  END IF;
  IF p_status IS NULL AND NOT p_update_courier THEN
    RAISE EXCEPTION 'Nenhuma alteração foi solicitada.';
  END IF;

  IF p_status IS NOT NULL THEN
    IF p_status <> 'delivering' OR NOT public.vortex_user_has_permission(p_store_id,'delivery.dispatch') THEN
      RAISE EXCEPTION 'Seu perfil não pode despachar este pedido.';
    END IF;
  END IF;

  IF p_update_courier THEN
    IF NOT public.vortex_user_has_permission(p_store_id,'delivery.assign') THEN
      RAISE EXCEPTION 'Seu perfil não pode atribuir entregadores.';
    END IF;
    IF p_courier_member_id IS NOT NULL AND NOT EXISTS (
      SELECT 1 FROM public.vortex_store_members
      WHERE store_id=p_store_id AND user_id=p_courier_member_id
        AND status='active' AND profile_key='delivery'
    ) THEN
      RAISE EXCEPTION 'O entregador selecionado não possui uma conta ativa nesta loja.';
    END IF;
  END IF;

  UPDATE public.vortex_kds_orders
  SET status=COALESCE(p_status,status),
      courier=CASE WHEN p_update_courier THEN COALESCE(p_courier,'') ELSE courier END,
      courier_member_id=CASE WHEN p_update_courier THEN p_courier_member_id ELSE courier_member_id END,
      updated_at=now()
  WHERE store_id=p_store_id AND id=p_order_id;

  RETURN jsonb_build_object('success',true);
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_update_delivery_order(uuid,text,text,text,boolean,uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_update_delivery_order(uuid,text,text,text,boolean,uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.rpc_close_cash_shift(
  p_store_id uuid,
  p_shift_id text,
  p_closed_at timestamptz,
  p_counted_cash numeric,
  p_close_reason text DEFAULT ''
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $function$
DECLARE
  v_id text;
BEGIN
  IF auth.uid() IS NULL OR NOT public.vortex_user_has_permission(p_store_id,'cash.close') THEN
    RAISE EXCEPTION 'Seu perfil não pode fechar o caixa.';
  END IF;

  UPDATE public.cash_shifts
  SET status='closed',
      closed_at=COALESCE(p_closed_at,now()),
      counted_cash=GREATEST(0,COALESCE(p_counted_cash,0)),
      close_reason=left(COALESCE(p_close_reason,''),500)
  WHERE store_id=p_store_id AND id=p_shift_id AND status='open'
  RETURNING id INTO v_id;

  IF v_id IS NULL THEN
    RETURN jsonb_build_object('success',false,'message','Turno não encontrado ou já encerrado.');
  END IF;

  RETURN jsonb_build_object('success',true,'shift_id',v_id);
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_close_cash_shift(uuid,text,timestamptz,numeric,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_close_cash_shift(uuid,text,timestamptz,numeric,text) TO authenticated;

CREATE OR REPLACE FUNCTION public.rpc_record_cash_movement(
  p_store_id uuid,
  p_shift_id text,
  p_entry_id text,
  p_type text,
  p_movement_type text,
  p_description text,
  p_value numeric,
  p_date date
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $function$
DECLARE
  v_operator text;
  v_shift text;
  v_existing text;
BEGIN
  IF auth.uid() IS NULL OR NOT public.vortex_user_has_permission(p_store_id,'cash.move') THEN
    RAISE EXCEPTION 'Seu perfil não pode registrar movimentações de caixa.';
  END IF;
  IF p_type NOT IN ('income','expense') OR COALESCE(p_value,0)<=0
     OR COALESCE(p_entry_id,'') NOT LIKE 'cash_mov_%'
     OR COALESCE(p_movement_type,'') NOT IN ('SUPRIMENTO','SANGRIA','DESPESA','AJUSTE (+)','AJUSTE (-)') THEN
    RAISE EXCEPTION 'Lançamento de caixa inválido.';
  END IF;

  SELECT COALESCE(NULLIF(m.display_name,''),u.email,'Funcionário')
  INTO v_operator
  FROM public.vortex_store_members AS m
  LEFT JOIN auth.users AS u ON u.id=m.user_id
  WHERE m.store_id=p_store_id AND m.user_id=auth.uid() AND m.status='active';

  IF v_operator IS NULL THEN RAISE EXCEPTION 'Funcionário ativo não identificado.'; END IF;

  SELECT id INTO v_existing
  FROM public.vortex_financial
  WHERE store_id=p_store_id AND id=p_entry_id;
  IF v_existing IS NOT NULL THEN
    RETURN jsonb_build_object('success',true,'already_recorded',true);
  END IF;

  UPDATE public.cash_shifts
  SET movements=COALESCE(movements,'[]'::jsonb) || jsonb_build_array(
    jsonb_build_object(
      'time',to_char(now() AT TIME ZONE 'America/Sao_Paulo','HH24:MI'),
      'type',p_movement_type,
      'reason',left(COALESCE(p_description,''),300),
      'val',p_value,
      'operator',v_operator,
      'user_id',auth.uid()
    )
  )
  WHERE store_id=p_store_id AND id=p_shift_id AND status='open'
  RETURNING id INTO v_shift;

  IF v_shift IS NULL THEN
    RAISE EXCEPTION 'Não existe um turno aberto válido para esta movimentação.';
  END IF;

  INSERT INTO public.vortex_financial(store_id,id,type,description,value,date)
  VALUES (
    p_store_id,p_entry_id,p_type,left(COALESCE(p_description,''),300),
    p_value,COALESCE(p_date,current_date)
  );

  RETURN jsonb_build_object('success',true,'shift_id',v_shift);
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_record_cash_movement(uuid,text,text,text,text,text,numeric,date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_record_cash_movement(uuid,text,text,text,text,text,numeric,date) TO authenticated;

CREATE OR REPLACE FUNCTION public.rpc_get_cash_shift_sales(p_store_id uuid,p_shift_id text)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $function$
DECLARE
  v_opened_at timestamptz;
  v_result jsonb;
BEGIN
  IF auth.uid() IS NULL OR NOT public.vortex_user_has_permission(p_store_id,'cash.view') THEN
    RAISE EXCEPTION 'Seu perfil não pode consultar o movimento do caixa.';
  END IF;

  SELECT opened_at INTO v_opened_at
  FROM public.cash_shifts
  WHERE store_id=p_store_id AND id=p_shift_id;
  IF v_opened_at IS NULL THEN
    RAISE EXCEPTION 'Turno de caixa não encontrado.';
  END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id',s.id,
    'total',s.total,
    'pay_method',COALESCE(to_jsonb(s)->>'pay_method',to_jsonb(s)->>'paymethod',''),
    'status',s.status,
    'date',to_jsonb(s)->>'date',
    'time',to_jsonb(s)->>'time'
  )),'[]'::jsonb)
  INTO v_result
  FROM public.vortex_sales_history AS s
  WHERE s.store_id=p_store_id
    AND COALESCE(s.status,'')<>'cancelled'
    AND (
      (
        NULLIF(to_jsonb(s)->>'date','')::date
        + COALESCE(NULLIF(to_jsonb(s)->>'time','')::time,'00:00'::time)
      ) AT TIME ZONE 'America/Sao_Paulo'
    ) >= v_opened_at;

  RETURN v_result;
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_get_cash_shift_sales(uuid,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_get_cash_shift_sales(uuid,text) TO authenticated;


-- Grava ajustes manuais no histórico. Consumo automático possui RPC separada.
CREATE OR REPLACE FUNCTION public.rpc_save_stock_movements(p_store_id uuid,p_movements jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $function$
DECLARE
  v_item jsonb;
  v_item_id text;
  v_qty numeric;
  v_inserted integer := 0;
  v_count integer := 0;
BEGIN
  IF auth.uid() IS NULL OR NOT public.vortex_user_has_permission(p_store_id,'stock.adjust') THEN
    RAISE EXCEPTION 'Seu perfil não pode lançar ajustes de estoque.';
  END IF;
  IF jsonb_typeof(COALESCE(p_movements,'[]'::jsonb)) IS DISTINCT FROM 'array'
     OR jsonb_array_length(COALESCE(p_movements,'[]'::jsonb))>500 THEN
    RAISE EXCEPTION 'Lista de movimentações inválida.';
  END IF;

  FOR v_item IN SELECT value FROM jsonb_array_elements(COALESCE(p_movements,'[]'::jsonb))
  LOOP
    v_item_id := NULLIF(BTRIM(v_item->>'item_id'),'');
    v_qty := NULLIF(v_item->>'qty','')::numeric;
    IF v_item_id IS NULL OR v_qty IS NULL OR v_qty<=0
       OR COALESCE(v_item->>'type','')='consumption'
       OR NULLIF(BTRIM(v_item->>'idempotency_key'),'') IS NULL THEN
      RAISE EXCEPTION 'Uma movimentação contém dados inválidos.';
    END IF;
    IF NOT EXISTS (
      SELECT 1 FROM public.vortex_stock_items
      WHERE store_id=p_store_id AND id=v_item_id
    ) THEN
      RAISE EXCEPTION 'Um dos insumos não pertence a este estabelecimento.';
    END IF;

    INSERT INTO public.vortex_stock_movements(
      store_id,id,order_id,item_id,item_name,type,qty,reason,idempotency_key,created_at
    ) VALUES (
      p_store_id,
      COALESCE(NULLIF(v_item->>'id',''),'mov_'||replace(gen_random_uuid()::text,'-','')),
      NULLIF(v_item->>'order_id',''),
      v_item_id,
      left(COALESCE(v_item->>'item_name',''),160),
      left(COALESCE(v_item->>'type','adjustment'),40),
      v_qty,
      left(COALESCE(v_item->>'reason',''),300),
      left(v_item->>'idempotency_key',180),
      COALESCE(NULLIF(v_item->>'created_at','')::timestamptz,now())
    )
    ON CONFLICT (store_id,idempotency_key) DO NOTHING;

    GET DIAGNOSTICS v_inserted = ROW_COUNT;
    v_count := v_count + v_inserted;
  END LOOP;

  RETURN jsonb_build_object('success',true,'inserted',v_count);
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_save_stock_movements(uuid,jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_save_stock_movements(uuid,jsonb) TO authenticated;

-- Consumo automático calculado no servidor a partir do pedido, da ficha técnica
-- e dos itens de estoque da própria loja. O navegador não envia quantidades.
CREATE OR REPLACE FUNCTION public.rpc_consume_stock_for_order_secure(p_store_id uuid,p_order_id text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $function$
DECLARE
  v_order public.vortex_kds_orders%ROWTYPE;
  v_recipes jsonb;
  v_order_item jsonb;
  v_recipe jsonb;
  v_ingredient jsonb;
  v_product_id text;
  v_product_name text;
  v_stock_id text;
  v_stock_name text;
  v_stock_unit text;
  v_order_qty numeric;
  v_ingredient_qty numeric;
  v_required_qty numeric;
  v_item_index integer := 0;
  v_ingredient_index integer;
  v_idempotency text;
  v_inserted integer;
  v_total integer := 0;
BEGIN
  IF auth.uid() IS NULL OR NOT (
    public.vortex_user_has_permission(p_store_id,'kds.update_status')
    OR public.vortex_user_has_permission(p_store_id,'stock.consume')
  ) THEN
    RAISE EXCEPTION 'Seu perfil não pode iniciar o consumo automático de estoque.';
  END IF;

  SELECT * INTO v_order
  FROM public.vortex_kds_orders
  WHERE store_id=p_store_id AND id=p_order_id
  FOR UPDATE;

  IF NOT FOUND OR v_order.status<>'preparing' THEN
    RAISE EXCEPTION 'O consumo só pode ser processado para um pedido confirmado em preparo.';
  END IF;

  SELECT data INTO v_recipes
  FROM public.vortex_store_documents
  WHERE store_id=p_store_id AND document_key='recipes';

  IF jsonb_typeof(v_recipes) IS DISTINCT FROM 'array' THEN
    RETURN jsonb_build_object('success',true,'skipped',true,'reason','no_recipes');
  END IF;

  FOR v_order_item IN SELECT value FROM jsonb_array_elements(COALESCE(v_order.items,'[]'::jsonb))
  LOOP
    v_product_id := COALESCE(v_order_item->>'id',v_order_item->>'productId');
    v_product_name := COALESCE(v_order_item->>'name',v_order_item->>'title','');
    v_order_qty := COALESCE(NULLIF(v_order_item->>'qty','')::numeric,NULLIF(v_order_item->>'quantity','')::numeric,1);
    IF v_order_qty<=0 THEN
      RAISE EXCEPTION 'Quantidade inválida em um item do pedido.';
    END IF;

    SELECT value INTO v_recipe
    FROM jsonb_array_elements(v_recipes)
    WHERE (v_product_id IS NOT NULL AND value->>'productId'=v_product_id)
       OR (COALESCE(value->>'productName','')<>'' AND lower(value->>'productName')=lower(v_product_name))
    LIMIT 1;

    IF v_recipe IS NULL OR jsonb_typeof(v_recipe->'ingredients') IS DISTINCT FROM 'array' THEN
      v_item_index := v_item_index + 1;
      CONTINUE;
    END IF;

    v_ingredient_index := 0;
    FOR v_ingredient IN SELECT value FROM jsonb_array_elements(v_recipe->'ingredients')
    LOOP
      v_stock_id := COALESCE(v_ingredient->>'insumoId',v_ingredient->>'ingredientId');
      v_stock_name := COALESCE(v_ingredient->>'name','');
      v_ingredient_qty := NULLIF(v_ingredient->>'qty','')::numeric;

      IF v_ingredient_qty IS NULL OR v_ingredient_qty<=0 THEN
        RAISE EXCEPTION 'Ficha técnica contém quantidade de ingrediente inválida.';
      END IF;

      SELECT id,unit INTO v_stock_id,v_stock_unit
      FROM public.vortex_stock_items
      WHERE store_id=p_store_id
        AND (
          (v_stock_id IS NOT NULL AND id=v_stock_id)
          OR (v_stock_name<>'' AND lower(name)=lower(v_stock_name))
        )
      LIMIT 1
      FOR UPDATE;

      IF v_stock_id IS NOT NULL THEN
        v_required_qty := v_ingredient_qty*v_order_qty;
        IF (v_ingredient->>'unit' IN ('g','ml')) AND (v_stock_unit IN ('kg','l')) THEN
          v_required_qty := v_required_qty/1000;
        END IF;

        v_idempotency := left(
          'consumption_'||p_order_id||'_item_'||v_item_index||'_ing_'||v_stock_id,180
        );

        INSERT INTO public.vortex_stock_movements(
          store_id,id,order_id,item_id,item_name,type,qty,reason,idempotency_key,created_at
        ) VALUES (
          p_store_id,
          'mov_'||replace(gen_random_uuid()::text,'-',''),
          p_order_id,
          v_stock_id,
          left(COALESCE(v_stock_name,v_stock_id),160),
          'consumption',
          v_required_qty,
          left('Consumo automático - Pedido #'||p_order_id||' ('||v_product_name||')',300),
          v_idempotency,
          now()
        )
        ON CONFLICT (store_id,idempotency_key) DO NOTHING;

        GET DIAGNOSTICS v_inserted = ROW_COUNT;
        IF v_inserted>0 THEN
          UPDATE public.vortex_stock_items
          SET qty=GREATEST(0,COALESCE(qty,0)-v_required_qty),updated_at=now()
          WHERE store_id=p_store_id AND id=v_stock_id;
          v_total := v_total+1;
        END IF;
      END IF;

      v_ingredient_index := v_ingredient_index+1;
    END LOOP;
    v_item_index := v_item_index+1;
  END LOOP;

  RETURN jsonb_build_object('success',true,'skipped',v_total=0,'movements',v_total);
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_consume_stock_for_order_secure(uuid,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_consume_stock_for_order_secure(uuid,text) TO authenticated;

-- A RPC antiga aceitava quantidades calculadas no navegador; deixa de ser pública.
REVOKE ALL ON FUNCTION public.rpc_consume_stock_for_order(uuid,text,jsonb)
FROM PUBLIC, anon, authenticated;

-- Cancelamento: permissão depende da origem real do pedido.
CREATE OR REPLACE FUNCTION public.rpc_cancel_order(
  p_order_id text,
  p_reason text DEFAULT 'Cancelado via Sistema'::text
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $function$
DECLARE
  v_store_id uuid;
  v_membership_count integer;
  v_current_status text;
  v_origin text;
  v_updated boolean := false;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Autenticação necessária para cancelar pedido.';
  END IF;

  SELECT COUNT(*), MIN(m.store_id::text)::uuid
    INTO v_membership_count, v_store_id
  FROM public.vortex_store_members AS m
  WHERE m.user_id = auth.uid() AND m.status = 'active';

  IF v_membership_count <> 1 OR v_store_id IS NULL THEN
    RAISE EXCEPTION 'Não foi possível identificar uma única loja ativa para esta conta.';
  END IF;

  SELECT origin,status INTO v_origin,v_current_status
  FROM public.vortex_kds_orders
  WHERE id=p_order_id AND store_id=v_store_id
  LIMIT 1;

  IF COALESCE(v_origin,'') ILIKE '%Delivery%' THEN
    IF NOT (
      public.vortex_user_has_permission(v_store_id,'delivery.manage')
      OR public.vortex_user_has_permission(v_store_id,'pdv.cancel')
    ) THEN
      RAISE EXCEPTION 'Seu perfil não pode cancelar pedidos de delivery.';
    END IF;
  ELSIF COALESCE(v_origin,'') ILIKE '%Mesa%' THEN
    IF NOT (
      public.vortex_user_has_permission(v_store_id,'tables.close')
      OR public.vortex_user_has_permission(v_store_id,'pdv.cancel')
    ) THEN
      RAISE EXCEPTION 'Seu perfil não pode cancelar comandas.';
    END IF;
  ELSIF NOT (
    public.vortex_user_has_permission(v_store_id,'pdv.cancel')
    OR public.vortex_user_has_permission(v_store_id,'kds.cancel')
  ) THEN
    RAISE EXCEPTION 'Seu perfil não pode cancelar este pedido.';
  END IF;

  SELECT status INTO v_current_status
  FROM public.vortex_sales_history
  WHERE id=p_order_id AND store_id=v_store_id;

  IF FOUND THEN
    IF v_current_status='cancelled' THEN
      RETURN json_build_object('success',true,'message','Pedido já estava cancelado.');
    END IF;

    UPDATE public.vortex_sales_history
    SET status='cancelled',
        financial_status='reversed',
        cancellation_reason=left(COALESCE(p_reason,'Cancelado via Sistema'),300),
        cancelled_at=timezone('utc'::text,now()),
        cancelled_by=auth.uid(),
        updated_at=timezone('utc'::text,now())
    WHERE id=p_order_id AND store_id=v_store_id;
    v_updated := v_updated OR FOUND;
  END IF;

  UPDATE public.vortex_kds_orders
  SET status='cancelled',
      cancellation_reason=left(COALESCE(p_reason,'Cancelado via Sistema'),300),
      cancelled_at=timezone('utc'::text,now()),
      updated_at=timezone('utc'::text,now())
  WHERE id=p_order_id AND store_id=v_store_id AND status<>'cancelled';

  v_updated := v_updated OR FOUND;

  RETURN json_build_object(
    'success',v_updated,
    'message',CASE WHEN v_updated THEN 'Pedido cancelado com sucesso.' ELSE 'Pedido não encontrado nesta loja.' END
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_cancel_order(text,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_cancel_order(text,text) TO authenticated;

-- QR público: alteração de configuração exige a permissão específica.
CREATE OR REPLACE FUNCTION public.rpc_set_public_qr_enabled(p_enabled boolean)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $function$
DECLARE
  v_store_id uuid;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Autenticação necessária.'; END IF;

  SELECT store_id INTO v_store_id
  FROM public.vortex_store_members
  WHERE user_id=auth.uid() AND status='active'
  ORDER BY created_at LIMIT 1;

  IF v_store_id IS NULL OR NOT public.vortex_user_has_permission(v_store_id,'tables.manage_qr') THEN
    RAISE EXCEPTION 'Seu perfil não pode alterar as configurações do QR Code.';
  END IF;

  INSERT INTO public.vortex_public_store_settings(store_id,qr_enabled,updated_at)
  VALUES (v_store_id,COALESCE(p_enabled,false),now())
  ON CONFLICT (store_id) DO UPDATE
  SET qr_enabled=EXCLUDED.qr_enabled,updated_at=now();

  RETURN jsonb_build_object('success',true,'qr_enabled',COALESCE(p_enabled,false));
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_set_public_qr_enabled(boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_set_public_qr_enabled(boolean) TO authenticated;

CREATE OR REPLACE FUNCTION public.rpc_set_public_delivery_enabled(p_enabled boolean)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $function$
DECLARE
  v_store_id uuid;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Entre na sua conta para alterar o cardápio público.';
  END IF;

  SELECT store_id INTO v_store_id
  FROM public.vortex_store_members
  WHERE user_id=auth.uid() AND status='active'
  ORDER BY created_at LIMIT 1;

  IF v_store_id IS NULL OR NOT public.vortex_user_has_permission(v_store_id,'delivery.manage') THEN
    RAISE EXCEPTION 'Seu perfil não pode alterar as configurações do delivery.';
  END IF;

  INSERT INTO public.vortex_public_delivery_settings(store_id,delivery_enabled,updated_at)
  VALUES (v_store_id,COALESCE(p_enabled,false),now())
  ON CONFLICT (store_id) DO UPDATE
  SET delivery_enabled=EXCLUDED.delivery_enabled,updated_at=now();

  RETURN jsonb_build_object('success',true,'delivery_enabled',COALESCE(p_enabled,false));
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_set_public_delivery_enabled(boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_set_public_delivery_enabled(boolean) TO authenticated;

-- Emissão, confirmação e baixa manual de entrega exigem ações distintas.
CREATE OR REPLACE FUNCTION public.rpc_issue_delivery_verification(p_store_id uuid,p_order_id text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, extensions, auth
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
  IF auth.uid() IS NULL OR NOT public.vortex_user_has_permission(p_store_id,'delivery.dispatch') THEN
    RAISE EXCEPTION 'Seu perfil não pode despachar este pedido.';
  END IF;

  SELECT origin,status INTO v_origin,v_status
  FROM public.vortex_kds_orders
  WHERE store_id=p_store_id AND id=p_order_id
  FOR UPDATE;

  IF NOT FOUND OR COALESCE(v_origin,'') NOT ILIKE '%Delivery%' THEN
    RAISE EXCEPTION 'Pedido de delivery não encontrado neste estabelecimento.';
  END IF;
  IF v_status IN ('finished','cancelled') THEN
    RAISE EXCEPTION 'Não é possível gerar código para um pedido já finalizado ou cancelado.';
  END IF;

  UPDATE public.vortex_delivery_verifications
  SET is_active=false
  WHERE store_id=p_store_id AND is_active=true AND expires_at<=now();

  v_expires_at := now()+interval '48 hours';
  FOR v_attempt IN 1..30 LOOP
    v_random := extensions.gen_random_bytes(4);
    v_number := (
      get_byte(v_random,0)::bigint*16777216
      +get_byte(v_random,1)::bigint*65536
      +get_byte(v_random,2)::bigint*256
      +get_byte(v_random,3)::bigint
    ) % 1000000;
    v_code := lpad(v_number::text,6,'0');
    v_token := encode(extensions.gen_random_bytes(32),'hex');
    BEGIN
      INSERT INTO public.vortex_delivery_verifications(
        store_id,order_id,code,access_token_hash,attempt_count,
        locked_until,expires_at,consumed_at,is_active,created_at
      ) VALUES (
        p_store_id,p_order_id,v_code,md5(v_token),0,NULL,
        v_expires_at,NULL,true,now()
      )
      ON CONFLICT (store_id,order_id) DO UPDATE
      SET code=EXCLUDED.code,access_token_hash=EXCLUDED.access_token_hash,
          attempt_count=0,locked_until=NULL,expires_at=EXCLUDED.expires_at,
          consumed_at=NULL,is_active=true,created_at=now();

      RETURN jsonb_build_object('success',true,'access_token',v_token,'expires_at',v_expires_at);
    EXCEPTION WHEN unique_violation THEN NULL;
    END;
  END LOOP;

  RAISE EXCEPTION 'Não foi possível gerar um código exclusivo. Tente novamente.';
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_issue_delivery_verification(uuid,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_issue_delivery_verification(uuid,text) TO authenticated;

CREATE OR REPLACE FUNCTION public.rpc_confirm_delivery_code(p_store_id uuid,p_order_id text,p_code text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $function$
DECLARE
  v_verification public.vortex_delivery_verifications%ROWTYPE;
  v_origin text;
  v_status text;
  v_attempts integer;
  v_profile_key text;
  v_courier_member_id uuid;
BEGIN
  IF auth.uid() IS NULL OR NOT public.vortex_user_has_permission(p_store_id,'delivery.confirm') THEN
    RAISE EXCEPTION 'Seu perfil não pode confirmar entregas.';
  END IF;

  SELECT profile_key INTO v_profile_key
  FROM public.vortex_store_members
  WHERE store_id=p_store_id AND user_id=auth.uid() AND status='active';

  SELECT origin,status,courier_member_id
  INTO v_origin,v_status,v_courier_member_id
  FROM public.vortex_kds_orders
  WHERE store_id=p_store_id AND id=p_order_id
  FOR UPDATE;

  IF NOT FOUND OR COALESCE(v_origin,'') NOT ILIKE '%Delivery%' OR v_status<>'delivering' THEN
    RETURN jsonb_build_object('success',false,'message','Este pedido não está em rota de entrega.');
  END IF;

  IF v_profile_key='delivery' AND v_courier_member_id IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'Este pedido não está atribuído à sua conta de entregador.';
  END IF;

  SELECT * INTO v_verification
  FROM public.vortex_delivery_verifications
  WHERE store_id=p_store_id AND order_id=p_order_id
  FOR UPDATE;

  IF NOT FOUND OR NOT v_verification.is_active
     OR v_verification.consumed_at IS NOT NULL
     OR v_verification.expires_at<=now() THEN
    RETURN jsonb_build_object('success',false,'message','Código inexistente, expirado ou já utilizado.');
  END IF;

  IF v_verification.locked_until IS NOT NULL AND v_verification.locked_until>now() THEN
    RETURN jsonb_build_object('success',false,'message','Muitas tentativas incorretas. Aguarde 15 minutos antes de tentar novamente.');
  END IF;

  IF v_verification.attempt_count>=5 THEN
    UPDATE public.vortex_delivery_verifications
    SET attempt_count=0,locked_until=NULL
    WHERE store_id=p_store_id AND order_id=p_order_id;
    v_verification.attempt_count:=0;
  END IF;

  IF COALESCE(p_code,'') !~ '^[0-9]{6}$' OR p_code<>v_verification.code THEN
    v_attempts:=v_verification.attempt_count+1;
    UPDATE public.vortex_delivery_verifications
    SET attempt_count=v_attempts,
        locked_until=CASE WHEN v_attempts>=5 THEN now()+interval '15 minutes' ELSE NULL END
    WHERE store_id=p_store_id AND order_id=p_order_id;
    RETURN jsonb_build_object(
      'success',false,
      'message',CASE WHEN v_attempts>=5
        THEN 'Limite de tentativas atingido. Aguarde 15 minutos.'
        ELSE 'Código incorreto. Confira os seis números e tente novamente.' END
    );
  END IF;

  UPDATE public.vortex_delivery_verifications
  SET is_active=false,consumed_at=now()
  WHERE store_id=p_store_id AND order_id=p_order_id;

  UPDATE public.vortex_kds_orders
  SET status='finished',updated_at=now()
  WHERE store_id=p_store_id AND id=p_order_id;

  RETURN jsonb_build_object('success',true,'message','Entrega confirmada com sucesso.');
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_confirm_delivery_code(uuid,text,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_confirm_delivery_code(uuid,text,text) TO authenticated;

CREATE OR REPLACE FUNCTION public.rpc_mark_delivery_manual(p_store_id uuid,p_order_id text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $function$
DECLARE
  v_updated_id text;
BEGIN
  IF auth.uid() IS NULL OR NOT public.vortex_user_has_permission(p_store_id,'delivery.manual_finish') THEN
    RAISE EXCEPTION 'Seu perfil não pode finalizar entregas manualmente.';
  END IF;

  UPDATE public.vortex_kds_orders
  SET status='finished',updated_at=now()
  WHERE store_id=p_store_id
    AND id=p_order_id
    AND origin ILIKE '%Delivery%'
    AND status NOT IN ('finished','cancelled')
  RETURNING id INTO v_updated_id;

  IF v_updated_id IS NULL THEN
    RETURN jsonb_build_object('success',false,'message','Pedido não encontrado ou já finalizado.');
  END IF;

  UPDATE public.vortex_delivery_verifications
  SET is_active=false,consumed_at=COALESCE(consumed_at,now())
  WHERE store_id=p_store_id AND order_id=p_order_id;

  RETURN jsonb_build_object('success',true,'message','Pedido marcado como entregue manualmente.');
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_mark_delivery_manual(uuid,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_mark_delivery_manual(uuid,text) TO authenticated;

COMMIT;
