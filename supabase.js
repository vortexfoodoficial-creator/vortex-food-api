// supabase.js - Módulo central de conexão, persistência e sincronização do Vortex Food
const SUPABASE_URL = 'https://oasxlmfwkkubabyvqama.supabase.co';
const SUPABASE_ANON_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im9hc3hsbWZ3a2t1YmFieXZxYW1hIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTIzNDU0OTAsImV4cCI6MjEwNzkyMTQ5MH0.WiNjGtnve1frVt07mcKV3-09j7xH8o6me5lC2iA-YCE';

// Função helper para garantir conexão sempre ativa e evitar 'undefined'
function getSupabase() {
  if (window.supabaseClient) {
    return window.supabaseClient;
  }
  if (window.supabase && typeof window.supabase.createClient === 'function') {
    window.supabaseClient = window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY);
    return window.supabaseClient;
  }
  console.warn('SDK do Supabase ainda não foi carregado pelo navegador.');
  return null;
}

// Helper para Configurações do Estabelecimento (Módulo 1 & Delivery)
async function dbSaveStoreSettings(settingsData) {
  const supabase = getSupabase();
  if (!supabase) return { error: 'Supabase não inicializado' };

  const record = {
    id: 1, // Registro único da loja
    store_name: settingsData.store_name || settingsData.nome || 'Vortex Food',
    store_address: settingsData.store_address || settingsData.endereco || '',
    cnpj: settingsData.cnpj || '',
    phone: settingsData.phone || settingsData.tel || '',
    email: settingsData.email || '',
    taxa: settingsData.taxa || '10,00',
    rodape: settingsData.rodape || '',
    updated_at: new Date().toISOString()
  };

  const { data, error } = await supabase.from('vortex_store_settings').upsert([record]);
  if (error) console.error('Erro ao salvar configurações no Supabase:', error);
  return { data, error };
}

async function dbFetchStoreSettings() {
  const supabase = getSupabase();
  if (!supabase) return null;
  
  const { data, error } = await supabase.from('vortex_store_settings').select('*').limit(1).maybeSingle();
  if (error) {
    console.error('Erro ao buscar configurações no Supabase:', error);
    return null;
  }
  return data;
}

// Helper central para sincronizar vendas (History / Dashboard / Financeiro / Relatórios)
async function dbSaveSale(saleData) {
  const supabase = getSupabase();
  if (!supabase) return { error: 'Supabase não inicializado' };
  
  const record = {
    id: String(saleData.id),
    client: saleData.client || 'Cliente Balcão',
    channel: saleData.channel || 'pdv',
    total: parseFloat(saleData.total) || 0,
    subtotal: parseFloat(saleData.subtotal) || 0,
    discount: parseFloat(saleData.discount) || 0,
    pay_method: saleData.payMethod || saleData.pay_method || saleData.paymentMethod || 'PIX',
    status: saleData.status || 'completed', // 'completed' ou 'cancelled', etc.
    financial_status: saleData.financialStatus || saleData.financial_status || 'paid',
    date: saleData.date || new Date().toISOString().split('T')[0],
    time: saleData.time || new Date().toLocaleTimeString('pt-BR', { hour: '2-digit', minute: '2-digit' }),
    items: saleData.items || [],
    updated_at: new Date().toISOString()
  };

  const { data, error } = await supabase.from('vortex_sales_history').upsert([record]);
  if (error) console.error('Erro ao salvar venda no Supabase (vortex_sales_history):', error);
  
  // Sincronização auxiliar com LocalStorage para suporte offline/cache
  try {
    let localHistory = JSON.parse(localStorage.getItem('vortex_sales_history')) || [];
    const idx = localHistory.findIndex(s => String(s.id) === String(record.id));
    if (idx >= 0) {
      localHistory[idx] = { ...localHistory[idx], ...record };
    } else {
      localHistory.unshift(record);
    }
    localStorage.setItem('vortex_sales_history', JSON.stringify(localHistory));
  } catch(e) {
    console.warn('Erro ao atualizar cache local de vendas:', e);
  }

  return { data, error };
}

async function dbFetchSales() {
  const supabase = getSupabase();
  if (!supabase) {
    // Fallback seguro para LocalStorage se offline
    return JSON.parse(localStorage.getItem('vortex_sales_history')) || [];
  }
  
  const { data, error } = await supabase.from('vortex_sales_history').select('*');
  if (error) {
    console.error('Erro ao buscar vendas no Supabase, usando cache local:', error);
    return JSON.parse(localStorage.getItem('vortex_sales_history')) || [];
  }
  if (!data) return [];
  
  const mapped = data.map(item => ({
    id: item.id,
    client: item.client,
    channel: item.channel,
    total: parseFloat(item.total) || 0,
    subtotal: parseFloat(item.subtotal) || 0,
    discount: parseFloat(item.discount) || 0,
    payMethod: item.payMethod || item.pay_method || 'Pix',
    status: item.status || 'completed',
    financialStatus: item.financial_status || 'paid',
    cancellationReason: item.cancellation_reason || '',
    cancelledAt: item.cancelled_at || null,
    date: item.date,
    time: item.time,
    items: item.items || []
  }));

  // Atualiza cache local com os dados mais recentes do servidor
  try {
    localStorage.setItem('vortex_sales_history', JSON.stringify(mapped));
  } catch(e) {}

  return mapped;
}

// Helper central para KDS (Cozinha & Delivery)
async function dbSaveKdsOrder(orderData) {
  const supabase = getSupabase();
  if (!supabase) return { error: 'Supabase não inicializado' };

  const record = {
    id: String(orderData.id),
    origin: orderData.origin || 'Balcão',
    client: orderData.client || 'Cliente Balcão',
    address: orderData.address || '',
    payment: orderData.payment || orderData.payMethod || 'Dinheiro',
    cashGiven: parseFloat(orderData.cashGiven || 0),
    change: parseFloat(orderData.change || 0),
    time: orderData.time || new Date().toLocaleTimeString('pt-BR', { hour: '2-digit', minute: '2-digit' }),
    date: orderData.date || new Date().toISOString().split('T')[0],
    dateFormatted: orderData.dateFormatted || new Date().toLocaleDateString('pt-BR'),
    items: orderData.items || [],
    total: parseFloat(orderData.total) || 0,
    observation: orderData.observation || '',
    status: orderData.status || 'received',
    financial_status: orderData.financialStatus || 'paid',
    code: orderData.code || '',
    updated_at: new Date().toISOString()
  };

  const { data, error } = await supabase.from('vortex_kds_orders').upsert([record]);
  if (error) console.error('Erro ao salvar pedido KDS no Supabase (vortex_kds_orders):', error);
  
  // Atualiza cache local do KDS
  try {
    let localKds = JSON.parse(localStorage.getItem('vortex_kds_orders')) || [];
    const idx = localKds.findIndex(o => String(o.id) === String(record.id));
    if (idx >= 0) {
      localKds[idx] = { ...localKds[idx], ...record };
    } else {
      localKds.unshift(record);
    }
    localStorage.setItem('vortex_kds_orders', JSON.stringify(localKds));
  } catch(e) {}

  return { data, error };
}

async function dbFetchKdsOrders() {
  const supabase = getSupabase();
  if (!supabase) {
    return JSON.parse(localStorage.getItem('vortex_kds_orders')) || [];
  }

  const { data, error } = await supabase.from('vortex_kds_orders').select('*');
  if (error) {
    console.error('Erro ao buscar pedidos KDS no Supabase:', error);
    return JSON.parse(localStorage.getItem('vortex_kds_orders')) || [];
  }
  if (!data) return [];

  const mapped = data.map(item => ({
    id: item.id,
    origin: item.origin,
    client: item.client,
    address: item.address,
    payment: item.payment,
    cashGiven: item.cashGiven,
    change: item.change,
    time: item.time,
    date: item.date,
    dateFormatted: item.dateFormatted,
    items: item.items || [],
    total: parseFloat(item.total) || 0,
    observation: item.observation,
    status: item.status || 'received',
    financialStatus: item.financial_status || 'paid',
    code: item.code
  }));

  try {
    localStorage.setItem('vortex_kds_orders', JSON.stringify(mapped));
  } catch(e) {}

  return mapped;
}

/**
 * REGRA CENTRAL DE CANCELAMENTO IDEMPOTENTE
 * Cancela um pedido de forma atômica no KDS e remove seu impacto do faturamento no Histórico de Vendas,
 * preservando o registro para fins de auditoria e relatórios.
 */
async function dbCancelOrder(orderId, reason = 'Cancelado via operação') {
  const supabase = getSupabase();
  const cancelTimestamp = new Date().toISOString();

  // 1. Tenta executar via RPC atômica no PostgreSQL se disponível
  if (supabase) {
    try {
      const { data: rpcData, error: rpcError } = await supabase.rpc('rpc_cancel_order', {
        p_order_id: String(orderId),
        p_reason: reason
      });
      if (!rpcError && rpcData && rpcData.success) {
        console.log('Cancelamento atômico executado via RPC:', rpcData.message);
        // Atualiza caches locais correspondentes
        updateLocalCachesAfterCancel(orderId, reason, cancelTimestamp);
        return { success: true };
      }
    } catch (err) {
      console.warn('RPC rpc_cancel_order indisponível, executando fallback via cliente:', err);
    }

    // 2. Fallback via cliente (atualização sequencial segura em ambas as tabelas)
    try {
      await supabase.from('vortex_sales_history').update({
        status: 'cancelled',
        financial_status: 'reversed',
        cancellation_reason: reason,
        cancelled_at: cancelTimestamp,
        updated_at: cancelTimestamp
      }).eq('id', String(orderId));

      await supabase.from('vortex_kds_orders').update({
        status: 'cancelled',
        cancellation_reason: reason,
        cancelled_at: cancelTimestamp,
        updated_at: cancelTimestamp
      }).eq('id', String(orderId));

      updateLocalCachesAfterCancel(orderId, reason, cancelTimestamp);
      return { success: true };
    } catch (clientErr) {
      console.error('Erro no fallback de cancelamento via cliente:', clientErr);
      return { success: false, error: clientErr };
    }
  } else {
    // Modo estritamente offline / LocalStorage
    updateLocalCachesAfterCancel(orderId, reason, cancelTimestamp);
    return { success: true, offline: true };
  }
}

function updateLocalCachesAfterCancel(orderId, reason, timestamp) {
  try {
    // Atualiza vendas locais
    let sales = JSON.parse(localStorage.getItem('vortex_sales_history')) || [];
    sales = sales.map(s => {
      if (String(s.id) === String(orderId)) {
        return { ...s, status: 'cancelled', financialStatus: 'reversed', cancellationReason: reason, cancelledAt: timestamp };
      }
      return s;
    });
    localStorage.setItem('vortex_sales_history', JSON.stringify(sales));

    // Atualiza KDS local
    let kds = JSON.parse(localStorage.getItem('vortex_kds_orders')) || [];
    kds = kds.map(k => {
      if (String(k.id) === String(orderId)) {
        return { ...k, status: 'cancelled', cancellationReason: reason, cancelledAt: timestamp };
      }
      return k;
    });
    localStorage.setItem('vortex_kds_orders', JSON.stringify(kds));
  } catch (e) {
    console.error('Erro ao atualizar caches locais após cancelamento:', e);
  }
}

// Helper para Integrações de Delivery na Nuvem
async function dbSaveIntegration(platform, credentials) {
  const supabase = getSupabase();
  if (!supabase) return { error: 'Supabase não inicializado' };
  const record = {
    platform: platform,
    connected: true,
    credentials: credentials,
    updated_at: new Date().toISOString()
  };
  const { data, error } = await supabase.from('vortex_integrations').upsert([record], { onConflict: 'platform' });
  if (error) console.error('Erro ao salvar integração no Supabase:', error);
  return { data, error };
}

async function dbFetchIntegrations() {
  const supabase = getSupabase();
  if (!supabase) return [];
  const { data, error } = await supabase.from('vortex_integrations').select('*');
  if (error) {
    console.error('Erro ao buscar integrações no Supabase:', error);
    return [];
  }
  return data || [];
}

// Helper para Lançamentos Financeiros
async function dbSaveFinancialEntry(entryData) {
  const supabase = getSupabase();
  if (!supabase) return { error: 'Supabase não inicializado' };
  const { data, error } = await supabase.from('vortex_financial').upsert([{
    id: String(entryData.id),
    type: entryData.type,
    description: entryData.description,
    value: parseFloat(entryData.value) || 0,
    date: entryData.date || new Date().toISOString().split('T')[0],
    updated_at: new Date().toISOString()
  }]);
  if (error) console.error('Erro ao salvar lançamento no Supabase:', error);
  return { data, error };
}

async function dbFetchFinancialEntries() {
  const supabase = getSupabase();
  if (!supabase) return JSON.parse(localStorage.getItem('vortex_financial_entries')) || [];
  
  const { data, error } = await supabase.from('vortex_financial').select('*');
  if (error) {
    console.error('Erro ao buscar financeiros no Supabase:', error);
    return JSON.parse(localStorage.getItem('vortex_financial_entries')) || [];
  }
  return data || [];
}

// Helpers para Catálogo e Fichas Técnicas
async function dbFetchCatalog() {
  const supabase = getSupabase();
  if (!supabase) return { products: JSON.parse(localStorage.getItem('vortex_products_catalog')) || [] };
  const { data, error } = await supabase.from('vortex_products_catalog').select('*');
  if (error) return { products: [] };
  return { products: data || [] };
}

async function dbFetchRecipes() {
  const supabase = getSupabase();
  if (!supabase) return JSON.parse(localStorage.getItem('vortex_recipes_catalog')) || [];
  const { data, error } = await supabase.from('vortex_recipes_catalog').select('*');
  if (error) return [];
  return data || [];
}

// Exclusão genérica
async function dbDeleteRecord(tableName, id) {
  const supabase = getSupabase();
  if (!supabase) return { error: 'Supabase não inicializado' };
  const { data, error } = await supabase.from(tableName).delete().eq('id', String(id));
  if (error) console.error(`Erro ao deletar id ${id} da tabela ${tableName}:`, error);
  return { data, error };
}

// ==========================================
// FUNÇÕES RESULT (PADRÃO ROBUSTO DE RETORNO)
// ==========================================

async function dbFetchSalesResult() {
  try {
    const data = await dbFetchSales();
    return { data, error: null };
  } catch (err) {
    return { data: [], error: err };
  }
}

async function dbFetchKdsOrdersResult() {
  try {
    const data = await dbFetchKdsOrders();
    return { data, error: null };
  } catch (err) {
    return { data: [], error: err };
  }
}

async function dbFetchRecipesResult() {
  try {
    const data = await dbFetchRecipes();
    return { data, error: null };
  } catch (err) {
    return { data: [], error: err };
  }
}

async function dbFetchFinancialEntriesResult() {
  try {
    const data = await dbFetchFinancialEntries();
    return { data, error: null };
  } catch (err) {
    return { data: [], error: err };
  }
}

async function dbFetchCatalogResult() {
  try {
    const res = await dbFetchCatalog();
    return { data: res, error: null };
  } catch (err) {
    return { data: { products: [] }, error: err };
  }
}

async function dbFetchStoreSettingsResult() {
  try {
    const data = await dbFetchStoreSettings();
    return { data, error: null };
  } catch (err) {
    return { data: null, error: err };
  }
}
