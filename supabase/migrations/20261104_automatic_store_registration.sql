-- Vortex Food | Cadastro automatico de restaurantes e periodo de teste
-- Migration: 2026-11-04
-- Execute no SQL Editor do Supabase, no projeto Vortex Food.
-- Esta migration nao apaga nem altera registros das tabelas antigas de operacao.

BEGIN;

-- 1) Dados complementares do estabelecimento (a tabela ja existe).
ALTER TABLE public.vortex_stores
  ADD COLUMN IF NOT EXISTS contact_name TEXT,
  ADD COLUMN IF NOT EXISTS document TEXT,
  ADD COLUMN IF NOT EXISTS whatsapp TEXT;

-- 2) Controle inicial da assinatura e do teste gratis.
CREATE TABLE IF NOT EXISTS public.vortex_subscriptions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  store_id UUID NOT NULL UNIQUE
    REFERENCES public.vortex_stores(id) ON DELETE CASCADE,
  plan_code TEXT NOT NULL DEFAULT 'trial',
  status TEXT NOT NULL DEFAULT 'trialing'
    CHECK (status IN ('trialing', 'active', 'past_due', 'suspended', 'canceled')),
  trial_started_at TIMESTAMPTZ NOT NULL,
  trial_ends_at TIMESTAMPTZ NOT NULL,
  current_period_start TIMESTAMPTZ,
  current_period_end TIMESTAMPTZ,
  grace_period_ends_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT vortex_subscriptions_trial_window_check
    CHECK (trial_ends_at > trial_started_at)
);

CREATE INDEX IF NOT EXISTS idx_vortex_subscriptions_status
  ON public.vortex_subscriptions(status);

-- 3) RLS: o membro ve somente o proprio vinculo.
ALTER TABLE public.vortex_stores ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.vortex_store_members ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.vortex_subscriptions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS vortex_store_members_select_self
  ON public.vortex_store_members;
CREATE POLICY vortex_store_members_select_self
  ON public.vortex_store_members
  FOR SELECT TO authenticated
  USING (user_id = auth.uid() AND status = 'active');

-- 4) O estabelecimento so pode ser consultado por membro ativo dele.
DROP POLICY IF EXISTS vortex_stores_select_members
  ON public.vortex_stores;
CREATE POLICY vortex_stores_select_members
  ON public.vortex_stores
  FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1
      FROM public.vortex_store_members AS m
      WHERE m.store_id = vortex_stores.id
        AND m.user_id = auth.uid()
        AND m.status = 'active'
    )
  );

-- 5) A assinatura so pode ser consultada por membro ativo do estabelecimento.
DROP POLICY IF EXISTS vortex_subscriptions_select_members
  ON public.vortex_subscriptions;
CREATE POLICY vortex_subscriptions_select_members
  ON public.vortex_subscriptions
  FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1
      FROM public.vortex_store_members AS m
      WHERE m.store_id = vortex_subscriptions.store_id
        AND m.user_id = auth.uid()
        AND m.status = 'active'
    )
  );

GRANT USAGE ON SCHEMA public TO authenticated;
GRANT SELECT ON TABLE public.vortex_stores TO authenticated;
GRANT SELECT ON TABLE public.vortex_store_members TO authenticated;
GRANT SELECT ON TABLE public.vortex_subscriptions TO authenticated;

-- 6) Finaliza o cadastro usando somente o usuario autenticado.
-- Os dados do restaurante sao lidos dos metadados enviados no signUp do Supabase Auth.
-- O navegador nao escolhe user_id, store_id ou role.
CREATE OR REPLACE FUNCTION public.rpc_complete_store_registration()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $function$
DECLARE
  v_user_id UUID;
  v_metadata JSONB;
  v_store_name TEXT;
  v_legal_name TEXT;
  v_contact_name TEXT;
  v_document TEXT;
  v_whatsapp TEXT;
  v_store_id UUID;
  v_subscription_id UUID;
  v_trial_started_at TIMESTAMPTZ;
  v_trial_ends_at TIMESTAMPTZ;
BEGIN
  v_user_id := auth.uid();

  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Voce precisa estar autenticado para concluir o cadastro.';
  END IF;

  -- Evita dois cadastros simultaneos para a mesma conta.
  PERFORM pg_advisory_xact_lock(hashtextextended(v_user_id::TEXT, 0));

  SELECT u.raw_user_meta_data
    INTO v_metadata
  FROM auth.users AS u
  WHERE u.id = v_user_id;

  IF v_metadata IS NULL THEN
    RAISE EXCEPTION 'Nao foi possivel localizar os dados do cadastro.';
  END IF;

  v_store_name := NULLIF(BTRIM(v_metadata ->> 'store_name'), '');
  v_legal_name := NULLIF(BTRIM(v_metadata ->> 'legal_name'), '');
  v_contact_name := NULLIF(BTRIM(v_metadata ->> 'contact_name'), '');
  v_document := NULLIF(BTRIM(v_metadata ->> 'document'), '');
  v_whatsapp := NULLIF(BTRIM(v_metadata ->> 'whatsapp'), '');

  -- Se o usuario ja concluiu o cadastro, a chamada e segura para repetir.
  SELECT m.store_id
    INTO v_store_id
  FROM public.vortex_store_members AS m
  WHERE m.user_id = v_user_id
    AND m.role = 'owner'
    AND m.status = 'active'
  ORDER BY m.created_at
  LIMIT 1;

  IF v_store_id IS NOT NULL THEN
    SELECT s.id, s.trial_started_at, s.trial_ends_at
      INTO v_subscription_id, v_trial_started_at, v_trial_ends_at
    FROM public.vortex_subscriptions AS s
    WHERE s.store_id = v_store_id
    LIMIT 1;

    IF v_subscription_id IS NULL THEN
      v_trial_started_at := clock_timestamp();
      v_trial_ends_at := v_trial_started_at + INTERVAL '30 days';

      INSERT INTO public.vortex_subscriptions (
        store_id, plan_code, status, trial_started_at, trial_ends_at
      )
      VALUES (
        v_store_id, 'trial', 'trialing', v_trial_started_at, v_trial_ends_at
      )
      RETURNING id INTO v_subscription_id;
    END IF;

    RETURN jsonb_build_object(
      'success', TRUE,
      'already_registered', TRUE,
      'store_id', v_store_id,
      'subscription_id', v_subscription_id,
      'trial_started_at', v_trial_started_at,
      'trial_ends_at', v_trial_ends_at
    );
  END IF;

  IF v_store_name IS NULL OR v_contact_name IS NULL
     OR v_document IS NULL OR v_whatsapp IS NULL THEN
    RAISE EXCEPTION 'Cadastro incompleto. Volte a pagina inicial e preencha os dados do estabelecimento.';
  END IF;

  INSERT INTO public.vortex_stores (
    name, legal_name, contact_name, document, whatsapp, status
  )
  VALUES (
    v_store_name, v_legal_name, v_contact_name, v_document, v_whatsapp, 'active'
  )
  RETURNING id INTO v_store_id;

  INSERT INTO public.vortex_store_members (
    store_id, user_id, role, status
  )
  VALUES (
    v_store_id, v_user_id, 'owner', 'active'
  );

  -- O prazo comeca quando o cadastro e efetivamente finalizado.
  v_trial_started_at := clock_timestamp();
  v_trial_ends_at := v_trial_started_at + INTERVAL '30 days';

  INSERT INTO public.vortex_subscriptions (
    store_id, plan_code, status, trial_started_at, trial_ends_at
  )
  VALUES (
    v_store_id, 'trial', 'trialing', v_trial_started_at, v_trial_ends_at
  )
  RETURNING id INTO v_subscription_id;

  RETURN jsonb_build_object(
    'success', TRUE,
    'already_registered', FALSE,
    'store_id', v_store_id,
    'subscription_id', v_subscription_id,
    'trial_started_at', v_trial_started_at,
    'trial_ends_at', v_trial_ends_at
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_complete_store_registration() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.rpc_complete_store_registration() FROM anon;
GRANT EXECUTE ON FUNCTION public.rpc_complete_store_registration() TO authenticated;

COMMIT;
