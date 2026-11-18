-- Cancelamento individual de itens do KDS com vínculo à comanda de mesa.
-- Itens sem itemId (pedidos históricos) permanecem no fluxo de cancelamento integral.
BEGIN;

CREATE TABLE IF NOT EXISTS public.vortex_order_item_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  store_id uuid NOT NULL REFERENCES public.vortex_stores(id) ON DELETE CASCADE,
  order_id text NOT NULL,
  item_id text NOT NULL,
  event_type text NOT NULL CHECK (event_type IN ('cancelled')),
  reason text NOT NULL,
  billing_action text NOT NULL CHECK (billing_action IN ('charge','waive')),
  order_status_before text NOT NULL,
  stock_disposition text NOT NULL CHECK (stock_disposition IN ('not_consumed','waste_after_consumption')),
  actor_id uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT vortex_order_item_events_once UNIQUE(store_id,order_id,item_id,event_type)
);

CREATE INDEX IF NOT EXISTS vortex_order_item_events_order_idx
  ON public.vortex_order_item_events(store_id,order_id,created_at);

ALTER TABLE public.vortex_order_item_events ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.vortex_order_item_events FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.rpc_cancel_kds_item(
  p_order_id text,
  p_item_id text,
  p_reason text,
  p_billing_action text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $function$
DECLARE
  v_store_id uuid;
  v_membership_count integer;
  v_order public.vortex_kds_orders%ROWTYPE;
  v_item jsonb;
  v_items jsonb;
  v_updated_items jsonb;
  v_cart jsonb;
  v_sent_items jsonb;
  v_table_number integer;
  v_item_index integer;
  v_stock_consumed boolean := false;
  v_stock_disposition text;
  v_new_total numeric(14,2);
  v_permission boolean := false;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Autenticação necessária para cancelar item.';
  END IF;
  IF COALESCE(NULLIF(BTRIM(p_order_id),''),'')='' OR COALESCE(NULLIF(BTRIM(p_item_id),''),'')=''
     OR p_billing_action NOT IN ('charge','waive') THEN
    RAISE EXCEPTION 'Pedido, item ou decisão de cobrança inválidos.';
  END IF;

  SELECT COUNT(*),MIN(store_id::text)::uuid
  INTO v_membership_count,v_store_id
  FROM public.vortex_store_members
  WHERE user_id=auth.uid() AND status='active';
  IF v_membership_count<>1 OR v_store_id IS NULL THEN
    RAISE EXCEPTION 'Não foi possível identificar uma única loja ativa.';
  END IF;

  SELECT * INTO v_order
  FROM public.vortex_kds_orders
  WHERE store_id=v_store_id AND id=p_order_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Pedido não encontrado nesta loja.'; END IF;
  IF v_order.status IN ('finished','completed','cancelled') THEN
    RAISE EXCEPTION 'Este pedido já foi finalizado. Ajustes após pagamento devem ser registrados como estorno.';
  END IF;

  IF COALESCE(v_order.origin,'') ILIKE '%Mesa%' THEN
    v_permission := (
      public.vortex_user_has_permission(v_store_id,'tables.close')
      OR public.vortex_user_has_permission(v_store_id,'pdv.cancel')
    );
  ELSIF COALESCE(v_order.origin,'') ILIKE '%Delivery%' THEN
    v_permission := (
      public.vortex_user_has_permission(v_store_id,'delivery.manage')
      OR public.vortex_user_has_permission(v_store_id,'pdv.cancel')
    );
  ELSE
    v_permission := (
      public.vortex_user_has_permission(v_store_id,'kds.cancel')
      OR public.vortex_user_has_permission(v_store_id,'pdv.cancel')
    );
  END IF;
  IF NOT v_permission THEN RAISE EXCEPTION 'Seu perfil não pode cancelar itens deste pedido.'; END IF;

  v_items := COALESCE(v_order.items,'[]'::jsonb);
  SELECT value,ordinality::integer-1
  INTO v_item,v_item_index
  FROM jsonb_array_elements(v_items) WITH ORDINALITY AS e(value,ordinality)
  WHERE COALESCE(value->>'itemId',value->>'item_id')=p_item_id
  LIMIT 1;
  IF v_item IS NULL THEN
    RAISE EXCEPTION 'Este item não possui identificador individual. Preserve o pedido e use o cancelamento integral, se necessário.';
  END IF;

  IF v_item->>'status'='cancelled' THEN
    IF v_item->>'billingStatus'=p_billing_action THEN
      RETURN jsonb_build_object('success',true,'already_cancelled',true,'billing_action',p_billing_action);
    END IF;
    RAISE EXCEPTION 'Este item já foi cancelado com outra decisão de cobrança. Faça um ajuste financeiro registrado, sem alterar o histórico do cancelamento.';
  END IF;

  SELECT EXISTS(
    SELECT 1
    FROM public.vortex_stock_movements
    WHERE store_id=v_store_id
      AND order_id=p_order_id
      AND idempotency_key LIKE 'consumption_'||p_order_id||'_item_'||v_item_index||'_ing_%'
  ) INTO v_stock_consumed;
  v_stock_disposition := CASE WHEN v_stock_consumed THEN 'waste_after_consumption' ELSE 'not_consumed' END;

  SELECT COALESCE(jsonb_agg(
    CASE
      WHEN COALESCE(e.value->>'itemId',e.value->>'item_id')=p_item_id THEN
        jsonb_set(
          jsonb_set(
            jsonb_set(
              jsonb_set(e.value,'{status}','"cancelled"'::jsonb,true),
              '{billingStatus}',to_jsonb(p_billing_action),true
            ),
            '{cancellationReason}',to_jsonb(left(COALESCE(p_reason,'Cancelado no KDS'),300)),true
          ),
          '{cancelledAt}',to_jsonb(now()),true
        ) || jsonb_build_object('cancelledBy',auth.uid())
      ELSE e.value
    END ORDER BY e.ordinality
  ),'[]'::jsonb)
  INTO v_updated_items
  FROM jsonb_array_elements(v_items) WITH ORDINALITY AS e(value,ordinality);

  IF COALESCE(v_order.origin,'') ILIKE '%Mesa%' THEN
    v_table_number := NULLIF(regexp_replace(v_order.origin,'[^0-9]','','g'),'')::integer;
    IF v_table_number IS NULL OR v_table_number NOT BETWEEN 1 AND 200 THEN
      RAISE EXCEPTION 'Não foi possível identificar a mesa deste pedido. O cancelamento não foi aplicado.';
    END IF;

    SELECT cart_data INTO v_cart
    FROM public.vortex_table_carts
    WHERE store_id=v_store_id AND table_number=v_table_number
    FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'A comanda desta mesa não está sincronizada na nuvem. O cancelamento não foi aplicado.';
    END IF;

    SELECT COALESCE(jsonb_agg(
      CASE
        WHEN COALESCE(e.value->>'itemId',e.value->>'item_id')=p_item_id THEN
          jsonb_set(
            jsonb_set(
              jsonb_set(
                jsonb_set(e.value,'{status}','"cancelled"'::jsonb,true),
                '{billingStatus}',to_jsonb(p_billing_action),true
              ),
              '{cancellationReason}',to_jsonb(left(COALESCE(p_reason,'Cancelado no KDS'),300)),true
            ),
            '{cancelledAt}',to_jsonb(now()),true
          ) || jsonb_build_object('cancelledBy',auth.uid())
        ELSE e.value
      END ORDER BY e.ordinality
    ),'[]'::jsonb)
    INTO v_sent_items
    FROM jsonb_array_elements(COALESCE(v_cart->'sentItems','[]'::jsonb)) WITH ORDINALITY AS e(value,ordinality);

    IF NOT EXISTS(
      SELECT 1 FROM jsonb_array_elements(COALESCE(v_cart->'sentItems','[]'::jsonb)) AS e(value)
      WHERE COALESCE(value->>'itemId',value->>'item_id')=p_item_id
    ) THEN
      RAISE EXCEPTION 'O item não foi encontrado na comanda da mesa. O cancelamento não foi aplicado.';
    END IF;

    SELECT COALESCE(SUM(
      COALESCE(NULLIF(value->>'price','')::numeric,0)
      * COALESCE(NULLIF(value->>'qty','')::numeric,NULLIF(value->>'quantity','')::numeric,1)
    ),0)
    INTO v_new_total
    FROM jsonb_array_elements(v_sent_items) AS e(value)
    WHERE COALESCE(value->>'billingStatus','charge')<>'waive';

    UPDATE public.vortex_table_carts
    SET cart_data=jsonb_set(
          jsonb_set(v_cart,'{sentItems}',v_sent_items,true),
          '{totalAccumulated}',to_jsonb(v_new_total),true
        ),
        updated_at=now(),
        updated_by=auth.uid()
    WHERE store_id=v_store_id AND table_number=v_table_number;
  END IF;

  UPDATE public.vortex_kds_orders
  SET items=v_updated_items,
      total=(
        SELECT COALESCE(SUM(
          COALESCE(NULLIF(value->>'price','')::numeric,0)
          * COALESCE(NULLIF(value->>'qty','')::numeric,NULLIF(value->>'quantity','')::numeric,1)
        ),0)
        FROM jsonb_array_elements(v_updated_items) AS e(value)
        WHERE COALESCE(value->>'billingStatus','charge')<>'waive'
      ),
      updated_at=now(),
      updated_by=auth.uid()
  WHERE store_id=v_store_id AND id=p_order_id;

  INSERT INTO public.vortex_order_item_events(
    store_id,order_id,item_id,event_type,reason,billing_action,
    order_status_before,stock_disposition,actor_id
  ) VALUES (
    v_store_id,p_order_id,p_item_id,'cancelled',
    left(COALESCE(p_reason,'Cancelado no KDS'),300),p_billing_action,
    v_order.status,v_stock_disposition,auth.uid()
  )
  ON CONFLICT(store_id,order_id,item_id,event_type) DO NOTHING;

  RETURN jsonb_build_object(
    'success',true,
    'order_id',p_order_id,
    'item_id',p_item_id,
    'billing_action',p_billing_action,
    'stock_disposition',v_stock_disposition
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_cancel_kds_item(text,text,text,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_cancel_kds_item(text,text,text,text) TO authenticated;

COMMIT;
