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
    return response(500, { error: "A configuração segura de permissões não está concluída no servidor." });
  }

  const authorization = req.headers.get("Authorization");
  if (!authorization?.startsWith("Bearer ")) return response(401, { error: "Entre novamente para continuar." });

  const token = authorization.slice(7).trim();
  const caller = createClient(url, anonKey, {
    auth: { persistSession: false, autoRefreshToken: false },
    global: { headers: { Authorization: authorization } },
  });
  const verifier = createClient(url, anonKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const admin = createClient(url, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  try {
    const { data: userResult, error: userError } = await caller.auth.getUser(token);
    const actor = userResult.user;
    if (userError || !actor?.email) return response(401, { error: "Sessão inválida. Entre novamente." });

    const { data: context, error: contextError } = await caller.rpc("rpc_get_my_permissions");
    if (contextError || !context?.store_id || !Array.isArray(context.permissions)) {
      return response(403, { error: "Não foi possível validar o acesso à loja." });
    }
    const actorPermissions = new Set<string>(context.permissions);
    if (!actorPermissions.has("team.manage_permissions")) {
      return response(403, { error: "Somente um usuário autorizado pode configurar permissões." });
    }

    let body: Record<string, unknown>;
    try { body = await req.json(); }
    catch { return response(400, { error: "Dados de configuração inválidos." }); }

    const targetUserId = String(body.target_user_id || "").trim();
    const password = String(body.current_password || "");
    const requestedProfile = body.profile_key == null ? null : String(body.profile_key).trim();
    const rawOverrides = Array.isArray(body.overrides) ? body.overrides : [];

    if (!targetUserId || targetUserId === actor.id || !password) {
      return response(400, { error: "Selecione um funcionário diferente da sua conta e confirme sua senha atual." });
    }
    if (requestedProfile !== null &&
        !["administrator", "manager", "attendant", "kitchen", "delivery"].includes(requestedProfile)) {
      return response(400, { error: "Perfil inválido. O perfil Proprietário não pode ser atribuído ou alterado." });
    }
    if (rawOverrides.length > 100) return response(400, { error: "Quantidade de permissões inválida." });

    // Reautenticação isolada: não substitui a sessão aberta no navegador.
    const { data: verified, error: passwordError } = await verifier.auth.signInWithPassword({
      email: actor.email,
      password,
    });
    if (passwordError || verified.user?.id !== actor.id) {
      return response(401, { error: "A senha atual não confere. Nenhuma permissão foi alterada." });
    }
    await verifier.auth.signOut();

    const storeId = String(context.store_id);
    const { data: target, error: targetError } = await admin
      .from("vortex_store_members")
      .select("store_id,user_id,role,profile_key,status,display_name")
      .eq("store_id", storeId)
      .eq("user_id", targetUserId)
      .maybeSingle();

    if (targetError || !target || target.status !== "active") {
      return response(404, { error: "Funcionário ativo não encontrado nesta loja." });
    }
    if (target.role === "owner" || target.profile_key === "owner") {
      return response(403, { error: "A conta do proprietário é protegida e não pode ser alterada por este recurso." });
    }

    const profileKey = requestedProfile || target.profile_key;
    const { data: profileRows, error: profileError } = await admin
      .from("vortex_profile_permissions")
      .select("permission_key")
      .eq("profile_key", profileKey)
      .eq("allowed", true);

    if (profileError) return response(500, { error: "Não foi possível consultar o perfil selecionado." });
    const profileKeys = new Set<string>((profileRows || []).map((row: { permission_key: string }) => row.permission_key));
    for (const key of profileKeys) {
      if (!actorPermissions.has(key)) {
        return response(403, { error: "O perfil selecionado contém permissões superiores às suas." });
      }
    }

    const normalizedOverrides: Array<{ permission_key: string; allowed: boolean }> = [];
    const seen = new Set<string>();
    for (const item of rawOverrides) {
      if (!item || typeof item !== "object") return response(400, { error: "Uma das permissões informadas é inválida." });
      const key = String((item as Record<string, unknown>).permission_key || "").trim();
      const allowed = (item as Record<string, unknown>).allowed;
      if (!key || typeof allowed !== "boolean" || seen.has(key)) {
        return response(400, { error: "Há permissões duplicadas ou com valores inválidos." });
      }
      seen.add(key);
      normalizedOverrides.push({ permission_key: key, allowed });
    }

    if (normalizedOverrides.length) {
      const keys = normalizedOverrides.map((item) => item.permission_key);
      const { data: known, error: knownError } = await admin
        .from("vortex_permission_catalog")
        .select("permission_key")
        .in("permission_key", keys);
      if (knownError || (known || []).length !== keys.length) {
        return response(400, { error: "A lista contém uma permissão desconhecida." });
      }
      if (normalizedOverrides.some((item) => item.allowed && !actorPermissions.has(item.permission_key))) {
        return response(403, { error: "Você não pode conceder uma permissão que não possui." });
      }
    }

    // A gravação do perfil, das exceções e da auditoria ocorre em uma única
    // transação no banco; não há janela com permissões parcialmente aplicadas.
    const { data: saved, error: saveError } = await admin.rpc("rpc_admin_replace_member_permissions", {
      p_store_id: storeId,
      p_target_user_id: targetUserId,
      p_actor_user_id: actor.id,
      p_profile_key: profileKey,
      p_overrides: normalizedOverrides,
    });
    if (saveError || !saved?.success) {
      return response(500, { error: saveError?.message || "Não foi possível aplicar as permissões." });
    }

    return response(200, {
      success: true,
      profile_key: profileKey,
      overrides_saved: saved.overrides_saved,
      message: "Permissões atualizadas e registradas no histórico de segurança.",
    });
  } catch (error) {
    console.error("manage-staff-permissions error:", error);
    return response(500, { error: "Não foi possível salvar as permissões. Tente novamente." });
  }
});
