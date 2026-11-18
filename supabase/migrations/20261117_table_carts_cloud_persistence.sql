-- Comandas de mesa persistidas por estabelecimento.
-- Não migra nem apaga os caches locais existentes; o cliente fará a sincronização controlada.
BEGIN;

CREATE TABLE IF NOT EXISTS public.vortex_table_carts (
  store_id uuid NOT NULL REFERENCES public.vortex_stores(id) ON DELETE CASCADE,
  table_number integer NOT NULL CHECK (table_number BETWEEN 1 AND 200),
  cart_data jsonb NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT now(),
  updated_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  CONSTRAINT vortex_table_carts_pkey PRIMARY KEY (store_id, table_number),
  CONSTRAINT vortex_table_carts_data_object CHECK (jsonb_typeof(cart_data) = 'object')
);

ALTER TABLE public.vortex_table_carts ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.vortex_table_carts FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.rpc_get_table_carts()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $function$
DECLARE
  v_store_id uuid;
  v_count integer;
  v_result jsonb;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Autenticação necessária.';
  END IF;

  SELECT COUNT(*), MIN(store_id::text)::uuid
  INTO v_count, v_store_id
  FROM public.vortex_store_members
  WHERE user_id=auth.uid() AND status='active';

  IF v_count<>1 OR v_store_id IS NULL THEN
    RAISE EXCEPTION 'Não foi possível identificar uma única loja ativa.';
  END IF;
  IF NOT public.vortex_user_has_permission(v_store_id,'tables.view') THEN
    RAISE EXCEPTION 'Seu perfil não pode consultar comandas de mesa.';
  END IF;

  SELECT COALESCE(jsonb_object_agg(table_number::text,cart_data),'{}'::jsonb)
  INTO v_result
  FROM public.vortex_table_carts
  WHERE store_id=v_store_id;

  RETURN v_result;
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpc_save_table_cart(
  p_table_number integer,
  p_cart jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $function$
DECLARE
  v_store_id uuid;
  v_count integer;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Autenticação necessária.';
  END IF;
  IF p_table_number IS NULL OR p_table_number NOT BETWEEN 1 AND 200 THEN
    RAISE EXCEPTION 'Número de mesa inválido.';
  END IF;

  SELECT COUNT(*), MIN(store_id::text)::uuid
  INTO v_count, v_store_id
  FROM public.vortex_store_members
  WHERE user_id=auth.uid() AND status='active';

  IF v_count<>1 OR v_store_id IS NULL THEN
    RAISE EXCEPTION 'Não foi possível identificar uma única loja ativa.';
  END IF;

  IF p_cart IS NULL THEN
    IF NOT public.vortex_user_has_permission(v_store_id,'tables.close') THEN
      RAISE EXCEPTION 'Seu perfil não pode liberar uma comanda.';
    END IF;
    DELETE FROM public.vortex_table_carts
    WHERE store_id=v_store_id AND table_number=p_table_number;
    RETURN jsonb_build_object('success',true,'deleted',true);
  END IF;

  IF jsonb_typeof(p_cart) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'Dados da comanda inválidos.';
  END IF;
  IF NOT (
    public.vortex_user_has_permission(v_store_id,'tables.open')
    OR public.vortex_user_has_permission(v_store_id,'tables.close')
  ) THEN
    RAISE EXCEPTION 'Seu perfil não pode atualizar comandas.';
  END IF;

  INSERT INTO public.vortex_table_carts(store_id,table_number,cart_data,updated_at,updated_by)
  VALUES(v_store_id,p_table_number,p_cart,now(),auth.uid())
  ON CONFLICT(store_id,table_number) DO UPDATE
  SET cart_data=EXCLUDED.cart_data,updated_at=now(),updated_by=auth.uid();

  RETURN jsonb_build_object('success',true,'deleted',false);
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_get_table_carts() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_get_table_carts() TO authenticated;
REVOKE ALL ON FUNCTION public.rpc_save_table_cart(integer,jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_save_table_cart(integer,jsonb) TO authenticated;

COMMIT;
