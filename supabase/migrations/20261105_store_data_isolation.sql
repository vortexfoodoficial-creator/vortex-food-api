-- VORTEX FOOD
-- Isolamento inicial dos dados operacionais por estabelecimento.
-- IMPORTANTE:
-- 1) Executar somente depois de conferir que o backup do banco foi concluído.
-- 2) Esta migração APAGA somente os registros operacionais de teste listados abaixo.
-- 3) Não apaga lojas, membros, usuários, assinaturas, tabelas ou módulos.
-- 4) Após esta migração, as tabelas operacionais aceitam acesso somente de usuários
--    autenticados que tenham vínculo ativo com o estabelecimento.
-- 5) O fluxo público de pedidos deverá usar uma RPC pública controlada em etapa própria.

BEGIN;

-- Proteção contra execução repetida: evita apagar dados reais numa segunda execução.
DO $$
BEGIN
  IF (
    SELECT COUNT(*)
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND column_name = 'store_id'
      AND table_name IN (
        'cash_shifts',
        'vortex_financial',
        'vortex_integrations',
        'vortex_kds',
        'vortex_kds_orders',
        'vortex_sales',
        'vortex_sales_history',
        'vortex_stock_items',
        'vortex_stock_movements',
        'vortex_store_settings'
      )
  ) = 10 THEN
    RAISE EXCEPTION 'A migração de isolamento já parece ter sido aplicada. Nenhum dado foi apagado.';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.vortex_stores LIMIT 1) THEN
    RAISE EXCEPTION 'Nenhum estabelecimento cadastrado. Migração cancelada por segurança.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM (VALUES
      ('cash_shifts'),
      ('vortex_financial'),
      ('vortex_integrations'),
      ('vortex_kds'),
      ('vortex_kds_orders'),
      ('vortex_sales'),
      ('vortex_sales_history'),
      ('vortex_stock_items'),
      ('vortex_stock_movements'),
      ('vortex_store_settings')
    ) AS required(table_name)
    WHERE to_regclass('public.' || required.table_name) IS NULL
  ) THEN
    RAISE EXCEPTION 'Uma ou mais tabelas esperadas não existem. Migração cancelada.';
  END IF;
END;
$$;

-- Limpa exclusivamente registros de teste das tabelas operacionais existentes.
-- As estruturas, funções, usuários, estabelecimentos e assinaturas são preservados.
TRUNCATE TABLE
  public.cash_shifts,
  public.vortex_financial,
  public.vortex_integrations,
  public.vortex_kds,
  public.vortex_kds_orders,
  public.vortex_sales,
  public.vortex_sales_history,
  public.vortex_stock_items,
  public.vortex_stock_movements,
  public.vortex_store_settings;

-- Adiciona a associação obrigatória com o estabelecimento.
ALTER TABLE public.cash_shifts ADD COLUMN IF NOT EXISTS store_id uuid;
ALTER TABLE public.vortex_financial ADD COLUMN IF NOT EXISTS store_id uuid;
ALTER TABLE public.vortex_integrations ADD COLUMN IF NOT EXISTS store_id uuid;
ALTER TABLE public.vortex_kds ADD COLUMN IF NOT EXISTS store_id uuid;
ALTER TABLE public.vortex_kds_orders ADD COLUMN IF NOT EXISTS store_id uuid;
ALTER TABLE public.vortex_sales ADD COLUMN IF NOT EXISTS store_id uuid;
ALTER TABLE public.vortex_sales_history ADD COLUMN IF NOT EXISTS store_id uuid;
ALTER TABLE public.vortex_stock_items ADD COLUMN IF NOT EXISTS store_id uuid;
ALTER TABLE public.vortex_stock_movements ADD COLUMN IF NOT EXISTS store_id uuid;
ALTER TABLE public.vortex_store_settings ADD COLUMN IF NOT EXISTS store_id uuid;

-- Impede que registros operacionais sejam criados sem um estabelecimento.
ALTER TABLE public.cash_shifts ALTER COLUMN store_id SET NOT NULL;
ALTER TABLE public.vortex_financial ALTER COLUMN store_id SET NOT NULL;
ALTER TABLE public.vortex_integrations ALTER COLUMN store_id SET NOT NULL;
ALTER TABLE public.vortex_kds ALTER COLUMN store_id SET NOT NULL;
ALTER TABLE public.vortex_kds_orders ALTER COLUMN store_id SET NOT NULL;
ALTER TABLE public.vortex_sales ALTER COLUMN store_id SET NOT NULL;
ALTER TABLE public.vortex_sales_history ALTER COLUMN store_id SET NOT NULL;
ALTER TABLE public.vortex_stock_items ALTER COLUMN store_id SET NOT NULL;
ALTER TABLE public.vortex_stock_movements ALTER COLUMN store_id SET NOT NULL;
ALTER TABLE public.vortex_store_settings ALTER COLUMN store_id SET NOT NULL;

-- Garante integridade referencial: cada registro pertence a uma loja existente.
DO $$
DECLARE
  t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'cash_shifts',
    'vortex_financial',
    'vortex_integrations',
    'vortex_kds',
    'vortex_kds_orders',
    'vortex_sales',
    'vortex_sales_history',
    'vortex_stock_items',
    'vortex_stock_movements',
    'vortex_store_settings'
  ]
  LOOP
    IF NOT EXISTS (
      SELECT 1 FROM pg_constraint
      WHERE conrelid = format('public.%I', t)::regclass
        AND conname = t || '_store_id_fkey'
    ) THEN
      EXECUTE format(
        'ALTER TABLE public.%I ADD CONSTRAINT %I FOREIGN KEY (store_id) REFERENCES public.vortex_stores(id) ON DELETE CASCADE',
        t, t || '_store_id_fkey'
      );
    END IF;
  END LOOP;
END;
$$;

-- Chaves que precisam ser únicas dentro de cada estabelecimento.
ALTER TABLE public.vortex_integrations DROP CONSTRAINT IF EXISTS vortex_integrations_pkey;
ALTER TABLE public.vortex_integrations
  ADD CONSTRAINT vortex_integrations_pkey PRIMARY KEY (store_id, platform);

ALTER TABLE public.vortex_store_settings DROP CONSTRAINT IF EXISTS vortex_store_settings_pkey;
ALTER TABLE public.vortex_store_settings
  ADD CONSTRAINT vortex_store_settings_pkey PRIMARY KEY (store_id, id);

ALTER TABLE public.vortex_stock_movements
  DROP CONSTRAINT IF EXISTS vortex_stock_movements_idempotency_key_key;
ALTER TABLE public.vortex_stock_movements
  ADD CONSTRAINT vortex_stock_movements_store_id_idempotency_key_key
  UNIQUE (store_id, idempotency_key);

-- Função auxiliar: valida o vínculo ativo do usuário com a loja solicitada.
CREATE OR REPLACE FUNCTION public.vortex_user_has_store_access(p_store_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $function$
  SELECT EXISTS (
    SELECT 1
    FROM public.vortex_store_members AS m
    WHERE m.store_id = p_store_id
      AND m.user_id = auth.uid()
      AND m.status = 'active'
  );
$function$;

REVOKE ALL ON FUNCTION public.vortex_user_has_store_access(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.vortex_user_has_store_access(uuid) TO authenticated;

-- Remove políticas antigas abertas e cria políticas por estabelecimento.
DO $$
DECLARE
  t text;
  p record;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'cash_shifts',
    'vortex_financial',
    'vortex_integrations',
    'vortex_kds',
    'vortex_kds_orders',
    'vortex_sales',
    'vortex_sales_history',
    'vortex_stock_items',
    'vortex_stock_movements',
    'vortex_store_settings'
  ]
  LOOP
    FOR p IN
      SELECT policyname
      FROM pg_policies
      WHERE schemaname = 'public'
        AND tablename = t
    LOOP
      EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', p.policyname, t);
    END LOOP;

    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format(
      'CREATE POLICY %I ON public.%I FOR ALL TO authenticated USING (public.vortex_user_has_store_access(store_id)) WITH CHECK (public.vortex_user_has_store_access(store_id))',
      t || '_store_isolation',
      t
    );

    EXECUTE format('REVOKE ALL ON TABLE public.%I FROM PUBLIC, anon', t);
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.%I TO authenticated', t);
  END LOOP;
END;
$$;

-- A função de cancelamento passa a operar somente na única loja ativa
-- vinculada ao usuário autenticado. Não altera pedidos de outra loja.
CREATE OR REPLACE FUNCTION public.rpc_cancel_order(
  p_order_id text,
  p_reason text DEFAULT 'Cancelado via Sistema'::text
)
RETURNS json
LANGUAGE plpgsql
AS $function$
DECLARE
  v_store_id uuid;
  v_membership_count integer;
  v_current_status text;
  v_updated boolean := false;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Autenticação necessária para cancelar pedido.';
  END IF;

  SELECT COUNT(*), MIN(m.store_id::text)::uuid
    INTO v_membership_count, v_store_id
  FROM public.vortex_store_members AS m
  WHERE m.user_id = auth.uid()
    AND m.status = 'active';

  IF v_membership_count <> 1 OR v_store_id IS NULL THEN
    RAISE EXCEPTION 'Não foi possível identificar uma única loja ativa para esta conta.';
  END IF;

  SELECT status
    INTO v_current_status
  FROM public.vortex_sales_history
  WHERE id = p_order_id
    AND store_id = v_store_id;

  IF FOUND THEN
    IF v_current_status = 'cancelled' THEN
      RETURN json_build_object('success', true, 'message', 'Pedido já estava cancelado.');
    END IF;

    UPDATE public.vortex_sales_history
    SET status = 'cancelled',
        financial_status = 'reversed',
        cancellation_reason = p_reason,
        cancelled_at = timezone('utc'::text, now()),
        updated_at = timezone('utc'::text, now())
    WHERE id = p_order_id
      AND store_id = v_store_id;

    v_updated := v_updated OR FOUND;
  END IF;

  UPDATE public.vortex_kds_orders
  SET status = 'cancelled',
      cancellation_reason = p_reason,
      cancelled_at = timezone('utc'::text, now()),
      updated_at = timezone('utc'::text, now())
  WHERE id = p_order_id
    AND store_id = v_store_id;

  v_updated := v_updated OR FOUND;

  RETURN json_build_object(
    'success', v_updated,
    'message', CASE WHEN v_updated THEN 'Pedido cancelado com sucesso.' ELSE 'Pedido não encontrado nesta loja.' END
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_cancel_order(text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_cancel_order(text, text) TO authenticated;

-- Mantém o cadastro automático de lojas disponível somente para usuários autenticados.
REVOKE ALL ON FUNCTION public.rpc_complete_store_registration() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_complete_store_registration() TO authenticated;

COMMIT;
