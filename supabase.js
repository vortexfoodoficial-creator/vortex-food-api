// supabase.js - Módulo central de conexão com o Supabase
const SUPABASE_URL = 'https://oasxlmfwkkubabyvqama.supabase.co';
const SUPABASE_ANON_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im9hc3hsbWZ3a2t1YmFieXZxYW1hIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTIzNDU0OTAsImV4cCI6MjEwNzkyMTQ5MH0.WiNjGtnve1frVt07mcKV3-09j7xH8o6me5lC2iA-YCE';

// Inicialização do cliente Supabase a partir do SDK oficial
if (window.supabase) {
  window.supabaseClient = window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY);
}

const supabase = window.supabaseClient;

// Helper para sincronizar vendas (History / Dashboard / Financeiro)
async function dbSaveSale(saleData) {
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
  if (!supabase) return [];
  const { data, error } = await supabase.from('vortex_sales_history').select('*').order('created_at', { ascending: false });
  if (error) {
    console.error('Erro ao buscar vendas no Supabase:', error);
    return [];
  }
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
  if (!supabase) return [];
  const { data, error } = await supabase.from('vortex_kds_orders').select('*').order('created_at', { ascending: false });
  if (error) {
    console.error('Erro ao buscar pedidos KDS no Supabase:', error);
    return [];
  }
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
  if (!supabase) return [];
  const { data, error } = await supabase.from('vortex_integrations').select('*');
  if (error) {
    console.error('Erro ao buscar integrações no Supabase:', error);
    return [];
  }
  return data;
}

// Helper para Lançamentos Financeiros
async function dbSaveFinancialEntry(entryData) {
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
  if (!supabase) return [];
  const { data, error } = await supabase.from('vortex_financial').select('*').order('created_at', { ascending: false });
  if (error) {
    console.error('Erro ao buscar financeiros no Supabase:', error);
    return [];
  }
  return data;
}

// Helper para Catálogo e Receitas (Usado pelo DRE e Relatórios)
async function dbFetchRecipes() {
  if (!supabase) return [];
  const { data, error } = await supabase.from('vortex_recipes_catalog').select('*');
  if (error) return [];
  return data;
}

// Exclusão genérica
async function dbDeleteRecord(tableName, id) {
  if (!supabase) return { error: 'Supabase não inicializado' };
  const { data, error } = await supabase.from(tableName).delete().eq('id', String(id));
  if (error) console.error(`Erro ao deletar id ${id} da tabela ${tableName}:`, error);
  return { data, error };
}
