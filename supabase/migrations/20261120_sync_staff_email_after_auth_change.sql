-- Sincroniza o e-mail autenticado com o cadastro da equipe após a confirmação no Supabase Auth.
BEGIN;

CREATE OR REPLACE FUNCTION public.rpc_sync_my_auth_email()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_email text;
  v_store_id uuid;
  v_staff_record_id text;
  v_rows integer := 0;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Sessão inválida.';
  END IF;

  SELECT lower(u.email) INTO v_email
  FROM auth.users AS u
  WHERE u.id = v_user_id;

  IF NULLIF(v_email, '') IS NULL THEN
    RAISE EXCEPTION 'Não foi possível identificar o e-mail confirmado da conta.';
  END IF;

  SELECT m.store_id, m.staff_record_id
    INTO v_store_id, v_staff_record_id
  FROM public.vortex_store_members AS m
  WHERE m.user_id = v_user_id AND m.status = 'active'
  LIMIT 1;

  IF v_store_id IS NULL THEN
    RAISE EXCEPTION 'Não existe vínculo ativo com um estabelecimento.';
  END IF;

  IF v_staff_record_id IS NOT NULL THEN
    UPDATE public.vortex_store_documents AS d
    SET data = (
      SELECT jsonb_agg(
        CASE
          WHEN item->>'id' = v_staff_record_id
            THEN jsonb_set(item, '{email}', to_jsonb(v_email), true)
          ELSE item
        END
        ORDER BY ordinal
      )
      FROM jsonb_array_elements(d.data) WITH ORDINALITY AS staff(item, ordinal)
    )
    WHERE d.store_id = v_store_id
      AND d.document_key = 'staff'
      AND jsonb_typeof(d.data) = 'array'
      AND EXISTS (
        SELECT 1
        FROM jsonb_array_elements(d.data) AS staff(item)
        WHERE item->>'id' = v_staff_record_id
      );
    GET DIAGNOSTICS v_rows = ROW_COUNT;
  END IF;

  INSERT INTO public.vortex_account_security_events(store_id, user_id, event_type, details)
  VALUES (
    v_store_id,
    v_user_id,
    'account_email_changed',
    jsonb_build_object('email', v_email)
  );

  RETURN jsonb_build_object(
    'success', true,
    'staff_record_synced', (v_staff_record_id IS NULL OR v_rows > 0)
  );
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_sync_my_auth_email() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_sync_my_auth_email() TO authenticated, service_role;

COMMIT;
