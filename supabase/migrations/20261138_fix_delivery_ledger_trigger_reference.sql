-- VORTEX FOOD: corrige a referência ao registro-alvo no UPSERT do financeiro dos motoboys.
-- A migração 37 já foi aplicada; esta migração substitui somente a função do trigger
-- para permitir concluir entregas sem erro no lançamento do contas a pagar.
BEGIN;

CREATE OR REPLACE FUNCTION public.vortex_sync_delivery_courier_ledger()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $function$
DECLARE
  v_courier_id uuid;
BEGIN
  IF NEW.status <> 'delivered' OR NEW.delivered_at IS NULL THEN
    RETURN NEW;
  END IF;

  SELECT COALESCE(NEW.delivered_by_user_id, r.courier_user_id)
    INTO v_courier_id
  FROM public.vortex_delivery_routes r
  WHERE r.store_id = NEW.store_id
    AND r.id = NEW.route_id;

  IF v_courier_id IS NULL THEN
    RETURN NEW;
  END IF;

  INSERT INTO public.vortex_delivery_courier_ledger AS existing (
    store_id, stop_id, route_id, order_id, courier_user_id,
    amount, rule_label, distance_km, delivered_at
  ) VALUES (
    NEW.store_id, NEW.id, NEW.route_id, NEW.order_id, v_courier_id,
    NEW.courier_payment_amount, NEW.courier_payment_rule_label,
    NEW.distance_km, NEW.delivered_at
  )
  ON CONFLICT (store_id, stop_id) DO UPDATE SET
    courier_user_id = CASE
      WHEN existing.payout_status = 'pending' THEN EXCLUDED.courier_user_id
      ELSE existing.courier_user_id
    END,
    amount = CASE
      WHEN existing.payout_status = 'pending' THEN EXCLUDED.amount
      ELSE existing.amount
    END,
    rule_label = CASE
      WHEN existing.payout_status = 'pending' THEN EXCLUDED.rule_label
      ELSE existing.rule_label
    END,
    distance_km = CASE
      WHEN existing.payout_status = 'pending' THEN EXCLUDED.distance_km
      ELSE existing.distance_km
    END,
    updated_at = now();

  RETURN NEW;
END;
$function$;

COMMIT;
