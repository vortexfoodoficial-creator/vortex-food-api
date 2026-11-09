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

  const url = Deno.env.get("SUPABASE_URL");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !anonKey || !serviceKey || !Deno.env.get("VORTEX_APP_ORIGIN")) {
    return response(500, { error: "A função de equipe não está configurada no servidor." });
  }

  const authorization = req.headers.get("Authorization");
  if (!authorization?.startsWith("Bearer ")) return response(401, { error: "Entre novamente para continuar." });

  const caller = createClient(url, anonKey, {
    auth: { persistSession: false, autoRefreshToken: false },
    global: { headers: { Authorization: authorization } },
  });
  const admin = createClient(url, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  try {
    const token = authorization.slice(7).trim();
    const { data: userData, error: userError } = await caller.auth.getUser(token);
    if (userError || !userData.user) return response(401, { error: "Sessão inválida." });

    const actorId = userData.user.id;
    const { data: context, error: contextError } = await caller.rpc("rpc_get_my_permissions");
    if (contextError || !context?.store_id || !context.permissions?.includes("team.manage")) {
      return response(403, { error: "Seu perfil não pode gerenciar a equipe." });
    }

    let body: Record<string, unknown>;
    try { body = await req.json(); }
    catch { return response(400, { error: "Dados inválidos." }); }

    const staffRecordId = String(body.staff_record_id || "").trim();
    const action = String(body.action || "").trim();
    if (!staffRecordId || !["deactivate", "reactivate"].includes(action)) {
      return response(400, { error: "Informe o funcionário e a ação desejada." });
    }

    const storeId = String(context.store_id);
    const { data: document, error: readError } = await admin
      .from("vortex_store_documents")
      .select("data")
      .eq("store_id", storeId)
      .eq("document_key", "staff")
      .maybeSingle();

    if (readError || !Array.isArray(document?.data)) return response(409, { error: "Não foi possível localizar a equipe sincronizada." });
    const staffList = document.data as Array<Record<string, unknown>>;
    const index = staffList.findIndex((item) => String(item.id || "") === staffRecordId);
    if (index < 0) return response(404, { error: "Colaborador não encontrado." });

    const staff = staffList[index];
    const targetUserId = String(staff.authUserId || "");
    if (targetUserId && targetUserId === actorId) {
      return response(403, { error: "Você não pode bloquear ou reativar a própria conta por este recurso." });
    }
    if (targetUserId) {
      const { data: member, error: memberError } = await admin
        .from("vortex_store_members")
        .select("role,profile_key,status,invitation_status")
        .eq("store_id", storeId)
        .eq("user_id", targetUserId)
        .maybeSingle();

      if (memberError || !member) return response(404, { error: "Vínculo da conta não encontrado." });
      if (member.role === "owner" || member.profile_key === "owner") {
        return response(403, { error: "A conta do proprietário não pode ser desativada por este recurso." });
      }
      if (member.profile_key === "administrator" && context.profile_key !== "owner") {
        return response(403, { error: "Somente o proprietário pode alterar o acesso de outro administrador." });
      }
      if (member.profile_key === "manager" && !["owner", "administrator"].includes(String(context.profile_key))) {
        return response(403, { error: "Seu perfil não pode alterar o acesso de um gerente." });
      }


    }

    const { data: accountUpdate, error: accountUpdateError } = await admin.rpc(
      "rpc_admin_set_staff_account_status",
      {
        p_store_id: storeId,
        p_staff_record_id: staffRecordId,
        p_target_user_id: targetUserId || null,
        p_actor_user_id: actorId,
        p_action: action,
      },
    );

    if (accountUpdateError || !accountUpdate?.success) {
      console.error("manage-staff-account atomic update error:", accountUpdateError);
      return response(500, { error: accountUpdateError?.message || "Não foi possível atualizar a conta e registrar a auditoria." });
    }

    return response(200, {
      success: true,
      status: action === "deactivate" ? "inativo" : "ativo",
      message: action === "deactivate" ? "Acesso do funcionário bloqueado." : "Acesso do funcionário reativado.",
    });
  } catch (error) {
    console.error("manage-staff-account error:", error);
    return response(500, { error: "Não foi possível atualizar o acesso do funcionário." });
  }
});
