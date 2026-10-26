// supabase.js - Módulo central de conexão com o Supabase
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
    rodape: settingsData.rodape || ''
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

// Helper para sincronizar vendas (History / Dashboard / Financeiro)
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
    payMethod: saleData.payMethod || saleData.pay_method || saleData.paymentMethod || 'PIX',
    status: saleData.status || 'finished',
    date: saleData.date || new Date().toISOString().split('T')[0],
    time: saleData.time || new Date().toLocaleTimeString('pt-BR', { hour: '2-digit', minute: '2-digit' }),
    items: saleData.items || []
  };

  const { data, error } = await supabase.from('vortex_sales_history').upsert([record]);
  if (error) console.error('Erro ao salvar venda no Supabase (vortex_sales_history):', error);
  return { data, error };
}

async function dbFetchSales() {
  const supabase = getSupabase();
  if (!supabase) return [];
  // Removido o .order('created_at') para evitar falhas caso a coluna não exista na tabela SQL
  const { data, error } = await supabase.from('vortex_sales_history').select('*');
  if (error) {
    console.error('Erro ao buscar vendas no Supabase:', error);
    return [];
  }
  if (!data) return [];
  return data.map(item => ({
    id: item.id,
    client: item.client,
    channel: item.channel,
    total: parseFloat(item.total) || 0,
    subtotal: parseFloat(item.subtotal) || 0,
    discount: parseFloat(item.discount) || 0,
    payMethod: item.payMethod || item.pay_method || 'Pix',
    status: item.status,
    date: item.date,
    time: item.time,
    items: item.items || []
  }));
}

// Helper para KDS (Cozinha & Delivery)
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
    status: orderData.status || 'new',
    code: orderData.code || ''
  };

  const { data, error } = await supabase.from('vortex_kds_orders').upsert([record]);
  if (error) console.error('Erro ao salvar pedido KDS no Supabase (vortex_kds_orders):', error);
  return { data, error };
}

async function dbFetchKdsOrders() {
  const supabase = getSupabase();
  if (!supabase) return [];
  // Removido o .order('created_at') para garantir estabilidade na busca
  const { data, error } = await supabase.from('vortex_kds_orders').select('*');
  if (error) {
    console.error('Erro ao buscar pedidos KDS no Supabase:', error);
    return [];
  }
  if (!data) return [];
  return data.map(item => ({
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
    status: item.status,
    code: item.code
  }));
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
    date: entryData.date || new Date().toISOString().split('T')[0]
  }]);
  if (error) console.error('Erro ao salvar lançamento no Supabase:', error);
  return { data, error };
}

async function dbFetchFinancialEntries() {
  const supabase = getSupabase();
  if (!supabase) return [];
  // Removido o .order('created_at') para blindar contra colunas ausentes
  const { data, error } = await supabase.from('vortex_financial').select('*');
  if (error) {
    console.error('Erro ao buscar financeiros no Supabase:', error);
    return [];
  }
  return data || [];
}

// Helpers para Catálogo e Fichas Técnicas
async function dbFetchCatalog() {
  const supabase = getSupabase();
  if (!supabase) return { products: [] };
  const { data, error } = await supabase.from('vortex_products_catalog').select('*');
  if (error) return { products: [] };
  return { products: data || [] };
}

async function dbFetchRecipes() {
  const supabase = getSupabase();
  if (!supabase) return [];
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
