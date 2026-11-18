-- VORTEX FOOD: estrutura inicial de rotas e operação do motoboy.
-- A migração é aditiva: não apaga pedidos, documentos, rotas antigas ou históricos.
-- Executar manualmente no Supabase somente após revisão do responsável pelo banco.

BEGIN;

-- 1) Permissões específicas do aplicativo do motoboy.
INSERT INTO public.vortex_permission_catalog(permission_key,module_key,action_key,label,description)
VALUES
  ('delivery.route_view','delivery','route_view','Visualizar minhas rotas','Consultar somente rotas e paradas atribuídas à própria conta.'),
  ('delivery.route_start','delivery','route_start','Iniciar rota','Registrar a saída para uma rota atribuída.'),
  ('delivery.occurrence_report','delivery','occurrence_report','Informar ocorrência','Registrar problemas durante uma entrega atribuída.'),
  ('delivery.presence_update','delivery','presence_update','Atualizar disponibilidade','Informar disponibilidade operacional do motoboy.')
ON CONFLICT (permission_key) DO UPDATE
SET module_key=EXCLUDED.module_key, action_key=EXCLUDED.action_key,
    label=EXCLUDED.label, description=EXCLUDED.description;

INSERT INTO public.vortex_profile_permissions(profile_key,permission_key,allowed)
VALUES
  ('delivery','delivery.route_view',true),
  ('delivery','delivery.route_start',true),
  ('delivery','delivery.occurrence_report',true),
  ('delivery','delivery.presence_update',true),
  ('administrator','delivery.route_view',true),
  ('administrator','delivery.route_start',true),
  ('administrator','delivery.occurrence_report',true),
  ('administrator','delivery.presence_update',true),
  ('manager','delivery.route_view',true),
  ('manager','delivery.route_start',true),
  ('manager','delivery.occurrence_report',true),
  ('manager','delivery.presence_update',true),
  ('attendant','delivery.route_view',true)
ON CONFLICT (profile_key,permission_key) DO UPDATE SET allowed=EXCLUDED.allowed;

-- 2) Rotas. Uma rota é uma entidade própria, independente do status do pedido.
CREATE TABLE IF NOT EXISTS public.vortex_delivery_routes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  store_id uuid NOT NULL REFERENCES public.vortex_stores(id) ON DELETE CASCADE,
  courier_user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  status text NOT NULL DEFAULT 'assigned'
    CHECK (status IN ('assigned','in_route','completed','cancelled')),
  route_version integer NOT NULL DEFAULT 1 CHECK (route_version > 0),
  assigned_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  assigned_at timestamptz NOT NULL DEFAULT now(),
  started_at timestamptz,
  completed_at timestamptz,
  cancelled_at timestamptz,
  notes text NOT NULL DEFAULT '',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT vortex_delivery_routes_store_id_id_key UNIQUE (store_id,id)
);

CREATE INDEX IF NOT EXISTS vortex_delivery_routes_courier_status_idx
  ON public.vortex_delivery_routes(store_id,courier_user_id,status,assigned_at DESC);
CREATE INDEX IF NOT EXISTS vortex_delivery_routes_store_status_idx
  ON public.vortex_delivery_routes(store_id,status,assigned_at DESC);

-- Um motoboy conduz uma rota ativa por vez; novas rotas aguardam a anterior.
CREATE UNIQUE INDEX IF NOT EXISTS vortex_delivery_routes_one_active_per_courier
  ON public.vortex_delivery_routes(store_id,courier_user_id)
  WHERE status IN ('assigned','in_route');

-- 3) Paradas da rota. A ordem original é preservada e não depende do navegador.
CREATE TABLE IF NOT EXISTS public.vortex_delivery_route_stops (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  store_id uuid NOT NULL,
  route_id uuid NOT NULL,
  order_id text NOT NULL,
  sequence_number integer NOT NULL CHECK (sequence_number > 0),
  status text NOT NULL DEFAULT 'assigned'
    CHECK (status IN ('assigned','in_progress','occurrence','delivered','returned','cancelled')),
  occurrence_type text,
  occurrence_notes text NOT NULL DEFAULT '',
  occurrence_at timestamptz,
  promised_delivery_at timestamptz,
  started_at timestamptz,
  delivered_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT vortex_delivery_route_stops_route_fkey
    FOREIGN KEY (store_id,route_id)
    REFERENCES public.vortex_delivery_routes(store_id,id) ON DELETE CASCADE,
  CONSTRAINT vortex_delivery_route_stops_sequence_key UNIQUE (store_id,route_id,sequence_number),
  CONSTRAINT vortex_delivery_route_stops_order_key UNIQUE (store_id,route_id,order_id)
);

CREATE INDEX IF NOT EXISTS vortex_delivery_route_stops_order_idx
  ON public.vortex_delivery_route_stops(store_id,order_id,status);
CREATE INDEX IF NOT EXISTS vortex_delivery_route_stops_route_sequence_idx
  ON public.vortex_delivery_route_stops(store_id,route_id,sequence_number);

-- Impede que um pedido esteja em duas rotas ativas ao mesmo tempo.
CREATE UNIQUE INDEX IF NOT EXISTS vortex_delivery_route_stops_one_active_route_per_order
  ON public.vortex_delivery_route_stops(store_id,order_id)
  WHERE status IN ('assigned','in_progress','occurrence');

-- 4) Eventos imutáveis para auditoria operacional.
CREATE TABLE IF NOT EXISTS public.vortex_delivery_route_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  store_id uuid NOT NULL,
  route_id uuid NOT NULL,
  stop_id uuid REFERENCES public.vortex_delivery_route_stops(id) ON DELETE SET NULL,
  order_id text,
  actor_user_id uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  event_type text NOT NULL,
  details jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT vortex_delivery_route_events_route_fkey
    FOREIGN KEY (store_id,route_id)
    REFERENCES public.vortex_delivery_routes(store_id,id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS vortex_delivery_route_events_route_created_idx
  ON public.vortex_delivery_route_events(store_id,route_id,created_at DESC);

-- 5) Presença operacional do motoboy.
CREATE TABLE IF NOT EXISTS public.vortex_delivery_courier_presence (
  store_id uuid NOT NULL REFERENCES public.vortex_stores(id) ON DELETE CASCADE,
  courier_user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  status text NOT NULL DEFAULT 'unavailable'
    CHECK (status IN ('available','in_route','paused','unavailable')),
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (store_id,courier_user_id)
);

-- Todas as tabelas novas são privadas. A leitura e escrita acontecem somente por RPC.
ALTER TABLE public.vortex_delivery_routes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.vortex_delivery_route_stops ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.vortex_delivery_route_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.vortex_delivery_courier_presence ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.vortex_delivery_routes,
  public.vortex_delivery_route_stops,
  public.vortex_delivery_route_events,
  public.vortex_delivery_courier_presence
FROM PUBLIC, anon, authenticated;

-- 6) Criação e atribuição atômica de uma rota pelo despacho.
CREATE OR REPLACE FUNCTION public.rpc_create_delivery_route(
  p_store_id uuid,
  p_courier_user_id uuid,
  p_order_ids text[]
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $function$
DECLARE
  v_route_id uuid;
  v_courier_name text;
  v_order_count integer;
  v_valid_count integer;
  v_order_id text;
  v_code text;
  v_token text;
  v_random bytea;
  v_number bigint;
  v_attempt integer;
  v_has_code boolean;
BEGIN
  IF auth.uid() IS NULL
     OR NOT public.vortex_user_has_permission(p_store_id,'delivery.assign')
     OR NOT public.vortex_user_has_permission(p_store_id,'delivery.dispatch') THEN
    RAISE EXCEPTION 'Seu perfil não pode criar e atribuir rotas.';
  END IF;

  IF p_courier_user_id IS NULL
     OR p_order_ids IS NULL
     OR cardinality(p_order_ids) < 1
     OR cardinality(p_order_ids) > 20
     OR array_position(p_order_ids,NULL) IS NOT NULL
     OR EXISTS (SELECT 1 FROM unnest(p_order_ids) AS u(order_id) GROUP BY u.order_id HAVING count(*) > 1) THEN
    RAISE EXCEPTION 'Selecione um motoboy e entre 1 e 20 pedidos diferentes.';
  END IF;

  SELECT COALESCE(NULLIF(display_name,''),'Motoboy')
    INTO v_courier_name
  FROM public.vortex_store_members
  WHERE store_id=p_store_id AND user_id=p_courier_user_id
    AND status='active' AND profile_key='delivery';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'O motoboy selecionado não possui uma conta ativa nesta loja.';
  END IF;

  -- Bloqueia os pedidos em ordem estável para evitar atribuições concorrentes.
  PERFORM 1
  FROM public.vortex_kds_orders o
  WHERE o.store_id=p_store_id AND o.id=ANY(p_order_ids)
  ORDER BY o.id
  FOR UPDATE;

  SELECT count(*) INTO v_order_count
  FROM public.vortex_kds_orders o
  WHERE o.store_id=p_store_id AND o.id=ANY(p_order_ids)
    AND COALESCE(o.origin,'') ILIKE '%Delivery%'
    AND o.status NOT IN ('finished','cancelled');

  IF v_order_count <> cardinality(p_order_ids) THEN
    RAISE EXCEPTION 'Um ou mais pedidos não existem, não são delivery ou já foram encerrados.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.vortex_kds_orders o
    WHERE o.store_id=p_store_id AND o.id=ANY(p_order_ids)
      AND o.courier_member_id IS NOT NULL
      AND o.courier_member_id<>p_courier_user_id
  ) THEN
    RAISE EXCEPTION 'Um ou mais pedidos já estão atribuídos a outro motoboy. Faça a transferência pela operação de despacho.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.vortex_delivery_route_stops s
    WHERE s.store_id=p_store_id AND s.order_id=ANY(p_order_ids)
      AND s.status IN ('assigned','in_progress','occurrence')
  ) THEN
    RAISE EXCEPTION 'Um ou mais pedidos já pertencem a uma rota ativa.';
  END IF;

  INSERT INTO public.vortex_delivery_routes(store_id,courier_user_id,status,assigned_by)
  VALUES (p_store_id,p_courier_user_id,'assigned',auth.uid())
  RETURNING id INTO v_route_id;

  INSERT INTO public.vortex_delivery_route_stops(store_id,route_id,order_id,sequence_number)
  SELECT p_store_id,v_route_id,x.order_id,x.ordinality::integer
  FROM unnest(p_order_ids) WITH ORDINALITY AS x(order_id,ordinality);

  UPDATE public.vortex_kds_orders
  SET courier_member_id=p_courier_user_id,
      courier=v_courier_name,
      updated_at=now()
  WHERE store_id=p_store_id AND id=ANY(p_order_ids);

  -- Preserva o código já emitido para pedidos públicos. Pedidos manuais recebem
  -- código próprio para o cliente; somente o despacho pode consultá-lo depois.
  FOREACH v_order_id IN ARRAY p_order_ids LOOP
    SELECT EXISTS (
      SELECT 1 FROM public.vortex_delivery_verifications
      WHERE store_id=p_store_id AND order_id=v_order_id
        AND is_active=true AND consumed_at IS NULL AND expires_at>now()
    ) INTO v_has_code;

    IF NOT v_has_code THEN
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
            p_store_id,v_order_id,v_code,md5(v_token),0,NULL,
            now()+interval '48 hours',NULL,true,now()
          )
          ON CONFLICT (store_id,order_id) DO UPDATE
          SET code=EXCLUDED.code,access_token_hash=EXCLUDED.access_token_hash,
              attempt_count=0,locked_until=NULL,expires_at=EXCLUDED.expires_at,
              consumed_at=NULL,is_active=true,created_at=now();
          v_has_code := true;
          EXIT;
        EXCEPTION WHEN unique_violation THEN
          v_has_code := false;
        END;
      END LOOP;

      IF NOT v_has_code THEN
        RAISE EXCEPTION 'Não foi possível gerar um código exclusivo para um dos pedidos.';
      END IF;
    END IF;
  END LOOP;

  INSERT INTO public.vortex_delivery_route_events(
    store_id,route_id,actor_user_id,event_type,details
  ) VALUES (
    p_store_id,v_route_id,auth.uid(),'route_assigned',
    jsonb_build_object('courier_user_id',p_courier_user_id,'order_ids',to_jsonb(p_order_ids))
  );

  INSERT INTO public.vortex_delivery_courier_presence(store_id,courier_user_id,status,updated_at)
  VALUES (p_store_id,p_courier_user_id,'available',now())
  ON CONFLICT (store_id,courier_user_id) DO NOTHING;

  RETURN jsonb_build_object('success',true,'route_id',v_route_id,'status','assigned','order_count',cardinality(p_order_ids));
END;
$function$;

-- 7) Consulta restrita às rotas do próprio motoboy.
CREATE OR REPLACE FUNCTION public.rpc_get_my_delivery_routes(p_store_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $function$
DECLARE
  v_result jsonb;
BEGIN
  IF auth.uid() IS NULL
     OR NOT public.vortex_user_has_permission(p_store_id,'delivery.route_view') THEN
    RAISE EXCEPTION 'Seu perfil não pode consultar o painel de rotas.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.vortex_store_members
    WHERE store_id=p_store_id AND user_id=auth.uid()
      AND status='active' AND profile_key='delivery'
  ) THEN
    RAISE EXCEPTION 'Esta operação é exclusiva da conta de motoboy.';
  END IF;

  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'id',r.id,'status',r.status,'route_version',r.route_version,
      'assigned_at',r.assigned_at,'started_at',r.started_at,
      'completed_at',r.completed_at,'notes',r.notes,
      'stops',COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'stop_id',s.id,'order_id',s.order_id,
          'sequence_number',s.sequence_number,'stop_status',s.status,
          'occurrence_type',s.occurrence_type,'occurrence_notes',s.occurrence_notes,
          'promised_delivery_at',s.promised_delivery_at,'started_at',s.started_at,'delivered_at',s.delivered_at,
          'display_id',o."displayId",
          'customer_name',regexp_replace(COALESCE(o.client,''),' \([^()]*\)$',''),
          'customer_phone',COALESCE((regexp_match(COALESCE(o.client,''),'\(([^()]*)\)$'))[1],''),
          'address',o.address,'payment_method',o.payment,
          'amount_due',o.total,'cash_given',o.cashgiven,'change',o.change,
          'observation',o.observation,'order_status',o.status,
          'order_date',o.date,'order_time',o.time
        ) ORDER BY s.sequence_number)
        FROM public.vortex_delivery_route_stops s
        JOIN public.vortex_kds_orders o
          ON o.store_id=s.store_id AND o.id=s.order_id
        WHERE s.store_id=r.store_id AND s.route_id=r.id
      ),'[]'::jsonb)
    ) ORDER BY r.assigned_at DESC
  ),'[]'::jsonb)
  INTO v_result
  FROM public.vortex_delivery_routes r
  WHERE r.store_id=p_store_id
    AND r.courier_user_id=auth.uid()
    AND (r.status IN ('assigned','in_route') OR r.assigned_at>now()-interval '30 days');

  RETURN v_result;
END;
$function$;

-- Código do cliente: somente despacho autorizado pode consultá-lo para compartilhamento.
CREATE OR REPLACE FUNCTION public.rpc_get_delivery_route_codes(p_store_id uuid,p_route_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $function$
DECLARE
  v_result jsonb;
BEGIN
  IF auth.uid() IS NULL
     OR NOT public.vortex_user_has_permission(p_store_id,'delivery.dispatch') THEN
    RAISE EXCEPTION 'Somente a equipe autorizada pode consultar códigos para compartilhar com clientes.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.vortex_delivery_routes
    WHERE store_id=p_store_id AND id=p_route_id
      AND status IN ('assigned','in_route')
  ) THEN
    RAISE EXCEPTION 'Rota ativa não encontrada.';
  END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'order_id',s.order_id,
    'display_id',o."displayId",
    'customer_name',regexp_replace(COALESCE(o.client,''),' \\([^()]*\\)
    'customer_phone',COALESCE((regexp_match(COALESCE(o.client,''),'\\(([^()]*)\\)$'))[1],''),
    'code',v.code,
    'expires_at',v.expires_at
  ) ORDER BY s.sequence_number),'[]'::jsonb)
  INTO v_result
  FROM public.vortex_delivery_route_stops s
  JOIN public.vortex_kds_orders o
    ON o.store_id=s.store_id AND o.id=s.order_id
  LEFT JOIN public.vortex_delivery_verifications v
    ON v.store_id=s.store_id AND v.order_id=s.order_id
   AND v.is_active=true AND v.consumed_at IS NULL AND v.expires_at>now()
  WHERE s.store_id=p_store_id AND s.route_id=p_route_id
    AND s.status IN ('assigned','in_progress','occurrence');

  RETURN v_result;
END;
$function$;

-- 8) Início efetivo da rota. O relógio começa aqui, nunca na atribuição.
CREATE OR REPLACE FUNCTION public.rpc_start_delivery_route(p_store_id uuid,p_route_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $function$
DECLARE
  v_route public.vortex_delivery_routes%ROWTYPE;
  v_stop_count integer;
  v_invalid_count integer;
BEGIN
  IF auth.uid() IS NULL
     OR NOT public.vortex_user_has_permission(p_store_id,'delivery.route_start') THEN
    RAISE EXCEPTION 'Seu perfil não pode iniciar rotas.';
  END IF;

  SELECT * INTO v_route
  FROM public.vortex_delivery_routes
  WHERE store_id=p_store_id AND id=p_route_id
    AND courier_user_id=auth.uid()
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Esta rota não está atribuída à sua conta.';
  END IF;
  IF v_route.status<>'assigned' THEN
    RAISE EXCEPTION 'Somente uma rota aguardando saída pode ser iniciada.';
  END IF;

  SELECT count(*) INTO v_stop_count
  FROM public.vortex_delivery_route_stops s
  WHERE s.store_id=p_store_id AND s.route_id=p_route_id AND s.status='assigned';

  SELECT count(*) INTO v_invalid_count
  FROM public.vortex_delivery_route_stops s
  JOIN public.vortex_kds_orders o ON o.store_id=s.store_id AND o.id=s.order_id
  WHERE s.store_id=p_store_id AND s.route_id=p_route_id
    AND s.status='assigned' AND o.status IN ('finished','cancelled');

  IF v_stop_count=0 OR v_invalid_count>0 THEN
    RAISE EXCEPTION 'Esta rota não possui entregas pendentes válidas. Atualize a rota com o estabelecimento.';
  END IF;

  UPDATE public.vortex_delivery_routes
  SET status='in_route',started_at=now(),updated_at=now()
  WHERE store_id=p_store_id AND id=p_route_id;

  UPDATE public.vortex_delivery_route_stops
  SET status='in_progress',started_at=now(),updated_at=now()
  WHERE store_id=p_store_id AND route_id=p_route_id AND status='assigned';

  UPDATE public.vortex_kds_orders o
  SET status='delivering',updated_at=now()
  FROM public.vortex_delivery_route_stops s
  WHERE s.store_id=p_store_id AND s.route_id=p_route_id
    AND s.order_id=o.id AND o.store_id=s.store_id
    AND s.status='in_progress' AND o.status NOT IN ('finished','cancelled');

  UPDATE public.vortex_delivery_courier_presence
  SET status='in_route',updated_at=now()
  WHERE store_id=p_store_id AND courier_user_id=auth.uid();

  INSERT INTO public.vortex_delivery_route_events(store_id,route_id,actor_user_id,event_type,details)
  VALUES (p_store_id,p_route_id,auth.uid(),'route_started',jsonb_build_object('started_at',now()));

  RETURN jsonb_build_object('success',true,'route_id',p_route_id,'started_at',now());
END;
$function$;

-- 9) Registro de ocorrência sem concluir ou cancelar indevidamente o pedido.
CREATE OR REPLACE FUNCTION public.rpc_report_delivery_occurrence(
  p_store_id uuid,
  p_route_id uuid,
  p_order_id text,
  p_occurrence_type text,
  p_notes text DEFAULT ''
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $function$
DECLARE
  v_stop_id uuid;
BEGIN
  IF auth.uid() IS NULL
     OR NOT public.vortex_user_has_permission(p_store_id,'delivery.occurrence_report') THEN
    RAISE EXCEPTION 'Seu perfil não pode registrar ocorrências.';
  END IF;

  IF p_occurrence_type IS NULL OR p_occurrence_type NOT IN ('customer_absent','wrong_address','no_response','customer_refused','other')
     OR length(COALESCE(p_notes,''))>1000 THEN
    RAISE EXCEPTION 'Tipo ou descrição da ocorrência inválidos.';
  END IF;

  PERFORM 1 FROM public.vortex_delivery_routes
  WHERE store_id=p_store_id AND id=p_route_id
    AND courier_user_id=auth.uid() AND status='in_route'
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'A rota não está ativa ou não pertence à sua conta.';
  END IF;

  UPDATE public.vortex_delivery_route_stops
  SET status='occurrence',occurrence_type=p_occurrence_type,
      occurrence_notes=left(COALESCE(p_notes,''),1000),
      occurrence_at=now(),updated_at=now()
  WHERE store_id=p_store_id AND route_id=p_route_id
    AND order_id=p_order_id AND status='in_progress'
  RETURNING id INTO v_stop_id;

  IF v_stop_id IS NULL THEN
    RAISE EXCEPTION 'A parada não está pendente nesta rota.';
  END IF;

  INSERT INTO public.vortex_delivery_route_events(
    store_id,route_id,stop_id,order_id,actor_user_id,event_type,details
  ) VALUES (
    p_store_id,p_route_id,v_stop_id,p_order_id,auth.uid(),'delivery_occurrence',
    jsonb_build_object('type',p_occurrence_type,'notes',left(COALESCE(p_notes,''),1000))
  );

  RETURN jsonb_build_object('success',true,'stop_id',v_stop_id,'status','occurrence');
END;
$function$;

-- 10) Atualização da disponibilidade somente da própria conta de motoboy.
CREATE OR REPLACE FUNCTION public.rpc_set_delivery_courier_presence(
  p_store_id uuid,
  p_status text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $function$
BEGIN
  IF auth.uid() IS NULL
     OR NOT public.vortex_user_has_permission(p_store_id,'delivery.presence_update')
     OR NOT EXISTS (
       SELECT 1 FROM public.vortex_store_members
       WHERE store_id=p_store_id AND user_id=auth.uid()
         AND status='active' AND profile_key='delivery'
     ) THEN
    RAISE EXCEPTION 'Somente um motoboy ativo pode alterar a própria disponibilidade.';
  END IF;

  IF p_status IS NULL OR p_status NOT IN ('available','paused','unavailable') THEN
    RAISE EXCEPTION 'Situação de disponibilidade inválida.';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.vortex_delivery_routes
    WHERE store_id=p_store_id AND courier_user_id=auth.uid() AND status='in_route'
  ) AND p_status<>'available' THEN
    RAISE EXCEPTION 'Finalize ou resolva a rota ativa antes de ficar indisponível ou pausar.';
  END IF;

  INSERT INTO public.vortex_delivery_courier_presence(store_id,courier_user_id,status,updated_at)
  VALUES (p_store_id,auth.uid(),p_status,now())
  ON CONFLICT (store_id,courier_user_id)
  DO UPDATE SET status=EXCLUDED.status,updated_at=now();

  RETURN jsonb_build_object('success',true,'status',p_status);
END;
$function$;

-- 11) Sincroniza a confirmação já existente com a parada e o histórico da rota.
-- Mantém o contrato de retorno e a proteção contra tentativas incorretas.
CREATE OR REPLACE FUNCTION public.rpc_confirm_delivery_code(
  p_store_id uuid,p_order_id text,p_code text
)
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
  v_route_id uuid;
  v_stop_id uuid;
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

  UPDATE public.vortex_delivery_route_stops
  SET status='delivered',delivered_at=now(),updated_at=now()
  WHERE store_id=p_store_id AND order_id=p_order_id
    AND status IN ('in_progress','occurrence')
  RETURNING route_id,id INTO v_route_id,v_stop_id;

  IF v_route_id IS NOT NULL THEN
    INSERT INTO public.vortex_delivery_route_events(
      store_id,route_id,stop_id,order_id,actor_user_id,event_type,details
    ) VALUES (
      p_store_id,v_route_id,v_stop_id,p_order_id,auth.uid(),'delivery_confirmed',
      jsonb_build_object('confirmed_at',now(),'method','customer_code')
    );

    IF NOT EXISTS (
      SELECT 1 FROM public.vortex_delivery_route_stops
      WHERE store_id=p_store_id AND route_id=v_route_id
        AND status IN ('assigned','in_progress','occurrence')
    ) THEN
      UPDATE public.vortex_delivery_routes
      SET status='completed',completed_at=now(),updated_at=now()
      WHERE store_id=p_store_id AND id=v_route_id AND status='in_route';

      UPDATE public.vortex_delivery_courier_presence
      SET status='available',updated_at=now()
      WHERE store_id=p_store_id
        AND courier_user_id=(SELECT courier_user_id FROM public.vortex_delivery_routes
          WHERE store_id=p_store_id AND id=v_route_id);
    END IF;
  END IF;

  RETURN jsonb_build_object('success',true,'message','Entrega confirmada com sucesso.');
END;
$function$;

-- Acesso exclusivamente via funções autenticadas.
REVOKE ALL ON FUNCTION public.rpc_create_delivery_route(uuid,uuid,text[]) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.rpc_get_my_delivery_routes(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.rpc_get_delivery_route_codes(uuid,uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.rpc_start_delivery_route(uuid,uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.rpc_report_delivery_occurrence(uuid,uuid,text,text,text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.rpc_set_delivery_courier_presence(uuid,text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.rpc_confirm_delivery_code(uuid,text,text) FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.rpc_create_delivery_route(uuid,uuid,text[]) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_get_my_delivery_routes(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_get_delivery_route_codes(uuid,uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_start_delivery_route(uuid,uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_report_delivery_occurrence(uuid,uuid,text,text,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_set_delivery_courier_presence(uuid,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_confirm_delivery_code(uuid,text,text) TO authenticated;

COMMIT;
,''),
    'customer_phone',COALESCE((regexp_match(COALESCE(o.client,''),'\\(([^()]*)\\)$'))[1],''),
    'code',v.code,
    'expires_at',v.expires_at
  ) ORDER BY s.sequence_number),'[]'::jsonb)
  INTO v_result
  FROM public.vortex_delivery_route_stops s
  JOIN public.vortex_kds_orders o
    ON o.store_id=s.store_id AND o.id=s.order_id
  LEFT JOIN public.vortex_delivery_verifications v
    ON v.store_id=s.store_id AND v.order_id=s.order_id
   AND v.is_active=true AND v.consumed_at IS NULL AND v.expires_at>now()
  WHERE s.store_id=p_store_id AND s.route_id=p_route_id
    AND s.status IN ('assigned','in_progress','occurrence');

  RETURN v_result;
END;
$function$;

-- 8) Início efetivo da rota. O relógio começa aqui, nunca na atribuição.
CREATE OR REPLACE FUNCTION public.rpc_start_delivery_route(p_store_id uuid,p_route_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $function$
DECLARE
  v_route public.vortex_delivery_routes%ROWTYPE;
  v_stop_count integer;
  v_invalid_count integer;
BEGIN
  IF auth.uid() IS NULL
     OR NOT public.vortex_user_has_permission(p_store_id,'delivery.route_start') THEN
    RAISE EXCEPTION 'Seu perfil não pode iniciar rotas.';
  END IF;

  SELECT * INTO v_route
  FROM public.vortex_delivery_routes
  WHERE store_id=p_store_id AND id=p_route_id
    AND courier_user_id=auth.uid()
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Esta rota não está atribuída à sua conta.';
  END IF;
  IF v_route.status<>'assigned' THEN
    RAISE EXCEPTION 'Somente uma rota aguardando saída pode ser iniciada.';
  END IF;

  SELECT count(*) INTO v_stop_count
  FROM public.vortex_delivery_route_stops s
  WHERE s.store_id=p_store_id AND s.route_id=p_route_id AND s.status='assigned';

  SELECT count(*) INTO v_invalid_count
  FROM public.vortex_delivery_route_stops s
  JOIN public.vortex_kds_orders o ON o.store_id=s.store_id AND o.id=s.order_id
  WHERE s.store_id=p_store_id AND s.route_id=p_route_id
    AND s.status='assigned' AND o.status IN ('finished','cancelled');

  IF v_stop_count=0 OR v_invalid_count>0 THEN
    RAISE EXCEPTION 'Esta rota não possui entregas pendentes válidas. Atualize a rota com o estabelecimento.';
  END IF;

  UPDATE public.vortex_delivery_routes
  SET status='in_route',started_at=now(),updated_at=now()
  WHERE store_id=p_store_id AND id=p_route_id;

  UPDATE public.vortex_delivery_route_stops
  SET status='in_progress',started_at=now(),updated_at=now()
  WHERE store_id=p_store_id AND route_id=p_route_id AND status='assigned';

  UPDATE public.vortex_kds_orders o
  SET status='delivering',updated_at=now()
  FROM public.vortex_delivery_route_stops s
  WHERE s.store_id=p_store_id AND s.route_id=p_route_id
    AND s.order_id=o.id AND o.store_id=s.store_id
    AND s.status='in_progress' AND o.status NOT IN ('finished','cancelled');

  UPDATE public.vortex_delivery_courier_presence
  SET status='in_route',updated_at=now()
  WHERE store_id=p_store_id AND courier_user_id=auth.uid();

  INSERT INTO public.vortex_delivery_route_events(store_id,route_id,actor_user_id,event_type,details)
  VALUES (p_store_id,p_route_id,auth.uid(),'route_started',jsonb_build_object('started_at',now()));

  RETURN jsonb_build_object('success',true,'route_id',p_route_id,'started_at',now());
END;
$function$;

-- 9) Registro de ocorrência sem concluir ou cancelar indevidamente o pedido.
CREATE OR REPLACE FUNCTION public.rpc_report_delivery_occurrence(
  p_store_id uuid,
  p_route_id uuid,
  p_order_id text,
  p_occurrence_type text,
  p_notes text DEFAULT ''
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $function$
DECLARE
  v_stop_id uuid;
BEGIN
  IF auth.uid() IS NULL
     OR NOT public.vortex_user_has_permission(p_store_id,'delivery.occurrence_report') THEN
    RAISE EXCEPTION 'Seu perfil não pode registrar ocorrências.';
  END IF;

  IF p_occurrence_type IS NULL OR p_occurrence_type NOT IN ('customer_absent','wrong_address','no_response','customer_refused','other')
     OR length(COALESCE(p_notes,''))>1000 THEN
    RAISE EXCEPTION 'Tipo ou descrição da ocorrência inválidos.';
  END IF;

  PERFORM 1 FROM public.vortex_delivery_routes
  WHERE store_id=p_store_id AND id=p_route_id
    AND courier_user_id=auth.uid() AND status='in_route'
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'A rota não está ativa ou não pertence à sua conta.';
  END IF;

  UPDATE public.vortex_delivery_route_stops
  SET status='occurrence',occurrence_type=p_occurrence_type,
      occurrence_notes=left(COALESCE(p_notes,''),1000),
      occurrence_at=now(),updated_at=now()
  WHERE store_id=p_store_id AND route_id=p_route_id
    AND order_id=p_order_id AND status='in_progress'
  RETURNING id INTO v_stop_id;

  IF v_stop_id IS NULL THEN
    RAISE EXCEPTION 'A parada não está pendente nesta rota.';
  END IF;

  INSERT INTO public.vortex_delivery_route_events(
    store_id,route_id,stop_id,order_id,actor_user_id,event_type,details
  ) VALUES (
    p_store_id,p_route_id,v_stop_id,p_order_id,auth.uid(),'delivery_occurrence',
    jsonb_build_object('type',p_occurrence_type,'notes',left(COALESCE(p_notes,''),1000))
  );

  RETURN jsonb_build_object('success',true,'stop_id',v_stop_id,'status','occurrence');
END;
$function$;

-- 10) Atualização da disponibilidade somente da própria conta de motoboy.
CREATE OR REPLACE FUNCTION public.rpc_set_delivery_courier_presence(
  p_store_id uuid,
  p_status text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $function$
BEGIN
  IF auth.uid() IS NULL
     OR NOT public.vortex_user_has_permission(p_store_id,'delivery.presence_update')
     OR NOT EXISTS (
       SELECT 1 FROM public.vortex_store_members
       WHERE store_id=p_store_id AND user_id=auth.uid()
         AND status='active' AND profile_key='delivery'
     ) THEN
    RAISE EXCEPTION 'Somente um motoboy ativo pode alterar a própria disponibilidade.';
  END IF;

  IF p_status IS NULL OR p_status NOT IN ('available','paused','unavailable') THEN
    RAISE EXCEPTION 'Situação de disponibilidade inválida.';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.vortex_delivery_routes
    WHERE store_id=p_store_id AND courier_user_id=auth.uid() AND status='in_route'
  ) AND p_status<>'available' THEN
    RAISE EXCEPTION 'Finalize ou resolva a rota ativa antes de ficar indisponível ou pausar.';
  END IF;

  INSERT INTO public.vortex_delivery_courier_presence(store_id,courier_user_id,status,updated_at)
  VALUES (p_store_id,auth.uid(),p_status,now())
  ON CONFLICT (store_id,courier_user_id)
  DO UPDATE SET status=EXCLUDED.status,updated_at=now();

  RETURN jsonb_build_object('success',true,'status',p_status);
END;
$function$;

-- 11) Sincroniza a confirmação já existente com a parada e o histórico da rota.
-- Mantém o contrato de retorno e a proteção contra tentativas incorretas.
CREATE OR REPLACE FUNCTION public.rpc_confirm_delivery_code(
  p_store_id uuid,p_order_id text,p_code text
)
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
  v_route_id uuid;
  v_stop_id uuid;
  v_route_status text;
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

  UPDATE public.vortex_delivery_route_stops
  SET status='delivered',delivered_at=now(),updated_at=now()
  WHERE store_id=p_store_id AND order_id=p_order_id
    AND status IN ('in_progress','occurrence')
  RETURNING route_id,id INTO v_route_id,v_stop_id;

  IF v_route_id IS NOT NULL THEN
    INSERT INTO public.vortex_delivery_route_events(
      store_id,route_id,stop_id,order_id,actor_user_id,event_type,details
    ) VALUES (
      p_store_id,v_route_id,v_stop_id,p_order_id,auth.uid(),'delivery_confirmed',
      jsonb_build_object('confirmed_at',now(),'method','customer_code')
    );

    SELECT status INTO v_route_status
    FROM public.vortex_delivery_routes
    WHERE store_id=p_store_id AND id=v_route_id
    FOR UPDATE;

    IF NOT EXISTS (
      SELECT 1 FROM public.vortex_delivery_route_stops
      WHERE store_id=p_store_id AND route_id=v_route_id
        AND status IN ('assigned','in_progress','occurrence')
    ) THEN
      UPDATE public.vortex_delivery_routes
      SET status='completed',completed_at=now(),updated_at=now()
      WHERE store_id=p_store_id AND id=v_route_id AND status='in_route';

      UPDATE public.vortex_delivery_courier_presence
      SET status='available',updated_at=now()
      WHERE store_id=p_store_id
        AND courier_user_id=(SELECT courier_user_id FROM public.vortex_delivery_routes
          WHERE store_id=p_store_id AND id=v_route_id);
    END IF;
  END IF;

  RETURN jsonb_build_object('success',true,'message','Entrega confirmada com sucesso.');
END;
$function$;

-- Acesso exclusivamente via funções autenticadas.
REVOKE ALL ON FUNCTION public.rpc_create_delivery_route(uuid,uuid,text[]) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.rpc_get_my_delivery_routes(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.rpc_get_delivery_route_codes(uuid,uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.rpc_start_delivery_route(uuid,uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.rpc_report_delivery_occurrence(uuid,uuid,text,text,text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.rpc_set_delivery_courier_presence(uuid,text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.rpc_confirm_delivery_code(uuid,text,text) FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.rpc_create_delivery_route(uuid,uuid,text[]) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_get_my_delivery_routes(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_get_delivery_route_codes(uuid,uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_start_delivery_route(uuid,uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_report_delivery_occurrence(uuid,uuid,text,text,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_set_delivery_courier_presence(uuid,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_confirm_delivery_code(uuid,text,text) TO authenticated;

COMMIT;
