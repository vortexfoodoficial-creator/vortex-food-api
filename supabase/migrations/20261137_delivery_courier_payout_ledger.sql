-- VORTEX FOOD: contas a pagar dos motoboys e correção da configuração de remuneração.
-- Aditiva: não cria pedidos/cadastros fictícios e não altera valores históricos já pagos.
BEGIN;

-- Permite manter a remuneração como "não configurada" sem bloquear o salvamento
-- das demais configurações do estabelecimento.
CREATE OR REPLACE FUNCTION public.rpc_save_delivery_courier_payment_rules(
  p_store_id uuid,
  p_mode text,
  p_fixed_amount numeric,
  p_neighborhood_rates jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $function$
DECLARE
  v_rates jsonb := COALESCE(p_neighborhood_rates,'[]'::jsonb);
  v_item jsonb;
BEGIN
  IF auth.uid() IS NULL OR NOT public.vortex_user_has_permission(p_store_id,'settings.manage') THEN
    RAISE EXCEPTION 'Seu perfil não pode alterar a remuneração dos entregadores.';
  END IF;
  IF p_mode IS NULL OR p_mode NOT IN ('fixed','neighborhood','per_km')
     OR jsonb_typeof(v_rates)<>'array'
     OR jsonb_array_length(v_rates)>200
     OR (p_fixed_amount IS NOT NULL AND (p_fixed_amount<0 OR p_fixed_amount>10000)) THEN
    RAISE EXCEPTION 'Configuração de remuneração inválida.';
  END IF;
  IF p_mode='per_km' AND p_fixed_amount IS NULL THEN
    RAISE EXCEPTION 'Informe o valor que o motoboy recebe por quilômetro.';
  END IF;
  IF p_mode='fixed' AND p_fixed_amount IS NOT NULL AND p_fixed_amount>10000 THEN
    RAISE EXCEPTION 'O valor fixo por entrega excede o limite permitido.';
  END IF;
  FOR v_item IN SELECT value FROM jsonb_array_elements(v_rates) LOOP
    IF length(trim(COALESCE(v_item->>'name','')))<2
       OR COALESCE(v_item->>'amount','') !~ '^\d{1,8}([.,]\d{1,2})?
       OR replace(v_item->>'amount',',','.')::numeric<0
       OR replace(v_item->>'amount',',','.')::numeric>10000 THEN
      RAISE EXCEPTION 'Revise os bairros e valores informados na remuneração.';
    END IF;
  END LOOP;

  INSERT INTO public.vortex_delivery_courier_payment_rules(
    store_id,mode,fixed_amount,neighborhood_rates,updated_by,updated_at
  ) VALUES (
    p_store_id,p_mode,CASE WHEN p_mode IN ('fixed','per_km') THEN p_fixed_amount ELSE NULL END,
    v_rates,auth.uid(),now()
  )
  ON CONFLICT (store_id) DO UPDATE SET
    mode=EXCLUDED.mode,fixed_amount=EXCLUDED.fixed_amount,
    neighborhood_rates=EXCLUDED.neighborhood_rates,
    updated_by=EXCLUDED.updated_by,updated_at=now();

  RETURN jsonb_build_object('success',true,'mode',p_mode,'configured',
    CASE WHEN p_mode='fixed' THEN p_fixed_amount IS NOT NULL
         WHEN p_mode='per_km' THEN p_fixed_amount IS NOT NULL
         ELSE jsonb_array_length(v_rates)>0 END);
END;
$function$;

CREATE TABLE IF NOT EXISTS public.vortex_delivery_courier_ledger (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  store_id uuid NOT NULL REFERENCES public.vortex_stores(id) ON DELETE CASCADE,
  stop_id uuid NOT NULL REFERENCES public.vortex_delivery_route_stops(id) ON DELETE RESTRICT,
  route_id uuid NOT NULL REFERENCES public.vortex_delivery_routes(id) ON DELETE RESTRICT,
  order_id text NOT NULL,
  courier_user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  amount numeric(12,2),
  rule_label text,
  distance_km numeric(8,2),
  delivered_at timestamptz NOT NULL,
  payout_status text NOT NULL DEFAULT 'pending' CHECK (payout_status IN ('pending','paid')),
  paid_at timestamptz,
  paid_by_user_id uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  payment_method text,
  payment_reference text,
  payment_notes text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT vortex_delivery_courier_ledger_amount_check CHECK (amount IS NULL OR amount>=0),
  CONSTRAINT vortex_delivery_courier_ledger_paid_fields_check
    CHECK ((payout_status='pending' AND paid_at IS NULL) OR (payout_status='paid' AND paid_at IS NOT NULL)),
  CONSTRAINT vortex_delivery_courier_ledger_stop_unique UNIQUE(store_id,stop_id)
);

CREATE INDEX IF NOT EXISTS vortex_delivery_courier_ledger_store_date_idx
  ON public.vortex_delivery_courier_ledger(store_id,delivered_at DESC);
CREATE INDEX IF NOT EXISTS vortex_delivery_courier_ledger_courier_date_idx
  ON public.vortex_delivery_courier_ledger(store_id,courier_user_id,delivered_at DESC);
CREATE INDEX IF NOT EXISTS vortex_delivery_courier_ledger_pending_idx
  ON public.vortex_delivery_courier_ledger(store_id,courier_user_id,delivered_at DESC)
  WHERE payout_status='pending';

ALTER TABLE public.vortex_delivery_courier_ledger ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.vortex_delivery_courier_ledger FROM PUBLIC,anon,authenticated;

CREATE OR REPLACE FUNCTION public.vortex_sync_delivery_courier_ledger()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $function$
DECLARE
  v_courier_id uuid;
BEGIN
  IF NEW.status<>'delivered' OR NEW.delivered_at IS NULL THEN
    RETURN NEW;
  END IF;

  SELECT COALESCE(NEW.delivered_by_user_id,r.courier_user_id)
    INTO v_courier_id
  FROM public.vortex_delivery_routes r
  WHERE r.store_id=NEW.store_id AND r.id=NEW.route_id;

  IF v_courier_id IS NULL THEN
    RETURN NEW;
  END IF;

  INSERT INTO public.vortex_delivery_courier_ledger AS existing(
    store_id,stop_id,route_id,order_id,courier_user_id,amount,rule_label,
    distance_km,delivered_at
  ) VALUES (
    NEW.store_id,NEW.id,NEW.route_id,NEW.order_id,v_courier_id,
    NEW.courier_payment_amount,NEW.courier_payment_rule_label,
    NEW.distance_km,NEW.delivered_at
  )
  ON CONFLICT(store_id,stop_id) DO UPDATE SET
    courier_user_id=CASE WHEN existing.payout_status='pending'
      THEN EXCLUDED.courier_user_id ELSE public.vortex_delivery_courier_ledger.courier_user_id END,
    amount=CASE WHEN existing.payout_status='pending'
      THEN EXCLUDED.amount ELSE public.vortex_delivery_courier_ledger.amount END,
    rule_label=CASE WHEN existing.payout_status='pending'
      THEN EXCLUDED.rule_label ELSE public.vortex_delivery_courier_ledger.rule_label END,
    distance_km=CASE WHEN existing.payout_status='pending'
      THEN EXCLUDED.distance_km ELSE public.vortex_delivery_courier_ledger.distance_km END,
    updated_at=now();

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_sync_delivery_courier_ledger ON public.vortex_delivery_route_stops;
CREATE TRIGGER trg_sync_delivery_courier_ledger
AFTER INSERT OR UPDATE OF status,delivered_at,delivered_by_user_id,courier_payment_amount,distance_km
ON public.vortex_delivery_route_stops
FOR EACH ROW EXECUTE FUNCTION public.vortex_sync_delivery_courier_ledger();

-- Recupera somente entregas reais já concluídas; o valor permanece NULL quando
-- não existe informação confiável, sem inventar remuneração retroativa.
INSERT INTO public.vortex_delivery_courier_ledger(
  store_id,stop_id,route_id,order_id,courier_user_id,amount,rule_label,distance_km,delivered_at
)
SELECT s.store_id,s.id,s.route_id,s.order_id,
       COALESCE(s.delivered_by_user_id,r.courier_user_id),
       s.courier_payment_amount,s.courier_payment_rule_label,s.distance_km,s.delivered_at
FROM public.vortex_delivery_route_stops s
JOIN public.vortex_delivery_routes r ON r.store_id=s.store_id AND r.id=s.route_id
WHERE s.status='delivered' AND s.delivered_at IS NOT NULL
  AND COALESCE(s.delivered_by_user_id,r.courier_user_id) IS NOT NULL
ON CONFLICT(store_id,stop_id) DO NOTHING;

CREATE OR REPLACE FUNCTION public.rpc_get_delivery_courier_earnings(
  p_store_id uuid,p_start_date date,p_end_date date,p_courier_user_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $function$
DECLARE v_is_courier boolean; v_result jsonb;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Sessão não autenticada.'; END IF;
  v_is_courier := EXISTS(
    SELECT 1 FROM public.vortex_store_members
    WHERE store_id=p_store_id AND user_id=auth.uid()
      AND status='active' AND profile_key='delivery'
  );
  IF v_is_courier THEN
    IF NOT public.vortex_user_has_permission(p_store_id,'delivery.route_view') THEN
      RAISE EXCEPTION 'Seu perfil não pode consultar o extrato de entregas.';
    END IF;
    IF p_courier_user_id IS NOT NULL AND p_courier_user_id<>auth.uid() THEN
      RAISE EXCEPTION 'Você só pode consultar seu próprio extrato.';
    END IF;
  ELSIF NOT public.vortex_user_has_permission(p_store_id,'delivery.dispatch_view') THEN
    RAISE EXCEPTION 'Seu perfil não pode consultar os repasses dos motoboys.';
  END IF;
  IF p_start_date IS NULL OR p_end_date IS NULL OR p_start_date>p_end_date
     OR p_end_date-p_start_date>366 THEN
    RAISE EXCEPTION 'Período inválido. Consulte no máximo 12 meses por vez.';
  END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id',l.id,'stop_id',l.stop_id,'route_id',l.route_id,'order_id',l.order_id,
    'display_id',o."displayId",'courier_user_id',l.courier_user_id,
    'courier_name',COALESCE(NULLIF(m.display_name,''),NULLIF(u.raw_user_meta_data->>'display_name',''),'Motoboy'),
    'amount',l.amount,'rule_label',l.rule_label,'distance_km',l.distance_km,
    'delivered_at',l.delivered_at,'payout_status',l.payout_status,
    'paid_at',l.paid_at,'paid_by_user_id',l.paid_by_user_id,
    'payment_method',l.payment_method,'payment_reference',l.payment_reference,
    'payment_notes',l.payment_notes
  ) ORDER BY l.delivered_at DESC),'[]'::jsonb)
  INTO v_result
  FROM public.vortex_delivery_courier_ledger l
  LEFT JOIN public.vortex_kds_orders o ON o.store_id=l.store_id AND o.id=l.order_id
  LEFT JOIN auth.users u ON u.id=l.courier_user_id
  LEFT JOIN public.vortex_store_members m ON m.store_id=l.store_id AND m.user_id=l.courier_user_id
  WHERE l.store_id=p_store_id
    AND l.delivered_at >= (p_start_date::timestamp AT TIME ZONE 'America/Sao_Paulo')
    AND l.delivered_at < ((p_end_date+1)::timestamp AT TIME ZONE 'America/Sao_Paulo')
    AND (v_is_courier OR p_courier_user_id IS NULL OR l.courier_user_id=p_courier_user_id)
    AND (NOT v_is_courier OR l.courier_user_id=auth.uid());
  RETURN v_result;
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpc_mark_delivery_courier_payment_paid(
  p_store_id uuid,p_stop_id uuid,p_payment_method text,p_payment_reference text,p_payment_notes text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $function$
DECLARE v_row public.vortex_delivery_courier_ledger%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL OR NOT public.vortex_user_has_permission(p_store_id,'delivery.dispatch_manage') THEN
    RAISE EXCEPTION 'Seu perfil não pode registrar repasses aos motoboys.';
  END IF;
  IF p_payment_method NOT IN ('pix','dinheiro','transferencia','outro') THEN
    RAISE EXCEPTION 'Selecione uma forma de repasse válida.';
  END IF;
  SELECT * INTO v_row
  FROM public.vortex_delivery_courier_ledger
  WHERE store_id=p_store_id AND stop_id=p_stop_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Lançamento financeiro não encontrado.'; END IF;
  IF v_row.payout_status='paid' THEN RAISE EXCEPTION 'Este repasse já foi marcado como pago.'; END IF;
  IF v_row.amount IS NULL THEN RAISE EXCEPTION 'Defina a remuneração desta entrega antes de registrar o pagamento.'; END IF;

  UPDATE public.vortex_delivery_courier_ledger
  SET payout_status='paid',paid_at=now(),paid_by_user_id=auth.uid(),
      payment_method=p_payment_method,
      payment_reference=NULLIF(trim(COALESCE(p_payment_reference,'')),''),
      payment_notes=NULLIF(trim(COALESCE(p_payment_notes,'')),''),
      updated_at=now()
  WHERE id=v_row.id;

  INSERT INTO public.vortex_delivery_route_events(
    store_id,route_id,stop_id,order_id,actor_user_id,event_type,details
  ) VALUES (
    p_store_id,v_row.route_id,v_row.stop_id,v_row.order_id,auth.uid(),
    'courier_payment_settled',
    jsonb_build_object('amount',v_row.amount,'payment_method',p_payment_method,
      'payment_reference',NULLIF(trim(COALESCE(p_payment_reference,'')),''),
      'paid_at',now())
  );
  RETURN jsonb_build_object('success',true,'stop_id',p_stop_id,'amount',v_row.amount,'payout_status','paid');
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_get_delivery_courier_earnings(uuid,date,date,uuid) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.rpc_mark_delivery_courier_payment_paid(uuid,uuid,text,text,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.rpc_get_delivery_courier_earnings(uuid,date,date,uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_mark_delivery_courier_payment_paid(uuid,uuid,text,text,text) TO authenticated;

COMMIT;
