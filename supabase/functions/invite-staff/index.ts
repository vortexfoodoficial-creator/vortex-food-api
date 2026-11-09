import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": Deno.env.get("VORTEX_APP_ORIGIN") || "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Content-Type": "application/json",
};

function response(status: number, body: Record<string, unknown>) {
  return new Response(JSON.stringify(body), { status, headers: corsHeaders });
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return response(405, { error: "Método não permitido." });

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const appUrl = Deno.env.get("VORTEX_APP_URL");

  if (!supabaseUrl || !anonKey || !serviceRoleKey || !appUrl || !Deno.env.get("VORTEX_APP_ORIGIN")) {
    return response(500, { error: "A função de convites não está configurada no servidor." });
  }

  const authorization = req.headers.get("Authorization");
  if (!authorization?.startsWith("Bearer ")) {
    return response(401, { error: "Entre novamente para continuar." });
  }

  const token = authorization.slice("Bearer ".length).trim();
  const caller = createClient(supabaseUrl, anonKey, {
    auth: { persistSession: false, autoRefreshToken: false },
    global: { headers: { Authorization: authorization } },
  });
  const admin = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  try {
    const { data: userData, error: userError } = await caller.auth.getUser(token);
    if (userError || !userData.user) {
      return response(401, { error: "Sessão inválida. Entre novamente." });
    }

    const actorId = userData.user.id;
    const { data: context, error: contextError } = await caller.rpc("rpc_get_my_permissions");
    if (contextError || !context?.store_id || !Array.isArray(context.permissions)) {
      return response(403, { error: "Não foi possível validar suas permissões nesta loja." });
    }

    const actorPermissions = new Set<string>(context.permissions);
    if (!actorPermissions.has("team.invite")) {
      return response(403, { error: "Seu perfil não tem permissão para convidar funcionários." });
    }

    let body: Record<string, unknown>;
    try {
      body = await req.json();
    } catch {
      return response(400, { error: "Dados do convite inválidos." });
    }

    const staffRecordId = String(body.staff_record_id || "").trim();
    const email = String(body.email || "").trim().toLowerCase();
    const profileKey = String(body.profile_key || "").trim();

    if (!staffRecordId || staffRecordId.length > 120 ||
        !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email) || email.length > 254) {
      return response(400, { error: "Informe um e-mail válido e selecione um colaborador cadastrado." });
    }
    if (!["administrator", "manager", "attendant", "kitchen", "delivery"].includes(profileKey)) {
      return response(400, { error: "Perfil de acesso inválido. O perfil Proprietário não pode ser atribuído por convite." });
    }
    if (profileKey === "administrator" && context.profile_key !== "owner") {
      return response(403, { error: "Somente o proprietário pode convidar outro administrador." });
    }

    const storeId = String(context.store_id);

    // O nome e a existência do colaborador são confirmados no documento da loja;
    // o navegador não pode inventar um funcionário ou escolher outro estabelecimento.
    const { data: staffDocument, error: staffReadError } = await admin
      .from("vortex_store_documents")
      .select("data")
      .eq("store_id", storeId)
      .eq("document_key", "staff")
      .maybeSingle();

    if (staffReadError || !Array.isArray(staffDocument?.data)) {
      return response(409, { error: "Não foi possível localizar a equipe sincronizada da loja. Salve o cadastro do colaborador e tente novamente." });
    }

    const staffList = staffDocument.data as Array<Record<string, unknown>>;
    const staffIndex = staffList.findIndex((member) => String(member.id || "") === staffRecordId);
    if (staffIndex < 0) {
      return response(404, { error: "O colaborador não foi encontrado na equipe desta loja." });
    }

    const staffRecord = staffList[staffIndex];
    if (String(staffRecord.status || "ativo").toLowerCase() !== "ativo") {
      return response(409, { error: "Ative o cadastro do colaborador antes de enviar o convite." });
    }
    if (staffRecord.authUserId) {
      return response(409, { error: "Este colaborador já possui uma conta vinculada." });
    }
    if (String(staffRecord.email || '').trim().toLowerCase() !== email) {
      return response(409, { error: "O e-mail precisa ser salvo no cadastro do colaborador antes de enviar o convite." });
    }

    // Não permitir que o responsável pelo convite conceda poderes que ele próprio não possui.
    const { data: targetPermissions, error: targetPermissionsError } = await admin
      .from("vortex_profile_permissions")
      .select("permission_key")
      .eq("profile_key", profileKey)
      .eq("allowed", true);

    if (targetPermissionsError) {
      return response(500, { error: "Não foi possível validar o perfil selecionado." });
    }
    const exceedsActor = (targetPermissions || []).some(
      (item: { permission_key: string }) => !actorPermissions.has(item.permission_key),
    );
    if (exceedsActor) {
      return response(403, { error: "Você não pode atribuir um perfil com permissões superiores às suas." });
    }

    const displayName = String(staffRecord.name || "").trim();
    if (!displayName) {
      return response(400, { error: "O cadastro do colaborador precisa ter um nome." });
    }

    let invitedUserId = '';
    let existingAccount = false;
    const inviteResult = await admin.auth.admin.inviteUserByEmail(email, {
      redirectTo: appUrl.replace(/\/$/, "") + "/login.html",
      data: {
        vortex_store_id: storeId,
        vortex_staff_record_id: staffRecordId,
      },
    });

    if (!inviteResult.error && inviteResult.data.user) {
      invitedUserId = inviteResult.data.user.id;
    } else if (/already registered|already been registered|user already exists/i.test(inviteResult.error?.message || '')) {
      const { data: usersResult, error: usersError } = await admin.auth.admin.listUsers({ page: 1, perPage: 1000 });
      const existingUser = (usersResult?.users || []).find((user) => String(user.email || '').toLowerCase() === email);
      if (usersError || !existingUser) {
        return response(409, { error: "Este e-mail já possui uma conta. Não foi possível localizar o usuário com segurança." });
      }
      invitedUserId = existingUser.id;
      existingAccount = true;
    } else {
      return response(409, {
        error: inviteResult.error?.message || "Não foi possível enviar o convite. Verifique o e-mail e tente novamente.",
      });
    }

    // O modelo atual mantém uma conta vinculada a uma única loja.
    const { data: existingMemberships, error: membershipsReadError } = await admin
      .from("vortex_store_members")
      .select("store_id,role,staff_record_id,status")
      .eq("user_id", invitedUserId);

    if (membershipsReadError) {
      return response(500, { error: "Não foi possível verificar os vínculos existentes desta conta." });
    }
    const otherStoreMembership = (existingMemberships || []).find((member) => String(member.store_id) !== storeId);
    if (otherStoreMembership) {
      return response(409, { error: "Esta conta já está vinculada a outro estabelecimento. O Vortex ainda trabalha com uma loja por usuário." });
    }
    const sameStoreMembership = (existingMemberships || []).find((member) => String(member.store_id) === storeId);
    if (sameStoreMembership && (sameStoreMembership.role === "owner" || String(sameStoreMembership.staff_record_id || "") !== staffRecordId)) {
      return response(409, { error: "Esta conta já está vinculada a outro cadastro ou é a conta do proprietário." });
    }

    if (sameStoreMembership) {
      const { error: membershipError } = await admin
        .from("vortex_store_members")
        .update({
          role: "employee",
          status: "inactive",
          profile_key: profileKey,
          display_name: displayName,
          staff_record_id: staffRecordId,
          invitation_status: "pending",
          invited_at: new Date().toISOString(),
          invited_by: actorId,
        })
        .eq("store_id", storeId)
        .eq("user_id", invitedUserId);
      if (membershipError) return response(500, { error: "Não foi possível preparar o vínculo pendente deste funcionário." });
    } else {
      const { error: membershipError } = await admin
        .from("vortex_store_members")
        .insert({
          store_id: storeId,
          user_id: invitedUserId,
          role: "employee",
          status: "inactive",
          profile_key: profileKey,
          display_name: displayName,
          staff_record_id: staffRecordId,
          invitation_status: "pending",
          invited_at: new Date().toISOString(),
          invited_by: actorId,
        });

      if (membershipError) {
        return response(500, {
          error: "O convite foi criado, mas não foi possível concluir o vínculo da equipe. O acesso continua bloqueado; contate o suporte antes de reenviar.",
        });
      }
    }

    const updatedStaff = staffList.map((member, index) => index === staffIndex
      ? {
          ...member,
          email,
          authUserId: invitedUserId,
          profileKey,
          invitationStatus: "pending",
          invitedAt: new Date().toISOString(),
        }
      : member);

    const { error: staffUpdateError } = await admin
      .from("vortex_store_documents")
      .update({ data: updatedStaff, updated_at: new Date().toISOString() })
      .eq("store_id", storeId)
      .eq("document_key", "staff");

    if (staffUpdateError) {
      await admin.from("vortex_store_members")
        .update({ status: "inactive", invitation_status: "revoked" })
        .eq("store_id", storeId)
        .eq("user_id", invitedUserId);

      return response(500, {
        error: "O convite foi enviado, mas não foi possível vincular o cadastro da equipe. O acesso permanece bloqueado; revise o cadastro antes de reenviar.",
      });
    }

    await admin.from("vortex_permission_audit_log").insert({
      store_id: storeId,
      actor_user_id: actorId,
      target_user_id: invitedUserId,
      event_type: "staff_invited",
      details: {
        staff_record_id: staffRecordId,
        email,
        profile_key: profileKey,
      },
    });

    return response(200, {
      success: true,
      invitation_status: "pending",
      user_id: invitedUserId,
      existing_account: existingAccount,
      message: existingAccount
        ? "Este e-mail já possui uma conta. Nenhum novo e-mail de convite foi enviado; peça ao funcionário para entrar com a senha atual. O vínculo será ativado no primeiro acesso."
        : "Convite enviado. O funcionário precisa aceitar o e-mail e criar a própria senha antes de acessar o Vortex Food.",
    });
  } catch (error) {
    console.error("invite-staff error:", error);
    return response(500, { error: "Ocorreu um erro ao processar o convite. Tente novamente." });
  }
});
