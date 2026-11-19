-- Corrige a hierarquia de convites: proprietário é autoridade máxima,
-- inclusive para permissões adicionadas ao catálogo depois da criação do perfil.
-- Não altera permissões dos perfis convidados nem relaxa as regras de gerente/admin.
BEGIN;

CREATE OR REPLACE FUNCTION public.rpc_admin_finalize_staff_invitation(
  p_store_id uuid,
  p_target_user_id uuid,
  p_actor_user_id uuid,
  p_staff_record_id text,
  p_email text,
  p_profile_key text,
  p_display_name text,
  p_invited_at timestamptz DEFAULT now()
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $function$
DECLARE
  v_staff_document jsonb;
  v_staff jsonb;
  v_updated_data jsonb;
  v_member public.vortex_store_members%ROWTYPE;
  v_actor public.vortex_store_members%ROWTYPE;
  v_can_invite boolean := false;
  v_has_member boolean := false;
BEGIN
  IF p_store_id IS NULL OR p_target_user_id IS NULL OR p_actor_user_id IS NULL
     OR NULLIF(BTRIM(p_staff_record_id),'') IS NULL
     OR NULLIF(BTRIM(p_display_name),'') IS NULL
     OR NULLIF(BTRIM(p_email),'') IS NULL
     OR p_profile_key IS NULL
     OR p_profile_key NOT IN ('administrator','manager','attendant','kitchen','delivery') THEN
    RAISE EXCEPTION 'Dados do convite inválidos.';
  END IF;

  SELECT * INTO v_actor
  FROM public.vortex_store_members
  WHERE store_id=p_store_id AND user_id=p_actor_user_id AND status='active'
  FOR SHARE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'O responsável pelo convite não possui vínculo ativo nesta loja.';
  END IF;

  IF v_actor.role='owner' OR v_actor.profile_key='owner' THEN
    v_can_invite := true;
  ELSE
    SELECT COALESCE(
      (SELECT mp.allowed FROM public.vortex_member_permissions mp
       WHERE mp.store_id=p_store_id AND mp.user_id=p_actor_user_id
         AND mp.permission_key='team.invite'),
      (SELECT pp.allowed FROM public.vortex_profile_permissions pp
       WHERE pp.profile_key=v_actor.profile_key AND pp.permission_key='team.invite'),
      false
    ) INTO v_can_invite;
  END IF;

  IF NOT v_can_invite THEN
    RAISE EXCEPTION 'O responsável não possui permissão para convidar funcionários.';
  END IF;

  IF p_profile_key='administrator' AND NOT (v_actor.role='owner' OR v_actor.profile_key='owner') THEN
    RAISE EXCEPTION 'Somente o proprietário pode convidar administradores.';
  END IF;
  IF p_profile_key='manager'
     AND NOT (v_actor.role='owner' OR v_actor.profile_key IN ('owner','administrator')) THEN
    RAISE EXCEPTION 'O responsável não pode convidar gerentes.';
  END IF;

  -- Proprietário é a autoridade máxima. Para os demais perfis, mantém-se
  -- a comparação efetiva entre permissões individuais e permissões-base.
  IF NOT (v_actor.role='owner' OR v_actor.profile_key='owner') AND EXISTS (
    SELECT 1
    FROM public.vortex_profile_permissions target_perm
    WHERE target_perm.profile_key=p_profile_key
      AND target_perm.allowed=true
      AND NOT COALESCE(
        (SELECT mp.allowed FROM public.vortex_member_permissions mp
         WHERE mp.store_id=p_store_id AND mp.user_id=p_actor_user_id
           AND mp.permission_key=target_perm.permission_key),
        (SELECT pp.allowed FROM public.vortex_profile_permissions pp
         WHERE pp.profile_key=v_actor.profile_key
           AND pp.permission_key=target_perm.permission_key),
        false
      )
  ) THEN
    RAISE EXCEPTION 'O perfil selecionado contém permissões superiores às do responsável.';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.vortex_store_members
    WHERE user_id=p_target_user_id AND store_id<>p_store_id
  ) THEN
    RAISE EXCEPTION 'Esta conta já está vinculada a outro estabelecimento.';
  END IF;

  SELECT data INTO v_staff_document
  FROM public.vortex_store_documents
  WHERE store_id=p_store_id AND document_key='staff'
  FOR UPDATE;

  IF NOT FOUND OR jsonb_typeof(v_staff_document) IS DISTINCT FROM 'array' THEN
    RAISE EXCEPTION 'Cadastro da equipe não encontrado ou inválido.';
  END IF;

  SELECT x.item INTO v_staff
  FROM jsonb_array_elements(v_staff_document) AS x(item)
  WHERE x.item->>'id'=p_staff_record_id
  LIMIT 1;

  IF v_staff IS NULL THEN
    RAISE EXCEPTION 'Colaborador não encontrado nesta loja.';
  END IF;
  IF lower(COALESCE(v_staff->>'status','ativo'))<>'ativo' THEN
    RAISE EXCEPTION 'O cadastro do colaborador está inativo.';
  END IF;
  IF lower(COALESCE(v_staff->>'email',''))<>lower(BTRIM(p_email)) THEN
    RAISE EXCEPTION 'O e-mail do convite não corresponde ao cadastro salvo.';
  END IF;
  IF NULLIF(v_staff->>'authUserId','') IS NOT NULL
     AND v_staff->>'authUserId'<>p_target_user_id::text THEN
    RAISE EXCEPTION 'Este cadastro já está vinculado a outra conta.';
  END IF;

  SELECT * INTO v_member
  FROM public.vortex_store_members
  WHERE store_id=p_store_id AND user_id=p_target_user_id
  FOR UPDATE;
  v_has_member := FOUND;

  IF v_has_member AND (
    v_member.role='owner'
    OR NULLIF(v_member.staff_record_id,'') IS DISTINCT FROM p_staff_record_id
  ) THEN
    RAISE EXCEPTION 'Esta conta já está vinculada a outro cadastro ou é a conta do proprietário.';
  END IF;

  INSERT INTO public.vortex_store_members(
    store_id,user_id,role,status,profile_key,display_name,staff_record_id,
    invitation_status,invited_at,invited_by
  ) VALUES (
    p_store_id,p_target_user_id,'employee','inactive',p_profile_key,
    BTRIM(p_display_name),p_staff_record_id,'pending',COALESCE(p_invited_at,now()),p_actor_user_id
  )
  ON CONFLICT (store_id,user_id) DO UPDATE SET
    role='employee',
    status='inactive',
    profile_key=EXCLUDED.profile_key,
    display_name=EXCLUDED.display_name,
    staff_record_id=EXCLUDED.staff_record_id,
    invitation_status='pending',
    invited_at=EXCLUDED.invited_at,
    invited_by=EXCLUDED.invited_by;

  SELECT COALESCE(jsonb_agg(
    CASE WHEN item->>'id'=p_staff_record_id THEN
      jsonb_set(
        jsonb_set(
          jsonb_set(
            jsonb_set(item,'{email}',to_jsonb(lower(BTRIM(p_email))),true),
            '{authUserId}',to_jsonb(p_target_user_id::text),true
          ),
          '{profileKey}',to_jsonb(p_profile_key),true
        ),
        '{invitationStatus}',to_jsonb('pending'::text),true
      ) || jsonb_build_object('invitedAt',COALESCE(p_invited_at,now())::text)
    ELSE item END
    ORDER BY ord
  ),'[]'::jsonb) INTO v_updated_data
  FROM jsonb_array_elements(v_staff_document) WITH ORDINALITY AS rows(item,ord);

  UPDATE public.vortex_store_documents
  SET data=v_updated_data, updated_at=now()
  WHERE store_id=p_store_id AND document_key='staff';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Não foi possível sincronizar o cadastro da equipe.';
  END IF;

  INSERT INTO public.vortex_permission_audit_log(
    store_id,actor_user_id,target_user_id,event_type,details
  ) VALUES (
    p_store_id,p_actor_user_id,p_target_user_id,'staff_invited',
    jsonb_build_object(
      'staff_record_id',p_staff_record_id,
      'email',lower(BTRIM(p_email)),
      'profile_key',p_profile_key
    )
  );

  RETURN jsonb_build_object('success',true,'invitation_status','pending');
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_admin_finalize_staff_invitation(uuid,uuid,uuid,text,text,text,text,timestamptz)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_admin_finalize_staff_invitation(uuid,uuid,uuid,text,text,text,text,timestamptz)
  TO service_role;

COMMIT;
