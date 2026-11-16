-- VORTEX FOOD: pareamento seguro de TVs do KDS por QR Code ou PIN.
-- A TV cria um desafio temporário e mantém sua própria credencial bruta.
-- O KDS autenticado aprova o desafio e o servidor vincula o hash da credencial
-- ao estabelecimento ativo. Nenhuma credencial permanente é armazenada em texto puro.

BEGIN;

DO $preflight$
BEGIN
  IF to_regclass('public.vortex_kds_tv_devices') IS NULL
     OR to_regclass('public.vortex_kds_tv_pairings') IS NULL THEN
    RAISE EXCEPTION 'As tabelas de TV do KDS não existem. Aplique primeiro a migração 20261121_kds_tv_device_security.sql.';
  END IF;

  IF to_regprocedure('public.vortex_user_has_store_access(uuid)') IS NULL
     OR to_regprocedure('public.vortex_user_has_permission(uuid,text)') IS NULL THEN
    RAISE EXCEPTION 'As funções de autorização do Vortex Food não foram encontradas.';
  END IF;
END;
$preflight$;

-- Uma solicitação ainda não aprovada não pertence a uma loja.
-- A loja é definida exclusivamente pelo usuário autenticado que aprova o pareamento.
ALTER TABLE public.vortex_kds_tv_pairings
  ALTER COLUMN store_id DROP NOT NULL;

ALTER TABLE public.vortex_kds_tv_pairings
  ADD COLUMN IF NOT EXISTS token_hash bytea,
  ADD COLUMN IF NOT EXISTS approved_at timestamptz,
  ADD COLUMN IF NOT EXISTS device_id uuid
    REFERENCES public.vortex_kds_tv_devices(id) ON DELETE SET NULL;

DO $constraints$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname='vortex_kds_tv_pairings_token_hash_length'
      AND conrelid='public.vortex_kds_tv_pairings'::regclass
  ) THEN
    ALTER TABLE public.vortex_kds_tv_pairings
      ADD CONSTRAINT vortex_kds_tv_pairings_token_hash_length
      CHECK (token_hash IS NULL OR octet_length(token_hash)=32);
  END IF;
END;
$constraints$;

CREATE INDEX IF NOT EXISTS vortex_kds_tv_pairings_pending_idx
  ON public.vortex_kds_tv_pairings(expires_at)
  WHERE approved_at IS NULL AND consumed_at IS NULL;

-- A TV inicia o pareamento sem informar store_id.
-- O segredo temporário é protegido com bcrypt; o PIN não fica em texto puro nem em SHA-256 simples.
-- p_token_hash é SHA-256 da credencial aleatória de 256 bits criada pela própria TV.
CREATE OR REPLACE FUNCTION public.rpc_start_kds_tv_pairing(
  p_pairing_id uuid,
  p_pairing_type text,
  p_pairing_secret text,
  p_token_hash bytea
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, public, extensions, auth
AS $function$
DECLARE
  v_pending_count integer;
  v_expires_at timestamptz;
  v_pairing_hash text;
BEGIN
  IF p_pairing_id IS NULL
     OR p_pairing_type IS NULL
     OR p_pairing_type NOT IN ('qr','pin')
     OR p_pairing_secret IS NULL
     OR length(p_pairing_secret)>80
     OR (p_pairing_type='pin' AND p_pairing_secret !~ '^[0-9]{6}$')
     OR (p_pairing_type='qr' AND p_pairing_secret !~ '^[0-9a-fA-F]{64}$')
     OR p_token_hash IS NULL
     OR octet_length(p_token_hash)<>32 THEN
    RETURN jsonb_build_object('success',false,'reason','invalid_request');
  END IF;

  -- Limita a quantidade global de desafios pendentes e serializa a contagem.
  PERFORM pg_advisory_xact_lock(73421011,1);

  DELETE FROM public.vortex_kds_tv_pairings
  WHERE expires_at < now() - interval '1 day';

  SELECT count(*)::integer
  INTO v_pending_count
  FROM public.vortex_kds_tv_pairings
  WHERE approved_at IS NULL
    AND consumed_at IS NULL
    AND expires_at > now();

  IF v_pending_count >= 1000 THEN
    RETURN jsonb_build_object('success',false,'reason','pairing_capacity_reached');
  END IF;

  v_expires_at := now() + interval '5 minutes';
  v_pairing_hash := extensions.crypt(p_pairing_secret, extensions.gen_salt('bf',12));

  INSERT INTO public.vortex_kds_tv_pairings (
    id,
    store_id,
    pairing_type,
    pairing_hash,
    device_name,
    profile,
    created_by,
    expires_at,
    attempts,
    max_attempts,
    token_hash
  )
  VALUES (
    p_pairing_id,
    NULL,
    p_pairing_type,
    convert_to(v_pairing_hash,'UTF8'),
    'TV aguardando pareamento',
    'public',
    NULL,
    v_expires_at,
    0,
    5,
    p_token_hash
  );

  RETURN jsonb_build_object(
    'success',true,
    'pairing_id',p_pairing_id,
    'expires_at',v_expires_at,
    'expires_in_seconds',300
  );
END;
$function$;

-- A TV consulta somente o estado do próprio desafio.
-- O ID é UUID aleatório; a resposta não contém dados da loja nem credenciais.
CREATE OR REPLACE FUNCTION public.rpc_get_kds_tv_pairing_status(
  p_pairing_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $function$
DECLARE
  v_pairing public.vortex_kds_tv_pairings%ROWTYPE;
BEGIN
  IF p_pairing_id IS NULL THEN
    RETURN jsonb_build_object('status','invalid');
  END IF;

  SELECT *
  INTO v_pairing
  FROM public.vortex_kds_tv_pairings
  WHERE id=p_pairing_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('status','invalid');
  END IF;

  IF v_pairing.approved_at IS NOT NULL THEN
    RETURN jsonb_build_object('status','approved');
  END IF;

  IF v_pairing.attempts >= v_pairing.max_attempts
     OR v_pairing.consumed_at IS NOT NULL THEN
    RETURN jsonb_build_object('status','locked');
  END IF;

  IF v_pairing.expires_at <= now() THEN
    RETURN jsonb_build_object('status','expired');
  END IF;

  RETURN jsonb_build_object(
    'status','pending',
    'expires_at',v_pairing.expires_at
  );
END;
$function$;

-- O KDS autenticado aprova o desafio e vincula a TV à loja autorizada.
-- Tentativas incorretas são contadas por desafio; o segredo é verificado com bcrypt.
CREATE OR REPLACE FUNCTION public.rpc_approve_kds_tv_pairing(
  p_store_id uuid,
  p_pairing_id uuid,
  p_pairing_secret text,
  p_device_name text,
  p_profile text
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, public, extensions, auth
AS $function$
DECLARE
  v_pairing public.vortex_kds_tv_pairings%ROWTYPE;
  v_device_id uuid;
  v_attempts integer;
  v_max_attempts integer;
  v_stored_hash text;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Autenticação necessária.';
  END IF;

  IF p_store_id IS NULL
     OR NOT public.vortex_user_has_store_access(p_store_id)
     OR NOT public.vortex_user_has_permission(p_store_id,'kds.view') THEN
    RAISE EXCEPTION 'Você não tem permissão para parear uma TV neste estabelecimento.';
  END IF;

  IF p_pairing_id IS NULL
     OR p_pairing_secret IS NULL
     OR length(p_pairing_secret)>80
     OR p_profile IS NULL
     OR p_profile NOT IN ('public','kitchen')
     OR length(btrim(COALESCE(p_device_name,''))) NOT BETWEEN 1 AND 80 THEN
    RETURN jsonb_build_object('success',false,'reason','invalid_request');
  END IF;

  SELECT *
  INTO v_pairing
  FROM public.vortex_kds_tv_pairings
  WHERE id=p_pairing_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success',false,'reason','invalid_code');
  END IF;

  IF v_pairing.approved_at IS NOT NULL THEN
    RETURN jsonb_build_object('success',false,'reason','already_approved');
  END IF;

  IF v_pairing.expires_at <= now() THEN
    RETURN jsonb_build_object('success',false,'reason','expired');
  END IF;

  IF v_pairing.consumed_at IS NOT NULL
     OR v_pairing.attempts >= v_pairing.max_attempts THEN
    RETURN jsonb_build_object('success',false,'reason','attempts_exceeded');
  END IF;

  v_stored_hash := convert_from(v_pairing.pairing_hash,'UTF8');

  IF (
       (v_pairing.pairing_type='pin' AND p_pairing_secret !~ '^[0-9]{6}$')
       OR (v_pairing.pairing_type='qr' AND p_pairing_secret !~ '^[0-9a-fA-F]{64}$')
       OR extensions.crypt(p_pairing_secret,v_stored_hash) IS DISTINCT FROM v_stored_hash
     ) THEN
    UPDATE public.vortex_kds_tv_pairings
    SET
      attempts=attempts+1,
      consumed_at=CASE
        WHEN attempts+1 >= max_attempts THEN now()
        ELSE consumed_at
      END
    WHERE id=p_pairing_id
    RETURNING attempts,max_attempts INTO v_attempts,v_max_attempts;

    RETURN jsonb_build_object(
      'success',false,
      'reason',CASE WHEN v_attempts >= v_max_attempts THEN 'attempts_exceeded' ELSE 'invalid_code' END,
      'attempts_remaining',GREATEST(v_max_attempts-v_attempts,0)
    );
  END IF;

  IF v_pairing.token_hash IS NULL OR octet_length(v_pairing.token_hash)<>32 THEN
    RAISE EXCEPTION 'A credencial temporária da TV é inválida.';
  END IF;

  INSERT INTO public.vortex_kds_tv_devices (
    store_id,
    device_name,
    profile,
    token_hash,
    created_by
  )
  VALUES (
    p_store_id,
    btrim(p_device_name),
    p_profile,
    v_pairing.token_hash,
    auth.uid()
  )
  RETURNING id INTO v_device_id;

  UPDATE public.vortex_kds_tv_pairings
  SET
    store_id=p_store_id,
    device_name=btrim(p_device_name),
    profile=p_profile,
    created_by=auth.uid(),
    approved_at=now(),
    consumed_at=now(),
    device_id=v_device_id
  WHERE id=p_pairing_id;

  RETURN jsonb_build_object(
    'success',true,
    'device_id',v_device_id,
    'device_name',btrim(p_device_name),
    'profile',p_profile
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_start_kds_tv_pairing(uuid,text,text,bytea) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_start_kds_tv_pairing(uuid,text,text,bytea) TO anon, authenticated;

REVOKE ALL ON FUNCTION public.rpc_get_kds_tv_pairing_status(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_get_kds_tv_pairing_status(uuid) TO anon, authenticated;

REVOKE ALL ON FUNCTION public.rpc_approve_kds_tv_pairing(uuid,uuid,text,text,text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_approve_kds_tv_pairing(uuid,uuid,text,text,text) TO authenticated;

COMMIT;
