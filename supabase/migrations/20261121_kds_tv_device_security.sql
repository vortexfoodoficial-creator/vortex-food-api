-- VORTEX FOOD: infraestrutura segura para TVs do KDS.
-- Esta migração cria somente estruturas isoladas para dispositivos de TV
-- e uma RPC de leitura com payload permitido por perfil.
-- Não altera pedidos, permissões atuais, RPCs existentes ou dados operacionais.

BEGIN;

DO $preflight$
BEGIN
  IF to_regclass('public.vortex_stores') IS NULL
     OR to_regclass('public.vortex_store_members') IS NULL
     OR to_regclass('public.vortex_kds_orders') IS NULL THEN
    RAISE EXCEPTION 'Estruturas-base do Vortex Food ausentes. Migração cancelada.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_extension e
    JOIN pg_namespace n ON n.oid=e.extnamespace
    WHERE e.extname='pgcrypto' AND n.nspname='extensions'
  ) THEN
    RAISE EXCEPTION 'A extensão pgcrypto não está disponível no schema extensions. Migração cancelada.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='public' AND table_name='vortex_kds_orders' AND column_name='store_id'
  ) OR NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='public' AND table_name='vortex_kds_orders' AND column_name='id'
  ) OR NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='public' AND table_name='vortex_kds_orders' AND column_name='items'
  ) OR NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='public' AND table_name='vortex_kds_orders' AND column_name='status'
  ) OR NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='public' AND table_name='vortex_kds_orders' AND column_name='date'
  ) OR NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='public' AND table_name='vortex_kds_orders' AND column_name='time'
  ) OR NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='public' AND table_name='vortex_kds_orders' AND column_name='origin'
  ) OR NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='public' AND table_name='vortex_kds_orders' AND column_name='updated_at'
  ) THEN
    RAISE EXCEPTION 'A tabela vortex_kds_orders não possui as colunas mínimas esperadas. Migração cancelada.';
  END IF;
END;
$preflight$;

CREATE TABLE IF NOT EXISTS public.vortex_kds_tv_devices (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  store_id uuid NOT NULL REFERENCES public.vortex_stores(id) ON DELETE CASCADE,
  device_name text NOT NULL CHECK (length(btrim(device_name)) BETWEEN 1 AND 80),
  profile text NOT NULL CHECK (profile IN ('public','kitchen')),
  config jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(config)='object'),
  token_hash bytea NOT NULL UNIQUE,
  created_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  last_seen_at timestamptz,
  revoked_at timestamptz,
  is_active boolean NOT NULL DEFAULT true,
  CONSTRAINT vortex_kds_tv_devices_revocation_check
    CHECK (is_active = (revoked_at IS NULL))
);

CREATE INDEX IF NOT EXISTS vortex_kds_tv_devices_store_active_idx
  ON public.vortex_kds_tv_devices(store_id, is_active, created_at DESC);

CREATE TABLE IF NOT EXISTS public.vortex_kds_tv_pairings (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  store_id uuid NOT NULL REFERENCES public.vortex_stores(id) ON DELETE CASCADE,
  pairing_type text NOT NULL CHECK (pairing_type IN ('qr','pin')),
  pairing_hash bytea NOT NULL UNIQUE,
  device_name text NOT NULL CHECK (length(btrim(device_name)) BETWEEN 1 AND 80),
  profile text NOT NULL CHECK (profile IN ('public','kitchen')),
  created_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz NOT NULL,
  attempts integer NOT NULL DEFAULT 0 CHECK (attempts >= 0),
  max_attempts integer NOT NULL DEFAULT 5 CHECK (max_attempts BETWEEN 1 AND 10),
  consumed_at timestamptz,
  CONSTRAINT vortex_kds_tv_pairings_expiry_check CHECK (expires_at > created_at)
);

CREATE INDEX IF NOT EXISTS vortex_kds_tv_pairings_store_expiry_idx
  ON public.vortex_kds_tv_pairings(store_id, expires_at);

ALTER TABLE public.vortex_kds_tv_devices ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.vortex_kds_tv_pairings ENABLE ROW LEVEL SECURITY;

-- Nenhum acesso direto pelo navegador. As próximas etapas usarão RPCs controladas.
REVOKE ALL ON TABLE public.vortex_kds_tv_devices FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.vortex_kds_tv_pairings FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.rpc_get_kds_tv_feed(p_device_token text)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $function$
DECLARE
  v_device_id uuid;
  v_store_id uuid;
  v_profile text;
  v_orders jsonb;
BEGIN
  IF p_device_token IS NULL
     OR length(p_device_token) < 32
     OR length(p_device_token) > 256 THEN
    RETURN jsonb_build_object('authorized',false,'reason','invalid_token');
  END IF;

  SELECT d.id,d.store_id,d.profile
    INTO v_device_id,v_store_id,v_profile
  FROM public.vortex_kds_tv_devices AS d
  WHERE d.token_hash = extensions.digest(p_device_token,'sha256')
    AND d.is_active = true
    AND d.revoked_at IS NULL
  LIMIT 1;

  IF v_device_id IS NULL THEN
    IF EXISTS (
      SELECT 1
      FROM public.vortex_kds_tv_devices AS d
      WHERE d.token_hash = extensions.digest(p_device_token,'sha256')
        AND (d.is_active = false OR d.revoked_at IS NOT NULL)
    ) THEN
      RETURN jsonb_build_object('authorized',false,'reason','revoked');
    END IF;
    RETURN jsonb_build_object('authorized',false,'reason','invalid_token');
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.vortex_stores AS s
    WHERE s.id=v_store_id AND s.status='active'
  ) THEN
    RETURN jsonb_build_object('authorized',false,'reason','store_unavailable');
  END IF;

  UPDATE public.vortex_kds_tv_devices
  SET last_seen_at=now()
  WHERE id=v_device_id AND is_active=true AND revoked_at IS NULL;

  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'id',o.id,
        'status',o.status,
        'date',o.date,
        'time',o.time,
        'origin',o.origin,
        'items',
          COALESCE((
            SELECT jsonb_agg(
              CASE WHEN v_profile='kitchen' THEN
                jsonb_build_object(
                  'name',left(COALESCE(NULLIF(x.value->>'name',''),'Item'),160),
                  'quantity',
                    CASE jsonb_typeof(x.value->'qty')
                      WHEN 'number' THEN x.value->'qty'
                      WHEN 'string' THEN to_jsonb(left(x.value->>'qty',12))
                      ELSE '1'::jsonb
                    END,
                  'category',left(COALESCE(x.value->>'category',''),80)
                )
              ELSE
                jsonb_build_object(
                  'name',left(COALESCE(NULLIF(x.value->>'name',''),'Item'),160),
                  'quantity',
                    CASE jsonb_typeof(x.value->'qty')
                      WHEN 'number' THEN x.value->'qty'
                      WHEN 'string' THEN to_jsonb(left(x.value->>'qty',12))
                      ELSE '1'::jsonb
                    END
                )
              END
              ORDER BY x.ordinality
            )
            FROM jsonb_array_elements(
              CASE WHEN jsonb_typeof(o.items)='array' THEN o.items ELSE '[]'::jsonb END
            ) WITH ORDINALITY AS x(value,ordinality)
            WHERE jsonb_typeof(x.value)='object'
          ),'[]'::jsonb)
      )
      ORDER BY o.date DESC NULLS LAST,o.time DESC NULLS LAST,o.updated_at DESC NULLS LAST
    ),
    '[]'::jsonb
  )
  INTO v_orders
  FROM (
    SELECT id,status,date,time,origin,items,updated_at
    FROM public.vortex_kds_orders
    WHERE store_id=v_store_id
      AND status NOT IN ('finished','cancelled')
    ORDER BY date DESC NULLS LAST,time DESC NULLS LAST,updated_at DESC NULLS LAST
    LIMIT 100
  ) AS o;

  RETURN jsonb_build_object(
    'authorized',true,
    'profile',v_profile,
    'orders',v_orders,
    'server_time',now()
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_get_kds_tv_feed(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_get_kds_tv_feed(text) TO anon, authenticated;

COMMIT;
