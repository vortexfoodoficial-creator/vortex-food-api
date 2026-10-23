// supabase.js - Módulo central de conexão com o Supabase
const SUPABASE_URL = 'https://oasxlmfwkkubabyvqama.supabase.co';
const SUPABASE_ANON_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im9hc3hsbWZ3a2t1YmFieXZxYW1hIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTIzNDU0OTAsImV4cCI6MjEwNzkyMTQ5MH0.WiNjGtnve1frVt07mcKV3-09j7xH8o6me5lC2iA-YCE';

if (window.supabase) {
  window.supabaseClient = window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY);
}

const supabase = window.supabaseClient;

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
  if (error) console.error('Erro ao salvar venda no Supabase:', error);
  return { data, error };
}

async function dbFetchSales() {
  if (!supabase) return [];
  const { data, error } = await supabase.from('vortex_sales_history').select('*').order('created_at', { ascending: false });
  if (error) { console.error('Erro ao buscar vendas:', error); return []; }
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
    items: orderData.items || [],
    total: parseFloat(orderData.total) || 0,
    status: orderData.status || 'new'
  };
  const { data, error } = await supabase.from('vortex_kds_orders').upsert([record]);
  return { data, error };
}

async function dbFetchKdsOrders() {
  if (!supabase) return [];
  const { data, error } = await supabase.from('vortex_kds_orders').select('*').order('created_at', { ascending: false });
  if (error) return [];
  return data;
}

async function dbSaveFinancialEntry(entryData) {
  if (!supabase) return { error: 'Supabase não inicializado' };
  const { data, error } = await supabase.from('vortex_financial').upsert([{
    id: String(entryData.id),
    type: entryData.type,
    description: entryData.description,
    value: parseFloat(entryData.value) || 0,
    date: entryData.date || new Date().toISOString().split('T')[0]
  }]);
  if (error) console.error('Erro ao salvar financeiro:', error);
  return { data, error };
}

async function dbFetchFinancialEntries() {
  if (!supabase) return [];
  const { data, error } = await supabase.from('vortex_financial').select('*').order('created_at', { ascending: false });
  if (error) return [];
  return data;
}

async function dbDeleteRecord(tableName, id) {
  if (!supabase) return { error: 'Supabase não inicializado' };
  const { data, error } = await supabase.from(tableName).delete().eq('id', String(id));
  return { data, error };
}
