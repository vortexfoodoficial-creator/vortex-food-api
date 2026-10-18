// supabase.js - Módulo central de conexão com o Supabase
const SUPABASE_URL = 'https://oasxlmfwkkubabyvqama.supabase.co';
const SUPABASE_ANON_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im9hc3hsbWZ3a2t1YmFieXZxYW1hIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTIzNDU0OTAsImV4cCI6MjEwNzkyMTQ5MH0.WiNjGtnve1frVt07mcKV3-09j7xH8o6me5lC2iA-YCE';

// Inicialização do cliente Supabase a partir do SDK oficial
const supabase = window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY);

// Helper para sincronizar vendas (History)
async function dbSaveSale(saleData) {
  const { data, error } = await supabase.from('vortex_sales').upsert([{
    id: String(saleData.id),
    client: saleData.client || 'Cliente Balcão',
    channel: saleData.channel || 'pdv',
    total: parseFloat(saleData.total) || 0,
    subtotal: parseFloat(saleData.subtotal) || 0,
    discount: parseFloat(saleData.discount) || 0,
    pay_method: saleData.payMethod || saleData.paymentMethod || 'PIX',
    status: saleData.status || 'finished',
    date: saleData.date || new Date().toISOString().split('T')[0],
    time: saleData.time || new Date().toLocaleTimeString('pt-BR', { hour: '2-digit', minute: '2-digit' }),
    items: saleData.items || []
  }]);
  if (error) console.error('Erro ao salvar venda no Supabase:', error);
  return { data, error };
}

async function dbFetchSales() {
  const { data, error } = await supabase.from('vortex_sales').select('*').order('created_at', { ascending: false });
  if (error) {
    console.error('Erro ao buscar vendas no Supabase:', error);
    return [];
  }
  return data.map(item => ({
    id: item.id,
    client: item.client,
    channel: item.channel,
    total: item.total,
    subtotal: item.subtotal,
    discount: item.discount,
    payMethod: item.pay_method,
    status: item.status,
    date: item.date,
    time: item.time,
    items: item.items
  }));
}

// Helper para KDS (Cozinha)
async function dbSaveKdsOrder(orderData) {
  const { data, error } = await supabase.from('vortex_kds').upsert([{
    id: String(orderData.id),
    origin: orderData.origin || 'Balcão',
    client: orderData.client || 'Cliente Balcão',
    time: orderData.time || new Date().toLocaleTimeString('pt-BR', { hour: '2-digit', minute: '2-digit' }),
    date: orderData.date || new Date().toISOString().split('T')[0],
    items: orderData.items || [],
    total: parseFloat(orderData.total) || 0,
    observation: orderData.observation || '',
    status: orderData.status || 'new'
  }]);
  if (error) console.error('Erro ao salvar pedido KDS no Supabase:', error);
  return { data, error };
}

async function dbFetchKdsOrders() {
  const { data, error } = await supabase.from('vortex_kds').select('*').order('created_at', { ascending: false });
  if (error) {
    console.error('Erro ao buscar pedidos KDS no Supabase:', error);
    return [];
  }
  return data.map(item => ({
    id: item.id,
    origin: item.origin,
    client: item.client,
    time: item.time,
    date: item.date,
    items: item.items,
    total: item.total,
    observation: item.observation,
    status: item.status
  }));
}

// Helper para Lançamentos Financeiros
async function dbSaveFinancialEntry(entryData) {
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
  const { data, error } = await supabase.from('vortex_financial').select('*').order('created_at', { ascending: false });
  if (error) {
    console.error('Erro ao buscar financeiros no Supabase:', error);
    return [];
  }
  return data;
}

// Exclusão genérica
async function dbDeleteRecord(tableName, id) {
  const { data, error } = await supabase.from(tableName).delete().eq('id', String(id));
  if (error) console.error(`Erro ao deletar id ${id} da tabela ${tableName}:`, error);
  return { data, error };
}
