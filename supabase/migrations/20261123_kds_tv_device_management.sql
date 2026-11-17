-- VORTEX FOOD: gerenciamento seguro de dispositivos de TV do KDS.
-- Lista e revoga somente TVs do estabelecimento ao qual o usuário tem acesso.
-- Não expõe token_hash nem permite acesso direto às tabelas.

BEGIN;

DO $preflight$
BEGIN
  IF to_regclass('public.vortex_kds_tv_devices') IS NULL THEN
    RAISE EXCEPTION 'Tabela public.vortex_kds_tv_devices não encontrada. Aplique as migrations anteriores de TV.';
  END IF;
  IF to_regprocedure('public.vortex_user_has_store_access(uuid)') IS NULL
     OR to_regprocedure('public.vortex_user_has_permission(uuid,text)') IS NULL THEN
    RAISE EXCEPTION 'Funções de autorização do estabelecimento não encontradas.';
  END IF;
END;
$preflight$;

CREATE OR REPLACE FUNCTION public.rpc_list_kds_tv_devices(p_store_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $function$
DECLARE
  v_devices jsonb;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Autenticação necessária.';
  END IF;

  IF p_store_id IS NULL
     OR NOT public.vortex_user_has_store_access(p_store_id)
     OR NOT public.vortex_user_has_permission(p_store_id,'kds.view') THEN
    RAISE EXCEPTION 'Você não tem permissão para visualizar as TVs deste estabelecimento.';
  END IF;

  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'id',d.id,
        'device_name',d.device_name,
        'profile',d.profile,
        'created_at',d.created_at,
        'last_seen_at',d.last_seen_at,
        'is_active',d.is_active,
        'revoked_at',d.revoked_at,
        'connection_status',CASE
          WHEN d.last_seen_at >= now() - interval '45 seconds' THEN 'connected'
          ELSE 'disconnected'
        END
      )
      ORDER BY d.created_at DESC
    ),
    '[]'::jsonb
  )
  INTO v_devices
  FROM public.vortex_kds_tv_devices AS d
  WHERE d.store_id=p_store_id
    AND d.is_active=true
    AND d.revoked_at IS NULL;

  RETURN jsonb_build_object('success',true,'devices',v_devices);
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpc_revoke_kds_tv_device(
  p_store_id uuid,
  p_device_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $function$
DECLARE
  v_device_id uuid;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Autenticação necessária.';
  END IF;

  IF p_store_id IS NULL
     OR NOT public.vortex_user_has_store_access(p_store_id)
     OR NOT public.vortex_user_has_permission(p_store_id,'kds.view') THEN
    RAISE EXCEPTION 'Você não tem permissão para gerenciar TVs deste estabelecimento.';
  END IF;

  IF p_device_id IS NULL THEN
    RETURN jsonb_build_object('success',false,'reason','invalid_device');
  END IF;

  UPDATE public.vortex_kds_tv_devices AS d
  SET is_active=false,
      revoked_at=COALESCE(d.revoked_at,now())
  WHERE d.id=p_device_id
    AND d.store_id=p_store_id
    AND d.is_active=true
    AND d.revoked_at IS NULL
  RETURNING d.id INTO v_device_id;

  IF v_device_id IS NULL THEN
    RETURN jsonb_build_object('success',false,'reason','device_not_found_or_inactive');
  END IF;

  RETURN jsonb_build_object('success',true,'device_id',v_device_id);
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_list_kds_tv_devices(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_list_kds_tv_devices(uuid) TO authenticated;

REVOKE ALL ON FUNCTION public.rpc_revoke_kds_tv_device(uuid,uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_revoke_kds_tv_device(uuid,uuid) TO authenticated;

COMMIT;
