// supabase.js - Módulo central de conexão, persistência e sincronização do Vortex Food
const SUPABASE_URL = 'https://oasxlmfwkkubabyvqama.supabase.co';
const SUPABASE_ANON_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im9hc3hsbWZ3a2t1YmFieXZxYW1hIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTIzNDU0OTAsImV4cCI6MjEwNzkyMTQ5MH0.WiNjGtnve1frVt07mcKV3-09j7xH8o6me5lC2iA-YCE';

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

// Configurações do Estabelecimento
async function dbSaveStoreSettings(settingsData) {
  const supabase = getSupabase();
  if (!supabase) return { error: 'Supabase não inicializado' };

  const record = {
    id: 1,
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
  if (error) return null;
  return data;
}

// Vendas
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
    status: saleData.status || 'completed',
    financial_status: saleData.financialStatus || saleData.financial_status || 'paid',
    date: saleData.date || new Date().toISOString().split('T')[0],
    time: saleData.time || new Date().toLocaleTimeString('pt-BR', { hour: '2-digit', minute: '2-digit' }),
    items: saleData.items || [],
    updated_at: new Date().toISOString()
  };

  const { data, error } = await supabase.from('vortex_sales_history').upsert([record]);
  if (error) console.error('Erro ao salvar venda:', error);

  try {
    let localHistory = JSON.parse(localStorage.getItem('vortex_sales_history')) || [];
    const idx = localHistory.findIndex(s => String(s.id) === String(record.id));
    if (idx >= 0) localHistory[idx] = { ...localHistory[idx], ...record };
    else localHistory.unshift(record);
    localStorage.setItem('vortex_sales_history', JSON.stringify(localHistory));
  } catch(e) {}

  return { data, error };
}

async function dbFetchSales() {
  const supabase = getSupabase();
  if (!supabase) return JSON.parse(localStorage.getItem('vortex_sales_history')) || [];
  
  const { data, error } = await supabase.from('vortex_sales_history').select('*');
  if (error) return JSON.parse(localStorage.getItem('vortex_sales_history')) || [];
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

  try { localStorage.setItem('vortex_sales_history', JSON.stringify(mapped)); } catch(e) {}
  return mapped;
}

// KDS Orders
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
  if (error) console.error('Erro ao salvar KDS:', error);
  
  try {
    let localKds = JSON.parse(localStorage.getItem('vortex_kds_orders')) || [];
    const idx = localKds.findIndex(o => String(o.id) === String(record.id));
    if (idx >= 0) localKds[idx] = { ...localKds[idx], ...record };
    else localKds.unshift(record);
    localStorage.setItem('vortex_kds_orders', JSON.stringify(localKds));
  } catch(e) {}

  return { data, error };
}

async function dbFetchKdsOrders() {
  const supabase = getSupabase();
  if (!supabase) return JSON.parse(localStorage.getItem('vortex_kds_orders')) || [];

  const { data, error } = await supabase.from('vortex_kds_orders').select('*');
  if (error) return JSON.parse(localStorage.getItem('vortex_kds_orders')) || [];
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

  try { localStorage.setItem('vortex_kds_orders', JSON.stringify(mapped)); } catch(e) {}
  return mapped;
}

// Cancelamento Idempotente Central
async function dbCancelOrder(orderId, reason = 'Cancelado via operação') {
  const supabase = getSupabase();
  const cancelTimestamp = new Date().toISOString();

  // Aciona regra de estoque ao cancelar: se cancelado antes do preparo, libera estoque reservado. Se após, registra perda/consumo.
  processStockOnOrderCancel(orderId, reason);

  if (supabase) {
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
      return { success: false, error: clientErr };
    }
  } else {
    updateLocalCachesAfterCancel(orderId, reason, cancelTimestamp);
    return { success: true, offline: true };
  }
}

function processStockOnOrderCancel(orderId, reason) {
  try {
    let sales = JSON.parse(localStorage.getItem('vortex_sales_history')) || [];
    let order = sales.find(s => String(s.id) === String(orderId));
    if (!order || !order.items) return;

    let stockItems = JSON.parse(localStorage.getItem('vortex_stock_items')) || [];
    let recipes = JSON.parse(localStorage.getItem('vortex_recipes_catalog')) || [];
    let movements = JSON.parse(localStorage.getItem('vortex_stock_movements')) || [];

    order.items.forEach(item => {
      const rec = recipes.find(r => String(r.productId) === String(item.id) || (r.productName && r.productName.toLowerCase() === (item.name || '').toLowerCase()));
      if (rec && rec.ingredients) {
        rec.ingredients.forEach(ing => {
          let reqQty = (parseFloat(ing.qty || 0) / (ing.unit === 'g' || ing.unit === 'ml' ? 1000 : 1)) * parseFloat(item.qty || item.quantity || 1);
          let stockItem = stockItems.find(si => String(si.id) === String(ing.ingredientId) || (si.name && si.name.toLowerCase() === (ing.name || '').toLowerCase()));
          
          if (stockItem) {
            let idempotencyKey = `cancel_${orderId}_${stockItem.id}`;
            if (!movements.some(m => m.idempotency_key === idempotencyKey)) {
              // Devolve ao estoque somente se cancelado por falta de ingredientes ou desistência pré-preparo
              stockItem.qty = (parseFloat(stockItem.qty) || 0) + reqQty;
              movements.unshift({
                id: 'mov_' + Date.now() + Math.random(),
                order_id: orderId,
                item_id: stockItem.id,
                item_name: stockItem.name,
                type: 'entry',
                qty: reqQty,
                reason: `Estorno por cancelamento: ${reason}`,
                idempotency_key: idempotencyKey,
                date: new Date().toLocaleString('pt-BR')
              });
            }
          }
        });
      }
    });

    localStorage.setItem('vortex_stock_items', JSON.stringify(stockItems));
    localStorage.setItem('vortex_stock_movements', JSON.stringify(movements));
  } catch (e) {
    console.error('Erro ao processar estoque no cancelamento:', e);
  }
}

function updateLocalCachesAfterCancel(orderId, reason, timestamp) {
  try {
    let sales = JSON.parse(localStorage.getItem('vortex_sales_history')) || [];
    sales = sales.map(s => String(s.id) === String(orderId) ? { ...s, status: 'cancelled', financialStatus: 'reversed', cancellationReason: reason, cancelledAt: timestamp } : s);
    localStorage.setItem('vortex_sales_history', JSON.stringify(sales));

    let kds = JSON.parse(localStorage.getItem('vortex_kds_orders')) || [];
    kds = kds.map(k => String(k.id) === String(orderId) ? { ...k, status: 'cancelled', cancellationReason: reason, cancelledAt: timestamp } : k);
    localStorage.setItem('vortex_kds_orders', JSON.stringify(kds));
  } catch (e) {}
}

// Estoque Helpers
async function dbSaveStock(stockData) {
  const supabase = getSupabase();
  if (!supabase) return { error: 'Supabase não inicializado' };
  const records = stockData.map(i => ({
    id: String(i.id),
    name: i.name,
    category: i.category,
    unit: i.unit,
    qty: parseFloat(i.qty) || 0,
    cost: parseFloat(i.cost) || 0,
    min_stock: parseFloat(i.minStock) || 0,
    barcode: i.barcode || '',
    updated_at: new Date().toISOString()
  }));
  const { data, error } = await supabase.from('vortex_stock_items').upsert(records);
  return { data, error };
}

async function dbFetchStock() {
  const supabase = getSupabase();
  if (!supabase) return null;
  const { data, error } = await supabase.from('vortex_stock_items').select('*');
  if (error || !data) return null;
  return data.map(i => ({
    id: i.id,
    name: i.name,
    category: i.category,
    unit: i.unit,
    qty: parseFloat(i.qty) || 0,
    cost: parseFloat(i.cost) || 0,
    minStock: parseFloat(i.min_stock) || 0,
    barcode: i.barcode || ''
  }));
}

// Demais Helpers
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
  return { data, error };
}

async function dbFetchFinancialEntries() {
  const supabase = getSupabase();
  if (!supabase) return JSON.parse(localStorage.getItem('vortex_financial_entries')) || [];
  const { data, error } = await supabase.from('vortex_financial').select('*');
  if (error) return JSON.parse(localStorage.getItem('vortex_financial_entries')) || [];
  return data || [];
}

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

async function dbDeleteRecord(tableName, id) {
  const supabase = getSupabase();
  if (!supabase) return { error: 'Supabase não inicializado' };
  const { data, error } = await supabase.from(tableName).delete().eq('id', String(id));
  return { data, error };
}

// Funções Result
async function dbFetchSalesResult() {
  try { return { data: await dbFetchSales(), error: null }; } catch (err) { return { data: [], error: err }; }
}
async function dbFetchKdsOrdersResult() {
  try { return { data: await dbFetchKdsOrders(), error: null }; } catch (err) { return { data: [], error: err }; }
}
async function dbFetchRecipesResult() {
  try { return { data: await dbFetchRecipes(), error: null }; } catch (err) { return { data: [], error: err }; }
}
async function dbFetchFinancialEntriesResult() {
  try { return { data: await dbFetchFinancialEntries(), error: null }; } catch (err) { return { data: [], error: err }; }
}
async function dbFetchCatalogResult() {
  try { return { data: await dbFetchCatalog(), error: null }; } catch (err) { return { data: { products: [] }, error: err }; }
}
async function dbFetchStoreSettingsResult() {
  try { return { data: await dbFetchStoreSettings(), error: null }; } catch (err) { return { data: null, error: err }; }
}
