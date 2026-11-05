-- VORTEX FOOD | Diagnóstico somente leitura antes do isolamento por loja.
-- Execute no SQL Editor do Supabase ANTES das migrações.
-- Este arquivo contém apenas consultas SELECT: não altera nem apaga dados.

-- 1) Confirma a existência das tabelas operacionais esperadas.
SELECT required.table_name,
       to_regclass('public.' || required.table_name) AS resolved_table
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
  ('vortex_store_settings'),
  ('vortex_stores'),
  ('vortex_store_members')
) AS required(table_name)
ORDER BY required.table_name;

-- 2) Lista colunas das tabelas que serão alteradas.
-- Conferir especialmente vortex_integrations.platform e as colunas id.
SELECT table_name, column_name, data_type, is_nullable
FROM information_schema.columns
WHERE table_schema = 'public'
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
ORDER BY table_name, ordinal_position;

-- 3) Lista TODAS as chaves estrangeiras que apontam para tabelas que terão
-- a chave primária alterada ou serão esvaziadas.
-- Qualquer dependência externa precisa ser analisada antes da migração.
SELECT
  c.conrelid::regclass AS referencing_table,
  c.conname AS foreign_key_name,
  c.confrelid::regclass AS referenced_table,
  pg_get_constraintdef(c.oid) AS definition
FROM pg_constraint AS c
WHERE c.contype = 'f'
  AND c.confrelid IN (
    'public.cash_shifts'::regclass,
    'public.vortex_financial'::regclass,
    'public.vortex_integrations'::regclass,
    'public.vortex_kds'::regclass,
    'public.vortex_kds_orders'::regclass,
    'public.vortex_sales'::regclass,
    'public.vortex_sales_history'::regclass,
    'public.vortex_stock_items'::regclass,
    'public.vortex_stock_movements'::regclass,
    'public.vortex_store_settings'::regclass
  )
ORDER BY referenced_table::text, referencing_table::text, foreign_key_name;

-- 4) Mostra as chaves primárias e restrições UNIQUE atuais das tabelas-alvo.
SELECT
  c.conrelid::regclass AS table_name,
  c.conname AS constraint_name,
  c.contype AS constraint_type,
  pg_get_constraintdef(c.oid) AS definition
FROM pg_constraint AS c
WHERE c.conrelid IN (
  'public.cash_shifts'::regclass,
  'public.vortex_financial'::regclass,
  'public.vortex_integrations'::regclass,
  'public.vortex_kds'::regclass,
  'public.vortex_kds_orders'::regclass,
  'public.vortex_sales'::regclass,
  'public.vortex_sales_history'::regclass,
  'public.vortex_stock_items'::regclass,
  'public.vortex_stock_movements'::regclass,
  'public.vortex_store_settings'::regclass
)
AND c.contype IN ('p', 'u')
ORDER BY table_name::text, constraint_type, constraint_name;

-- 5) Confirma a quantidade de registros atuais por tabela.
-- Esta consulta é apenas informativa; não executa limpeza.
SELECT 'cash_shifts' AS table_name, count(*) AS row_count FROM public.cash_shifts
UNION ALL SELECT 'vortex_financial', count(*) FROM public.vortex_financial
UNION ALL SELECT 'vortex_integrations', count(*) FROM public.vortex_integrations
UNION ALL SELECT 'vortex_kds', count(*) FROM public.vortex_kds
UNION ALL SELECT 'vortex_kds_orders', count(*) FROM public.vortex_kds_orders
UNION ALL SELECT 'vortex_sales', count(*) FROM public.vortex_sales
UNION ALL SELECT 'vortex_sales_history', count(*) FROM public.vortex_sales_history
UNION ALL SELECT 'vortex_stock_items', count(*) FROM public.vortex_stock_items
UNION ALL SELECT 'vortex_stock_movements', count(*) FROM public.vortex_stock_movements
UNION ALL SELECT 'vortex_store_settings', count(*) FROM public.vortex_store_settings
ORDER BY table_name;
