-- VORTEX FOOD: fundação do sistema granular de permissões por funcionário.
-- Esta migração cria catálogo, perfis, permissões individuais e trilha de auditoria.
-- Não altera políticas operacionais nesta etapa; o bloqueio efetivo será aplicado
-- em migrações seguintes, depois de mapear cada operação dos módulos.

BEGIN;

CREATE TABLE IF NOT EXISTS public.vortex_permission_catalog (
  permission_key text PRIMARY KEY,
  module_key text NOT NULL,
  action_key text NOT NULL,
  label text NOT NULL,
  description text NOT NULL DEFAULT ''
);

CREATE TABLE IF NOT EXISTS public.vortex_permission_profiles (
  profile_key text PRIMARY KEY,
  label text NOT NULL,
  description text NOT NULL DEFAULT '',
  is_system boolean NOT NULL DEFAULT true
);

CREATE TABLE IF NOT EXISTS public.vortex_profile_permissions (
  profile_key text NOT NULL REFERENCES public.vortex_permission_profiles(profile_key) ON DELETE CASCADE,
  permission_key text NOT NULL REFERENCES public.vortex_permission_catalog(permission_key) ON DELETE CASCADE,
  allowed boolean NOT NULL DEFAULT true,
  PRIMARY KEY (profile_key, permission_key)
);

CREATE TABLE IF NOT EXISTS public.vortex_member_permissions (
  store_id uuid NOT NULL,
  user_id uuid NOT NULL,
  permission_key text NOT NULL REFERENCES public.vortex_permission_catalog(permission_key) ON DELETE CASCADE,
  allowed boolean NOT NULL,
  granted_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (store_id, user_id, permission_key),
  CONSTRAINT vortex_member_permissions_member_fkey
    FOREIGN KEY (store_id, user_id)
    REFERENCES public.vortex_store_members(store_id, user_id)
    ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS public.vortex_permission_audit_log (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  store_id uuid NOT NULL REFERENCES public.vortex_stores(id) ON DELETE CASCADE,
  actor_user_id uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  target_user_id uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  permission_key text,
  previous_allowed boolean,
  new_allowed boolean,
  event_type text NOT NULL,
  details jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS vortex_member_permissions_user_idx
  ON public.vortex_member_permissions(store_id, user_id);
CREATE INDEX IF NOT EXISTS vortex_permission_audit_store_created_idx
  ON public.vortex_permission_audit_log(store_id, created_at DESC);

-- Perfis são modelos iniciais; cada funcionário poderá receber exceções individuais.
INSERT INTO public.vortex_permission_profiles(profile_key, label, description)
VALUES
  ('owner', 'Proprietário', 'Acesso integral ao estabelecimento e controle final das permissões.'),
  ('administrator', 'Administrador', 'Administração operacional ampla, sem poderes sobre o proprietário.'),
  ('manager', 'Gerente', 'Gestão diária da operação e da equipe dentro das permissões concedidas.'),
  ('attendant', 'Atendente', 'Atendimento, vendas e operações de balcão autorizadas.'),
  ('kitchen', 'Equipe de cozinha', 'Visualização e atualização dos pedidos de preparo.'),
  ('delivery', 'Entregador', 'Acesso às entregas atribuídas e confirmação de entrega.')
ON CONFLICT (profile_key) DO UPDATE
SET label = EXCLUDED.label, description = EXCLUDED.description;

INSERT INTO public.vortex_permission_catalog(permission_key,module_key,action_key,label,description)
VALUES
  ('dashboard.view','dashboard','view','Visualizar painel','Acessar indicadores gerais permitidos.'),
  ('pdv.view','pdv','view','Visualizar PDV','Abrir o ponto de venda.'),
  ('pdv.sell','pdv','sell','Registrar vendas','Finalizar vendas no PDV.'),
  ('pdv.discount','pdv','discount','Aplicar descontos','Aplicar descontos em vendas.'),
  ('pdv.cancel','pdv','cancel','Cancelar vendas','Cancelar vendas e pedidos.'),
  ('pdv.history','pdv','history','Consultar histórico de vendas','Consultar vendas anteriores.'),
  ('tables.view','tables','view','Visualizar mesas','Consultar mapa e situação das mesas.'),
  ('tables.open','tables','open','Abrir mesas','Abrir atendimento em mesa.'),
  ('tables.close','tables','close','Fechar mesas','Fechar contas e atendimentos de mesa.'),
  ('tables.attend_requests','tables','attend_requests','Atender solicitações','Atender chamadas e pedidos de conta por QR.'),
  ('tables.manage_qr','tables','manage_qr','Configurar QR Code','Ativar e configurar atendimento por QR.'),
  ('delivery.view','delivery','view','Visualizar delivery','Consultar pedidos de entrega.'),
  ('delivery.manage','delivery','manage','Gerenciar delivery','Editar e organizar pedidos de entrega.'),
  ('delivery.assign','delivery','assign','Atribuir entregas','Atribuir pedidos a entregadores.'),
  ('delivery.dispatch','delivery','dispatch','Despachar entregas','Liberar pedidos para entrega.'),
  ('delivery.confirm','delivery','confirm','Confirmar entrega','Confirmar entrega com código.'),
  ('delivery.manual_finish','delivery','manual_finish','Finalizar sem código','Finalizar entrega manualmente.'),
  ('delivery.manage_couriers','delivery','manage_couriers','Gerenciar entregadores','Cadastrar e editar entregadores.'),
  ('kds.view','kds','view','Visualizar KDS','Ver fila de preparo.'),
  ('kds.update_status','kds','update_status','Atualizar preparo','Alterar etapas e status dos pedidos.'),
  ('kds.cancel','kds','cancel','Cancelar no KDS','Cancelar pedidos pela cozinha.'),
  ('catalog.view','catalog','view','Visualizar cardápio','Consultar produtos e categorias.'),
  ('catalog.manage_products','catalog','manage_products','Gerenciar produtos','Criar e editar produtos.'),
  ('catalog.manage_prices','catalog','manage_prices','Alterar preços','Alterar preços e valores.'),
  ('catalog.manage_categories','catalog','manage_categories','Gerenciar categorias','Criar e editar categorias e complementos.'),
  ('recipes.view','recipes','view','Visualizar fichas técnicas','Consultar receitas e fichas técnicas.'),
  ('recipes.manage','recipes','manage','Gerenciar fichas técnicas','Criar e editar receitas.'),
  ('stock.view','stock','view','Visualizar estoque','Consultar quantidades e movimentações autorizadas.'),
  ('stock.manage_items','stock','manage_items','Gerenciar itens','Cadastrar e editar itens de estoque.'),
  ('stock.adjust','stock','adjust','Ajustar estoque','Lançar entradas, perdas e ajustes.'),
  ('stock.consume','stock','consume','Baixar consumo','Autorizar consumo automático de insumos.'),
  ('stock.view_costs','stock','view_costs','Visualizar custos','Consultar custos e valores de insumos.'),
  ('purchases.view','purchases','view','Visualizar compras','Consultar compras e fornecedores.'),
  ('purchases.manage','purchases','manage','Gerenciar compras','Criar e editar compras.'),
  ('cash.view','cash','view','Visualizar caixa','Consultar turnos e movimentações de caixa.'),
  ('cash.open','cash','open','Abrir caixa','Abrir turno de caixa.'),
  ('cash.move','cash','move','Movimentar caixa','Lançar entradas e saídas.'),
  ('cash.close','cash','close','Fechar caixa','Fechar turno e conferir valores.'),
  ('cash.history','cash','history','Consultar histórico do caixa','Consultar turnos encerrados.'),
  ('finance.view','finance','view','Visualizar financeiro','Consultar dados financeiros.'),
  ('finance.create','finance','create','Lançar financeiro','Criar lançamentos financeiros.'),
  ('finance.edit','finance','edit','Editar financeiro','Editar lançamentos financeiros.'),
  ('finance.delete','finance','delete','Excluir financeiro','Excluir lançamentos financeiros.'),
  ('accounts.view','accounts','view','Visualizar contas','Consultar contas a pagar e receber.'),
  ('accounts.manage','accounts','manage','Gerenciar contas','Criar, editar e baixar contas.'),
  ('team.view','team','view','Visualizar equipe','Consultar cadastro da equipe.'),
  ('team.manage','team','manage','Gerenciar equipe','Editar dados e situação dos funcionários.'),
  ('team.invite','team','invite','Convidar funcionários','Criar convites e contas individuais.'),
  ('team.manage_permissions','team','manage_permissions','Configurar permissões','Alterar perfis e permissões individuais.'),
  ('reports.view','reports','view','Visualizar relatórios','Consultar relatórios operacionais.'),
  ('reports.export','reports','export','Exportar relatórios','Exportar relatórios e dados.'),
  ('reports.financial','reports','financial','Relatórios financeiros','Consultar relatórios financeiros detalhados.'),
  ('crm.view','crm','view','Visualizar clientes','Consultar cadastro e histórico de clientes.'),
  ('crm.manage','crm','manage','Gerenciar clientes','Editar dados e ações de relacionamento.'),
  ('coupons.manage','coupons','manage','Gerenciar cupons','Criar e editar cupons.'),
  ('loyalty.manage','loyalty','manage','Gerenciar fidelidade','Configurar pontos e recompensas.'),
  ('marketing.manage','marketing','manage','Gerenciar marketing','Gerenciar campanhas e ações de marketing.'),
  ('integrations.view','integrations','view','Visualizar integrações','Consultar integrações sem expor segredos desnecessários.'),
  ('integrations.manage','integrations','manage','Gerenciar integrações','Alterar integrações e credenciais.'),
  ('settings.view','settings','view','Visualizar configurações','Consultar configurações do estabelecimento.'),
  ('settings.manage','settings','manage','Gerenciar configurações','Alterar configurações do estabelecimento.'),
  ('printers.manage','printers','manage','Gerenciar impressoras','Configurar impressoras neste dispositivo.'),
  ('subscription.view','subscription','view','Visualizar assinatura','Consultar plano e situação da assinatura.'),
  ('subscription.manage','subscription','manage','Gerenciar assinatura','Alterar plano e dados de cobrança.'),
  ('fiscal.view','fiscal','view','Visualizar módulo fiscal','Consultar informações do módulo fiscal existente.'),
  ('fiscal.manage','fiscal','manage','Gerenciar módulo fiscal','Alterar configurações do módulo fiscal existente.')
ON CONFLICT (permission_key) DO UPDATE
SET module_key=EXCLUDED.module_key, action_key=EXCLUDED.action_key,
    label=EXCLUDED.label, description=EXCLUDED.description;

-- Proprietário recebe todas as permissões; o helper também garante isso pelo papel owner.
INSERT INTO public.vortex_profile_permissions(profile_key,permission_key,allowed)
SELECT 'owner', permission_key, true
FROM public.vortex_permission_catalog
ON CONFLICT (profile_key,permission_key) DO UPDATE SET allowed=true;

-- Administrador: operação ampla, mas não pode configurar privilégios nem assinatura.
INSERT INTO public.vortex_profile_permissions(profile_key,permission_key,allowed)
SELECT 'administrator', permission_key, true
FROM public.vortex_permission_catalog
WHERE permission_key NOT IN ('team.manage_permissions','subscription.manage')
ON CONFLICT (profile_key,permission_key) DO UPDATE SET allowed=true;

-- Gerente: gestão diária, sem convites/permissões, assinatura ou credenciais de integração.
INSERT INTO public.vortex_profile_permissions(profile_key,permission_key,allowed)
SELECT 'manager', permission_key, true
FROM public.vortex_permission_catalog
WHERE module_key IN ('dashboard','pdv','tables','delivery','kds','catalog','recipes','stock','purchases','cash','finance','accounts','team','reports','crm','coupons','loyalty','marketing','printers','fiscal')
  AND permission_key NOT IN (
    'pdv.cancel','tables.manage_qr','delivery.manual_finish','kds.cancel',
    'stock.view_costs','cash.close','finance.delete','team.invite',
    'team.manage_permissions','reports.financial','fiscal.manage'
  )
ON CONFLICT (profile_key,permission_key) DO UPDATE SET allowed=true;

-- Atendente: vendas e atendimento, sem administração financeira ou configurações.
INSERT INTO public.vortex_profile_permissions(profile_key,permission_key,allowed)
SELECT 'attendant', permission_key, true
FROM public.vortex_permission_catalog
WHERE permission_key IN (
  'dashboard.view','pdv.view','pdv.sell','tables.view','tables.open',
  'tables.close','tables.attend_requests','delivery.view','delivery.manage',
  'delivery.assign','delivery.dispatch','kds.view','catalog.view','cash.view','cash.open','cash.move'
)
ON CONFLICT (profile_key,permission_key) DO UPDATE SET allowed=true;

-- Cozinha: somente fila e atualização de preparo.
INSERT INTO public.vortex_profile_permissions(profile_key,permission_key,allowed)
SELECT 'kitchen', permission_key, true
FROM public.vortex_permission_catalog
WHERE permission_key IN ('dashboard.view','kds.view','kds.update_status')
ON CONFLICT (profile_key,permission_key) DO UPDATE SET allowed=true;

-- Entregador: consulta e confirmação de entregas atribuídas (escopo por pedido será aplicado no módulo/RPC).
INSERT INTO public.vortex_profile_permissions(profile_key,permission_key,allowed)
SELECT 'delivery', permission_key, true
FROM public.vortex_permission_catalog
WHERE permission_key IN ('dashboard.view','delivery.view','delivery.confirm')
ON CONFLICT (profile_key,permission_key) DO UPDATE SET allowed=true;

-- Compatibilidade: o papel técnico existente permanece owner/admin/manager/employee.
ALTER TABLE public.vortex_store_members
  ADD COLUMN IF NOT EXISTS profile_key text,
  ADD COLUMN IF NOT EXISTS display_name text,
  ADD COLUMN IF NOT EXISTS staff_record_id text,
  ADD COLUMN IF NOT EXISTS invitation_status text NOT NULL DEFAULT 'accepted',
  ADD COLUMN IF NOT EXISTS invited_at timestamptz,
  ADD COLUMN IF NOT EXISTS invited_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS invitation_accepted_at timestamptz;

UPDATE public.vortex_store_members
SET profile_key = CASE
  WHEN role = 'owner' THEN 'owner'
  WHEN role = 'admin' THEN 'administrator'
  WHEN role = 'manager' THEN 'manager'
  ELSE 'attendant'
END
WHERE profile_key IS NULL OR profile_key NOT IN
  ('owner','administrator','manager','attendant','kitchen','delivery');

ALTER TABLE public.vortex_store_members
  ALTER COLUMN profile_key SET DEFAULT 'attendant',
  ALTER COLUMN profile_key SET NOT NULL;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.vortex_store_members'::regclass
      AND conname = 'vortex_store_members_invitation_status_check'
  ) THEN
    ALTER TABLE public.vortex_store_members
      ADD CONSTRAINT vortex_store_members_invitation_status_check
      CHECK (invitation_status IN ('pending','accepted','revoked'));
  END IF;
END;
$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.vortex_store_members'::regclass
      AND conname = 'vortex_store_members_profile_key_fkey'
  ) THEN
    ALTER TABLE public.vortex_store_members
      ADD CONSTRAINT vortex_store_members_profile_key_fkey
      FOREIGN KEY (profile_key)
      REFERENCES public.vortex_permission_profiles(profile_key);
  END IF;
END;
$$;

-- Tabelas internas: sem acesso direto pelo navegador. RPCs SECURITY DEFINER farão a mediação.
ALTER TABLE public.vortex_permission_catalog ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.vortex_permission_profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.vortex_profile_permissions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.vortex_member_permissions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.vortex_permission_audit_log ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.vortex_permission_catalog,
  public.vortex_permission_profiles,
  public.vortex_profile_permissions,
  public.vortex_member_permissions,
  public.vortex_permission_audit_log
FROM PUBLIC, anon, authenticated, service_role;

-- Helper de autorização: nega por padrão, valida vínculo ativo e aplica
-- primeiro a exceção individual; na ausência dela, usa o perfil-base.
CREATE OR REPLACE FUNCTION public.vortex_user_has_permission(
  p_store_id uuid,
  p_permission_key text
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $function$
DECLARE
  v_user_id uuid;
  v_role text;
  v_profile_key text;
  v_override boolean;
  v_profile_allowed boolean;
BEGIN
  v_user_id := auth.uid();
  IF v_user_id IS NULL OR p_store_id IS NULL OR p_permission_key IS NULL THEN
    RETURN false;
  END IF;

  SELECT m.role, m.profile_key
    INTO v_role, v_profile_key
  FROM public.vortex_store_members AS m
  WHERE m.store_id = p_store_id
    AND m.user_id = v_user_id
    AND m.status = 'active'
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN false;
  END IF;

  IF v_role = 'owner' OR v_profile_key = 'owner' THEN
    RETURN true;
  END IF;

  SELECT mp.allowed
    INTO v_override
  FROM public.vortex_member_permissions AS mp
  WHERE mp.store_id = p_store_id
    AND mp.user_id = v_user_id
    AND mp.permission_key = p_permission_key;

  IF FOUND THEN
    RETURN v_override;
  END IF;

  SELECT pp.allowed
    INTO v_profile_allowed
  FROM public.vortex_profile_permissions AS pp
  WHERE pp.profile_key = v_profile_key
    AND pp.permission_key = p_permission_key;

  RETURN COALESCE(v_profile_allowed, false);
END;
$function$;

REVOKE ALL ON FUNCTION public.vortex_user_has_permission(uuid,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.vortex_user_has_permission(uuid,text) TO authenticated;

-- Retorna apenas os dados do usuário autenticado e sua lista efetiva de permissões.
CREATE OR REPLACE FUNCTION public.rpc_get_my_permissions()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $function$
DECLARE
  v_user_id uuid;
  v_membership public.vortex_store_members%ROWTYPE;
  v_email text;
  v_permissions jsonb;
  v_count integer;
BEGIN
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Autenticação necessária.';
  END IF;

  SELECT COUNT(*) INTO v_count
  FROM public.vortex_store_members
  WHERE user_id = v_user_id AND status = 'active';

  IF v_count <> 1 THEN
    RAISE EXCEPTION 'A conta precisa ter exatamente um vínculo ativo com estabelecimento.';
  END IF;

  SELECT * INTO v_membership
  FROM public.vortex_store_members
  WHERE user_id = v_user_id AND status = 'active'
  LIMIT 1;

  SELECT email INTO v_email FROM auth.users WHERE id = v_user_id;

  SELECT COALESCE(jsonb_agg(c.permission_key ORDER BY c.module_key,c.action_key),'[]'::jsonb)
    INTO v_permissions
  FROM public.vortex_permission_catalog AS c
  WHERE public.vortex_user_has_permission(v_membership.store_id,c.permission_key);

  RETURN jsonb_build_object(
    'user_id', v_user_id,
    'store_id', v_membership.store_id,
    'display_name', COALESCE(NULLIF(v_membership.display_name,''),v_email,'Funcionário'),
    'email', v_email,
    'role', v_membership.role,
    'profile_key', v_membership.profile_key,
    'staff_record_id', v_membership.staff_record_id,
    'permissions', v_permissions
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_get_my_permissions() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_get_my_permissions() TO authenticated;


-- Ativação segura: somente a própria conta autenticada pode aceitar o convite
-- que foi previamente criado pelo backend confiável.
CREATE OR REPLACE FUNCTION public.rpc_accept_staff_invitation()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $function$
DECLARE
  v_user_id uuid;
  v_email_confirmed_at timestamptz;
  v_store_id uuid;
  v_count integer;
BEGIN
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Autenticação necessária para aceitar o convite.';
  END IF;

  SELECT email_confirmed_at INTO v_email_confirmed_at
  FROM auth.users
  WHERE id = v_user_id;

  IF v_email_confirmed_at IS NULL THEN
    RAISE EXCEPTION 'Confirme o convite recebido por e-mail antes de ativar o acesso.';
  END IF;

  UPDATE public.vortex_store_members
  SET status = 'active',
      invitation_status = 'accepted',
      invitation_accepted_at = now()
  WHERE user_id = v_user_id
    AND status = 'inactive'
    AND invitation_status = 'pending'
  RETURNING store_id INTO v_store_id;

  IF v_store_id IS NULL THEN
    SELECT COUNT(*) INTO v_count
    FROM public.vortex_store_members
    WHERE user_id = v_user_id
      AND status = 'active'
      AND invitation_status = 'accepted';

    IF v_count = 1 THEN
      RETURN jsonb_build_object('success', true, 'already_accepted', true);
    END IF;

    RAISE EXCEPTION 'Não existe convite pendente válido para esta conta.';
  END IF;

  INSERT INTO public.vortex_permission_audit_log(
    store_id, actor_user_id, target_user_id, event_type, details
  ) VALUES (
    v_store_id, v_user_id, v_user_id, 'staff_invitation_accepted',
    jsonb_build_object('accepted_at', now())
  );

  RETURN jsonb_build_object('success', true, 'store_id', v_store_id);
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_accept_staff_invitation() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_accept_staff_invitation() TO authenticated;


-- Operação atômica chamada exclusivamente pelo backend confiável após
-- validar sessão, autorização do ator e senha atual.
CREATE OR REPLACE FUNCTION public.rpc_admin_replace_member_permissions(
  p_store_id uuid,
  p_target_user_id uuid,
  p_actor_user_id uuid,
  p_profile_key text,
  p_overrides jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $function$
DECLARE
  v_target public.vortex_store_members%ROWTYPE;
  v_item jsonb;
  v_key text;
  v_allowed boolean;
  v_count integer := 0;
BEGIN
  IF p_store_id IS NULL OR p_target_user_id IS NULL OR p_actor_user_id IS NULL
     OR p_profile_key NOT IN ('administrator','manager','attendant','kitchen','delivery')
     OR jsonb_typeof(COALESCE(p_overrides,'[]'::jsonb)) <> 'array' THEN
    RAISE EXCEPTION 'Dados de permissões inválidos.';
  END IF;

  SELECT * INTO v_target
  FROM public.vortex_store_members
  WHERE store_id = p_store_id
    AND user_id = p_target_user_id
    AND status = 'active'
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Funcionário ativo não encontrado.';
  END IF;

  IF v_target.role = 'owner' OR v_target.profile_key = 'owner'
     OR p_target_user_id = p_actor_user_id THEN
    RAISE EXCEPTION 'A conta do proprietário ou a própria conta não pode ser alterada por esta operação.';
  END IF;

  IF jsonb_array_length(COALESCE(p_overrides,'[]'::jsonb)) > 100 THEN
    RAISE EXCEPTION 'Quantidade de permissões inválida.';
  END IF;

  -- Valida todos os itens antes de modificar qualquer registro.
  FOR v_item IN SELECT value FROM jsonb_array_elements(COALESCE(p_overrides,'[]'::jsonb))
  LOOP
    v_key := NULLIF(BTRIM(v_item->>'permission_key'),'');
    IF v_key IS NULL OR jsonb_typeof(v_item->'allowed') IS DISTINCT FROM 'boolean'
       OR NOT EXISTS (
         SELECT 1 FROM public.vortex_permission_catalog
         WHERE permission_key = v_key
       ) THEN
      RAISE EXCEPTION 'Uma das permissões informadas é inválida.';
    END IF;
    v_count := v_count + 1;
  END LOOP;

  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(COALESCE(p_overrides,'[]'::jsonb)) AS x(value)
    GROUP BY x.value->>'permission_key'
    HAVING COUNT(*) > 1
  ) THEN
    RAISE EXCEPTION 'A lista contém permissões duplicadas.';
  END IF;

  UPDATE public.vortex_store_members
  SET profile_key = p_profile_key
  WHERE store_id = p_store_id AND user_id = p_target_user_id;

  DELETE FROM public.vortex_member_permissions
  WHERE store_id = p_store_id AND user_id = p_target_user_id;

  FOR v_item IN SELECT value FROM jsonb_array_elements(COALESCE(p_overrides,'[]'::jsonb))
  LOOP
    v_key := BTRIM(v_item->>'permission_key');
    v_allowed := (v_item->>'allowed')::boolean;

    INSERT INTO public.vortex_member_permissions(
      store_id,user_id,permission_key,allowed,granted_by,updated_at
    ) VALUES (
      p_store_id,p_target_user_id,v_key,v_allowed,p_actor_user_id,now()
    );

    INSERT INTO public.vortex_permission_audit_log(
      store_id,actor_user_id,target_user_id,permission_key,
      previous_allowed,new_allowed,event_type,details
    ) VALUES (
      p_store_id,p_actor_user_id,p_target_user_id,v_key,
      NULL,v_allowed,'member_permission_changed',
      jsonb_build_object('profile_key',p_profile_key)
    );
  END LOOP;

  INSERT INTO public.vortex_permission_audit_log(
    store_id,actor_user_id,target_user_id,event_type,details
  ) VALUES (
    p_store_id,p_actor_user_id,p_target_user_id,'member_profile_changed',
    jsonb_build_object('previous_profile_key',v_target.profile_key,'new_profile_key',p_profile_key)
  );

  RETURN jsonb_build_object(
    'success',true,
    'profile_key',p_profile_key,
    'overrides_saved',v_count
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_admin_replace_member_permissions(uuid,uuid,uuid,text,jsonb)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_admin_replace_member_permissions(uuid,uuid,uuid,text,jsonb)
  TO service_role;


-- Catálogo e estado individual só podem ser consultados por quem administra permissões.
CREATE OR REPLACE FUNCTION public.rpc_get_permission_catalog()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $function$
DECLARE
  v_store_id uuid;
  v_result jsonb;
BEGIN
  SELECT store_id INTO v_store_id
  FROM public.vortex_store_members
  WHERE user_id = auth.uid() AND status = 'active'
  LIMIT 1;

  IF v_store_id IS NULL
     OR NOT public.vortex_user_has_permission(v_store_id,'team.manage_permissions') THEN
    RAISE EXCEPTION 'Você não tem permissão para consultar a configuração de permissões.';
  END IF;

  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'permission_key',c.permission_key,
      'module_key',c.module_key,
      'action_key',c.action_key,
      'label',c.label,
      'description',c.description,
      'profiles',COALESCE((
        SELECT jsonb_agg(jsonb_build_object('profile_key',p.profile_key,'label',p.label))
        FROM public.vortex_profile_permissions AS pp
        JOIN public.vortex_permission_profiles AS p ON p.profile_key=pp.profile_key
        WHERE pp.permission_key=c.permission_key AND pp.allowed=true
      ),'[]'::jsonb)
    ) ORDER BY c.module_key,c.action_key
  ),'[]'::jsonb)
  INTO v_result
  FROM public.vortex_permission_catalog AS c;

  RETURN v_result;
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_get_permission_catalog() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_get_permission_catalog() TO authenticated;

CREATE OR REPLACE FUNCTION public.rpc_get_member_permission_settings(p_target_user_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $function$
DECLARE
  v_store_id uuid;
  v_target public.vortex_store_members%ROWTYPE;
  v_overrides jsonb;
BEGIN
  SELECT store_id INTO v_store_id
  FROM public.vortex_store_members
  WHERE user_id = auth.uid() AND status = 'active'
  LIMIT 1;

  IF v_store_id IS NULL
     OR NOT public.vortex_user_has_permission(v_store_id,'team.manage_permissions') THEN
    RAISE EXCEPTION 'Você não tem permissão para configurar funcionários.';
  END IF;

  SELECT * INTO v_target
  FROM public.vortex_store_members
  WHERE store_id=v_store_id AND user_id=p_target_user_id
  LIMIT 1;

  IF NOT FOUND OR v_target.role='owner' OR v_target.profile_key='owner' THEN
    RAISE EXCEPTION 'Funcionário não encontrado ou conta protegida.';
  END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'permission_key',mp.permission_key,'allowed',mp.allowed
  ) ORDER BY mp.permission_key),'[]'::jsonb)
  INTO v_overrides
  FROM public.vortex_member_permissions AS mp
  WHERE mp.store_id=v_store_id AND mp.user_id=p_target_user_id;

  RETURN jsonb_build_object(
    'user_id',v_target.user_id,
    'display_name',v_target.display_name,
    'profile_key',v_target.profile_key,
    'status',v_target.status,
    'overrides',v_overrides
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_get_member_permission_settings(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_get_member_permission_settings(uuid) TO authenticated;


-- Estado de conta limitado ao próprio usuário, para separar cadastro de loja
-- de convite de funcionário no fluxo de login.
CREATE OR REPLACE FUNCTION public.rpc_get_my_account_state()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $function$
DECLARE
  v_user_id uuid;
  v_count integer;
  v_member public.vortex_store_members%ROWTYPE;
BEGIN
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Autenticação necessária.';
  END IF;

  SELECT COUNT(*) INTO v_count
  FROM public.vortex_store_members
  WHERE user_id=v_user_id;

  IF v_count = 0 THEN
    RETURN jsonb_build_object('state','unregistered');
  END IF;
  IF v_count <> 1 THEN
    RETURN jsonb_build_object('state','review_required');
  END IF;

  SELECT * INTO v_member
  FROM public.vortex_store_members
  WHERE user_id=v_user_id
  LIMIT 1;

  IF v_member.invitation_status='pending' AND v_member.status='inactive' THEN
    RETURN jsonb_build_object(
      'state','invitation_pending',
      'store_id',v_member.store_id,
      'invitation_status',v_member.invitation_status
    );
  END IF;

  IF v_member.status='active' AND v_member.invitation_status='accepted' THEN
    RETURN jsonb_build_object('state','active','store_id',v_member.store_id);
  END IF;

  RETURN jsonb_build_object('state','inactive');
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_get_my_account_state() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_get_my_account_state() TO authenticated;


-- Mantém o perfil de Proprietário coerente também nos cadastros criados no futuro.
CREATE OR REPLACE FUNCTION public.vortex_sync_member_profile_key()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $function$
BEGIN
  IF NEW.role='owner' THEN
    NEW.profile_key := 'owner';
  ELSIF NEW.role='admin' AND COALESCE(NEW.profile_key,'attendant')='attendant' THEN
    NEW.profile_key := 'administrator';
  ELSIF NEW.role='manager' AND COALESCE(NEW.profile_key,'attendant')='attendant' THEN
    NEW.profile_key := 'manager';
  ELSIF NEW.role='employee' AND NEW.profile_key IS NULL THEN
    NEW.profile_key := 'attendant';
  END IF;

  IF NEW.profile_key='owner' AND NEW.role<>'owner' THEN
    RAISE EXCEPTION 'O perfil Proprietário não pode ser atribuído a um funcionário.';
  END IF;

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS vortex_store_members_profile_key_sync
  ON public.vortex_store_members;
CREATE TRIGGER vortex_store_members_profile_key_sync
BEFORE INSERT OR UPDATE OF role, profile_key
ON public.vortex_store_members
FOR EACH ROW
EXECUTE FUNCTION public.vortex_sync_member_profile_key();


-- O backend confiável usa a chave service_role; ela não é enviada ao navegador.
GRANT SELECT ON TABLE public.vortex_permission_catalog,
  public.vortex_permission_profiles,
  public.vortex_profile_permissions
TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.vortex_member_permissions
TO service_role;
GRANT SELECT, INSERT ON TABLE public.vortex_permission_audit_log
TO service_role;

CREATE OR REPLACE FUNCTION public.rpc_get_store_operational_settings()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $function$
DECLARE
  v_store_id uuid;
  v_result jsonb;
BEGIN
  SELECT store_id INTO v_store_id
  FROM public.vortex_store_members
  WHERE user_id=auth.uid() AND status='active'
  LIMIT 1;

  IF v_store_id IS NULL THEN
    RAISE EXCEPTION 'Estabelecimento ativo não identificado.';
  END IF;

  SELECT jsonb_build_object(
    'store_name',COALESCE(s.store_name,st.name,''),
    'store_address',COALESCE(s.store_address,''),
    'phone',COALESCE(s.phone,''),
    'taxa',COALESCE(s.taxa,'10,00'),
    'rodape',COALESCE(s.rodape,'')
  ) INTO v_result
  FROM public.vortex_stores AS st
  LEFT JOIN LATERAL (
    SELECT store_name,store_address,phone,taxa,rodape
    FROM public.vortex_store_settings
    WHERE store_id=v_store_id
    ORDER BY id
    LIMIT 1
  ) AS s ON true
  WHERE st.id=v_store_id;

  RETURN COALESCE(v_result,'{}'::jsonb);
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_get_store_operational_settings() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_get_store_operational_settings() TO authenticated;

COMMIT;
