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
  if (!url || !anonKey || !Deno.env.get("VORTEX_APP_ORIGIN")) {
    return response(500, { error: "A validação de desbloqueio não está configurada no servidor." });
  }

  const authorization = req.headers.get("Authorization");
  if (!authorization?.startsWith("Bearer ")) return response(401, { error: "Sessão inválida." });

  const caller = createClient(url, anonKey, {
    auth: { persistSession: false, autoRefreshToken: false },
    global: { headers: { Authorization: authorization } },
  });
  const verifier = createClient(url, anonKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  try {
    const token = authorization.slice(7).trim();
    const { data: userResult, error: userError } = await caller.auth.getUser(token);
    const user = userResult.user;
    if (userError || !user?.email) return response(401, { error: "Sessão inválida. Entre novamente." });

    const { data: context, error: contextError } = await caller.rpc("rpc_get_my_permissions");
    if (contextError || !context?.store_id) {
      return response(403, { error: "Esta conta não possui acesso ativo ao estabelecimento." });
    }

    let body: Record<string, unknown>;
    try { body = await req.json(); }
    catch { return response(400, { error: "Informe sua senha para desbloquear." }); }
    const password = String(body.password || "");
    if (!password || password.length > 1024) return response(400, { error: "Informe uma senha válida." });

    // Cliente isolado e sem persistência: a senha é verificada sem substituir
    // a sessão que está bloqueada no navegador.
    const { data: verified, error: passwordError } = await verifier.auth.signInWithPassword({
      email: user.email,
      password,
    });
    // Não chamar signOut aqui: o logout do Supabase pode revogar outras
    // sessões da mesma conta. Este cliente é temporário e não persiste sessão.

    if (passwordError || verified.user?.id !== user.id) {
      return response(401, { error: "Senha incorreta." });
    }

    return response(200, { success: true });
  } catch (error) {
    console.error("verify-current-password error:", error);
    return response(500, { error: "Não foi possível validar a senha. Tente novamente." });
  }
});
