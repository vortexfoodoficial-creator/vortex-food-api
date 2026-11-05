// supabase.js - Módulo central de conexão, persistência e sincronização do Vortex Food
const SUPABASE_URL = 'https://oasxlmfwkkubabyvqama.supabase.co';
const SUPABASE_ANON_KEY = 'sb_publishable_r3Ob9dbgz52-_ziLLe9-_w_wvimzPkk';

// Armazenamento local separado por estabelecimento. A preferência visual
// vortex_theme permanece no dispositivo; os demais dados vortex_* são isolados.
(function installVortexStoreStorage() {
  if (window.__VORTEX_STORE_STORAGE_INSTALLED) return;
  window.__VORTEX_STORE_STORAGE_INSTALLED = true;
  const proto = Storage.prototype;
  const nativeGet = proto.getItem;
  const nativeSet = proto.setItem;
  const nativeRemove = proto.removeItem;
  const isTenantKey = key => String(key).startsWith('vortex_') && key !== 'vortex_theme';
  const scopedKey = key => 'vortex_store_' + window.VORTEX_ACTIVE_STORE_ID + '::' + key;

  // Antes da identificação da loja, dados operacionais não são lidos nem gravados.
  // Isso impede que dados de demonstração ou de uma sessão sem login sejam
  // transferidos acidentalmente para o primeiro estabelecimento conectado.
  proto.getItem = function(key) {
    if (this === window.localStorage && isTenantKey(key)) {
      if (!window.VORTEX_ACTIVE_STORE_ID) return null;
      return nativeGet.call(this, scopedKey(key));
    }
    return nativeGet.call(this, key);
  };
  proto.setItem = function(key, value) {
    if (this === window.localStorage && isTenantKey(key)) {
      if (!window.VORTEX_ACTIVE_STORE_ID) return;
      return nativeSet.call(this, scopedKey(key), value);
    }
    return nativeSet.call(this, key, value);
  };
  proto.removeItem = function(key) {
    if (this === window.localStorage && isTenantKey(key)) {
      if (!window.VORTEX_ACTIVE_STORE_ID) return;
      return nativeRemove.call(this, scopedKey(key));
    }
    return nativeRemove.call(this, key);
  };

  window.VortexStoreStorage = {
    setStoreId(storeId) {
      if (!storeId) return;
      window.VORTEX_ACTIVE_STORE_ID = String(storeId);
    },
    getStoreId() {
      return window.VORTEX_ACTIVE_STORE_ID || null;
    }
  };
})();

function getSupabase() {
  if (window.supabaseClient) {
    return window.supabaseClient;
  }
  if (window.supabase && typeof window.supabase.createClient === 'function') {
    window.supabaseClient = window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY, { auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true } });
    return window.supabaseClient;
  }
  console.warn('SDK do Supabase ainda não foi carregado pelo navegador.');
  return null;
}

// Configurações do Estabelecimento
async function dbSaveStoreSettings(settingsData) {
  const supabase = getSupabase();
  if (!supabase) return { error: 'Supabase não inicializado' };
  const storeId = await vortexGetCurrentStoreId();
  if (!storeId) return { error: new Error('Estabelecimento ativo não identificado.') };

  const record = {
    store_id: storeId,
    id: 1,
    store_name: settingsData.store_name || settingsData.nome || 'Vortex Food',
    store_address: settingsData.store_address || settingsData.endereco || '',
    cnpj: settingsData.cnpj || '',
    phone: settingsData.phone || settingsData.tel || '',
    email: settingsData.email || '',
    taxa: settingsData.taxa || '10,00',
    rodape: settingsData.rodape || ''
  };

  const { data, error } = await supabase.from('vortex_store_settings').upsert([record], { onConflict: 'store_id,id' });
  if (error) console.error('Erro ao salvar configurações no Supabase:', error);
  return { data, error };
}

async function dbFetchStoreSettings() {
  const supabase = getSupabase();
  if (!supabase) return null;
  const storeId = await vortexGetCurrentStoreId();
  if (!storeId) return null;
  const { data, error } = await supabase.from('vortex_store_settings').select('*').eq('store_id', storeId).limit(1).maybeSingle();
  if (error) return null;
  return data;
}

// Vendas
async function dbSaveSale(saleData) {
  const supabase = getSupabase();
  if (!supabase) return { error: 'Supabase não inicializado' };
  const storeId = await vortexGetCurrentStoreId();
  if (!storeId) return { error: new Error('Estabelecimento ativo não identificado.') };

  const record = {
    store_id: storeId,
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
  const storeId = await vortexGetCurrentStoreId();
  if (!storeId) return [];
  if (!supabase) return JSON.parse(localStorage.getItem('vortex_sales_history')) || [];

  const { data, error } = await supabase.from('vortex_sales_history').select('*').eq('store_id', storeId);
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
  const storeId = await vortexGetCurrentStoreId();
  if (!storeId) return { error: new Error('Estabelecimento ativo não identificado.') };

  const record = {
    store_id: storeId,
    id: String(orderData.id),
    origin: orderData.origin || 'Balcão',
    client: orderData.client || 'Cliente Balcão',
    address: orderData.address || '',
    payment: orderData.payment || orderData.payMethod || 'Dinheiro',
    cashgiven: parseFloat(orderData.cashGiven || orderData.cashgiven || 0),
    change: parseFloat(orderData.change || 0),
    time: orderData.time || new Date().toLocaleTimeString('pt-BR', { hour: '2-digit', minute: '2-digit' }),
    date: orderData.date || new Date().toISOString().split('T')[0],
    dateformatted: orderData.dateFormatted || orderData.dateformatted || new Date().toLocaleDateString('pt-BR'),
    items: orderData.items || [],
    total: parseFloat(orderData.total) || 0,
    observation: orderData.observation || '',
    status: orderData.status || 'received',
    financial_status: orderData.financialStatus || 'paid',
    code: orderData.code || '',
    displayId: orderData.displayId || orderData.displayid || null,
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
  const storeId = await vortexGetCurrentStoreId();
  if (!storeId) return [];
  if (!supabase) return JSON.parse(localStorage.getItem('vortex_kds_orders')) || [];

  const { data, error } = await supabase.from('vortex_kds_orders').select('*').eq('store_id', storeId);
  if (error) return JSON.parse(localStorage.getItem('vortex_kds_orders')) || [];
  if (!data) return [];

  const remoteMapped = data.map(item => ({
    id: item.id,
    origin: item.origin,
    client: item.client,
    address: item.address,
    payment: item.payment,
    cashGiven: item.cashgiven,
    change: item.change,
    time: item.time,
    date: item.date,
    dateFormatted: item.dateformatted,
    items: item.items || [],
    total: parseFloat(item.total) || 0,
    observation: item.observation,
    status: item.status || 'received',
    financialStatus: item.financial_status || 'paid',
    code: item.code,
    displayId: item.displayId || item.displayid || null
  }));

  // Preserva o número de exibição local quando a nuvem não o retorna.
  let localOrders = [];
  try {
    localOrders = JSON.parse(localStorage.getItem('vortex_kds_orders')) || [];
  } catch(e) {
    localOrders = [];
  }

  const localMap = new Map(localOrders.map(order => [String(order.id), order]));
  remoteMapped.forEach(remoteOrder => {
    const localOrder = localMap.get(String(remoteOrder.id)) || {};
    localMap.set(String(remoteOrder.id), {
      ...localOrder,
      ...remoteOrder,
      displayId: remoteOrder.displayId || remoteOrder.displayid || localOrder.displayId || localOrder.displayid || null
    });
  });

  const mergedOrders = Array.from(localMap.values());
  try { localStorage.setItem('vortex_kds_orders', JSON.stringify(mergedOrders)); } catch(e) {}
  return mergedOrders;
}

/**
 * REGRA CENTRAL DE CONSUMO DE ESTOQUE AO ENTRAR EM PREPARO (IDEMPOTENTE)
 */
async function processStockConsumptionForOrder(order) {
  if (!order || !Array.isArray(order.items) || order.items.length === 0) return;

  const supabase = getSupabase();
  const storeId = await vortexGetCurrentStoreId();
  if (!supabase || !storeId) {
    console.warn('Consumo automático aguardando conexão e identificação do estabelecimento.');
    return;
  }

  try {
    const stockItems = JSON.parse(localStorage.getItem('vortex_stock_items')) || [];
    const recipes = JSON.parse(localStorage.getItem('vortex_recipes_catalog')) || [];
    const movements = [];

    order.items.forEach((item, itemIndex) => {
      const rec = recipes.find(r =>
        String(r.productId) === String(item.id || item.productId) ||
        (r.productName && r.productName.trim().toLowerCase() === (item.name || item.title || '').trim().toLowerCase())
      );

      if (!rec || !Array.isArray(rec.ingredients)) return;

      rec.ingredients.forEach(ing => {
        const ingredientQtyPerUnit = parseFloat(ing.qty || 0);
        const itemQty = parseFloat(item.qty || item.quantity || 1);
        const totalReqQty = ingredientQtyPerUnit * itemQty;
        const stockItem = stockItems.find(si =>
          String(si.id) === String(ing.insumoId || ing.ingredientId) ||
          (si.name && si.name.trim().toLowerCase() === (ing.name || '').trim().toLowerCase())
        );

        if (!stockItem || !Number.isFinite(totalReqQty) || totalReqQty <= 0) return;

        let calculatedQty = totalReqQty;
        const unitToUse = ing.unit || 'g';
        if ((unitToUse === 'g' || unitToUse === 'ml') && (stockItem.unit === 'kg' || stockItem.unit === 'l')) {
          calculatedQty = totalReqQty / 1000;
        }

        if (!Number.isFinite(calculatedQty) || calculatedQty <= 0) return;

        movements.push({
          id: 'mov_' + Date.now() + '_' + itemIndex + '_' + String(stockItem.id),
          item_id: String(stockItem.id),
          item_name: String(stockItem.name || ''),
          type: 'consumption',
          qty: calculatedQty,
          reason: `Consumo automático - Pedido #${order.id} (${item.name || 'Produto'})`,
          idempotency_key: `consumption_${order.id}_item_${itemIndex}_ing_${stockItem.id}`
        });
      });
    });

    if (!movements.length) return;

    // O banco grava a movimentação e desconta o saldo na mesma transação.
    // Se o mesmo pedido for processado novamente, a chave única impede novo desconto.
    const { data, error } = await supabase.rpc('rpc_consume_stock_for_order', {
      p_store_id: storeId,
      p_order_id: String(order.id),
      p_movements: movements
    });
    if (error) throw error;
    if (!data || data.success !== true) throw new Error('O banco não confirmou o consumo do estoque.');

    const [cloudStock, cloudMovements] = await Promise.all([
      typeof dbFetchStock === 'function' ? dbFetchStock() : Promise.resolve(null),
      typeof dbFetchStockMovements === 'function' ? dbFetchStockMovements() : Promise.resolve(null)
    ]);

    if (Array.isArray(cloudStock)) {
      localStorage.setItem('vortex_stock_items', JSON.stringify(cloudStock));
    }
    if (Array.isArray(cloudMovements)) {
      localStorage.setItem('vortex_stock_movements', JSON.stringify(cloudMovements));
    }
  } catch (e) {
    console.error('Erro ao processar consumo automático de estoque:', e);
  }
}

// Cancelamento Idempotente Central
async function dbCancelOrder(orderId, reason = 'Cancelado via operação') {
  const supabase = getSupabase();
  const storeId = await vortexGetCurrentStoreId();
  if (!storeId) return { success: false, error: new Error('Estabelecimento ativo não identificado.') };
  const cancelTimestamp = new Date().toISOString();

  if (supabase) {
    try {
      await supabase.from('vortex_sales_history').update({
        status: 'cancelled',
        financial_status: 'reversed',
        cancellation_reason: reason,
        cancelled_at: cancelTimestamp,
        updated_at: cancelTimestamp
      }).eq('id', String(orderId)).eq('store_id', storeId);

      await supabase.from('vortex_kds_orders').update({
        status: 'cancelled',
        cancellation_reason: reason,
        cancelled_at: cancelTimestamp,
        updated_at: cancelTimestamp
      }).eq('id', String(orderId)).eq('store_id', storeId);

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
  if (!supabase) return { error: new Error('Supabase não inicializado') };
  const storeId = await vortexGetCurrentStoreId();
  if (!storeId) return { error: new Error('Estabelecimento ativo não identificado.') };

  const items = Array.isArray(stockData) ? stockData : [];
  if (!items.length) return { data: [], error: null };

  const records = items.map(i => ({
    store_id: storeId,
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

async function dbDeleteStockItem(itemId) {
  const supabase = getSupabase();
  if (!supabase) return { error: new Error('Supabase não inicializado') };
  const storeId = await vortexGetCurrentStoreId();
  if (!storeId) return { error: new Error('Estabelecimento ativo não identificado.') };
  return await supabase
    .from('vortex_stock_items')
    .delete()
    .eq('store_id', storeId)
    .eq('id', String(itemId))
    .select('id');
}

async function dbSaveStockMovements(movements) {
  const supabase = getSupabase();
  if (!supabase) return { error: new Error('Supabase não inicializado') };
  const storeId = await vortexGetCurrentStoreId();
  if (!storeId) return { error: new Error('Estabelecimento ativo não identificado.') };

  const entries = Array.isArray(movements) ? movements : [];
  if (!entries.length) return { data: [], error: null };

  const normalized = entries.map((movement, index) => {
    const id = String(movement.id || ('mov_' + Date.now() + '_' + index));
    movement.id = id;
    return {
      store_id: storeId,
      id,
      order_id: movement.order_id ? String(movement.order_id) : null,
      item_id: String(movement.item_id || ''),
      item_name: String(movement.item_name || movement.itemName || ''),
      type: String(movement.type || 'adjustment'),
      qty: Number(movement.qty) || 0,
      reason: String(movement.reason || ''),
      idempotency_key: String(movement.idempotency_key || ('stock_' + id)),
      created_at: movement.created_at || movement.createdAt || new Date().toISOString()
    };
  });

  // Histórico append-only: não remove registros remotos a partir de um cache local.
  const { data, error } = await supabase.from('vortex_stock_movements').upsert(normalized);
  return { data, error };
}

async function dbFetchStockMovements() {
  const supabase = getSupabase();
  if (!supabase) return null;
  const storeId = await vortexGetCurrentStoreId();
  if (!storeId) return [];
  const { data, error } = await supabase
    .from('vortex_stock_movements')
    .select('*')
    .eq('store_id', storeId)
    .order('created_at', { ascending: false });
  if (error || !data) return null;
  return data.map(movement => ({
    id: movement.id,
    order_id: movement.order_id,
    item_id: movement.item_id,
    item_name: movement.item_name,
    type: movement.type,
    qty: Number(movement.qty) || 0,
    reason: movement.reason || '',
    idempotency_key: movement.idempotency_key || '',
    created_at: movement.created_at,
    date: movement.created_at ? new Date(movement.created_at).toLocaleString('pt-BR') : ''
  }));
}

async function dbFetchStock() {
  const supabase = getSupabase();
  if (!supabase) return null;
  const storeId = await vortexGetCurrentStoreId();
  if (!storeId) return [];
  const { data, error } = await supabase.from('vortex_stock_items').select('*').eq('store_id', storeId);
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
  const storeId = await vortexGetCurrentStoreId();
  if (!storeId) return { error: new Error('Estabelecimento ativo não identificado.') };
  const { data, error } = await supabase.from('vortex_financial').upsert([{
    store_id: storeId,
    id: String(entryData.id),
    type: entryData.type,
    description: entryData.description,
    value: parseFloat(entryData.value) || 0,
    date: entryData.date || new Date().toISOString().split('T')[0]
  }]);
  return { data, error };
}

async function dbFetchFinancialEntries() {
  const supabase = getSupabase();
  const storeId = await vortexGetCurrentStoreId();
  if (!storeId) return [];
  if (!supabase) return JSON.parse(localStorage.getItem('vortex_financial_entries')) || [];
  const { data, error } = await supabase.from('vortex_financial').select('*').eq('store_id', storeId);
  if (error) return JSON.parse(localStorage.getItem('vortex_financial_entries')) || [];
  return data || [];
}

async function dbFetchCatalog() {
  const cloud = await dbFetchStoreDocument('catalog');
  if (cloud && typeof cloud === 'object') {
    const catalog = {
      products: Array.isArray(cloud.products) ? cloud.products : [],
      groups: Array.isArray(cloud.groups) ? cloud.groups : [],
      complements: Array.isArray(cloud.complements) ? cloud.complements : []
    };
    // Mantém os caches locais alinhados à nuvem, inclusive quando o catálogo está vazio.
    try {
      localStorage.setItem('vortex_products_catalog', JSON.stringify(catalog.products));
      localStorage.setItem('vortex_groups_catalog', JSON.stringify(catalog.groups));
      localStorage.setItem('vortex_complements_catalog', JSON.stringify(catalog.complements));
    } catch (error) {
      console.warn('Não foi possível atualizar o cache local do catálogo:', error);
    }
    return catalog;
  }
  return {
    products: JSON.parse(localStorage.getItem('vortex_products_catalog')) || [],
    groups: JSON.parse(localStorage.getItem('vortex_groups_catalog')) || [],
    complements: JSON.parse(localStorage.getItem('vortex_complements_catalog')) || []
  };
}

async function dbSaveCatalog(catalogData) {
  const payload = {
    products: Array.isArray(catalogData && catalogData.products) ? catalogData.products : [],
    groups: Array.isArray(catalogData && catalogData.groups) ? catalogData.groups : [],
    complements: Array.isArray(catalogData && catalogData.complements) ? catalogData.complements : []
  };
  return await dbSaveStoreDocument('catalog', payload);
}

async function dbSaveCoupons(coupons) {
  return await dbSaveStoreDocument('coupons', Array.isArray(coupons) ? coupons : []);
}

async function dbFetchCoupons() {
  const supabase = getSupabase();
  const storeId = await vortexGetCurrentStoreId();
  if (!supabase || !storeId) return null;
  const { data, error } = await supabase
    .from('vortex_store_documents')
    .select('data')
    .eq('store_id', storeId)
    .eq('document_key', 'coupons')
    .maybeSingle();
  if (error || !data) return null;
  return Array.isArray(data.data) ? data.data : [];
}

async function dbSaveLoyalty(data) {
  return await dbSaveStoreDocument('loyalty', data && typeof data === 'object' ? data : {});
}

async function dbFetchLoyalty() {
  const data = await dbFetchStoreDocument('loyalty');
  return data && typeof data === 'object' ? data : null;
}

async function dbSaveCustomers(customers) {
  return await dbSaveStoreDocument('customers', Array.isArray(customers) ? customers : []);
}

async function dbFetchCustomers() {
  const supabase = getSupabase();
  const storeId = await vortexGetCurrentStoreId();
  if (!supabase || !storeId) return null;
  const { data, error } = await supabase
    .from('vortex_store_documents')
    .select('data')
    .eq('store_id', storeId)
    .eq('document_key', 'customers')
    .maybeSingle();
  if (error || !data) return null;
  return Array.isArray(data.data) ? data.data : [];
}

async function dbFetchRecipes() {
  // As fichas técnicas ainda não possuem tabela própria no banco auditado.
  // O armazenamento local já está separado por estabelecimento.
  return JSON.parse(localStorage.getItem('vortex_recipes_catalog')) || [];
}

/* Documentos JSON separados por estabelecimento para módulos sem tabela própria. */
async function dbSaveStoreDocument(documentKey, documentData) {
  const supabase = getSupabase();
  const storeId = await vortexGetCurrentStoreId();
  if (!supabase) return { error: new Error('Supabase não inicializado') };
  if (!storeId) return { error: new Error('Estabelecimento ativo não identificado.') };
  return await supabase.from('vortex_store_documents').upsert([{
    store_id: storeId,
    document_key: String(documentKey),
    data: documentData,
    updated_at: new Date().toISOString()
  }], { onConflict: 'store_id,document_key' });
}

async function dbFetchStoreDocument(documentKey) {
  const supabase = getSupabase();
  const storeId = await vortexGetCurrentStoreId();
  if (!supabase || !storeId) return null;
  const { data, error } = await supabase
    .from('vortex_store_documents')
    .select('data')
    .eq('store_id', storeId)
    .eq('document_key', String(documentKey))
    .maybeSingle();
  if (error || !data) return null;
  return data.data;
}

async function dbSavePublicQrEnabled(enabled) {
  const supabase = getSupabase();
  if (!supabase) return { error: new Error('Supabase não inicializado') };
  return await supabase.rpc('rpc_set_public_qr_enabled', { p_enabled: !!enabled });
}

async function dbFetchPublicQrEnabled() {
  const supabase = getSupabase();
  const storeId = await vortexGetCurrentStoreId();
  if (!supabase || !storeId) return false;
  const { data, error } = await supabase
    .from('vortex_public_store_settings')
    .select('qr_enabled')
    .eq('store_id', storeId)
    .maybeSingle();
  return !error && !!(data && data.qr_enabled);
}

async function dbFetchPublicTableRequests() {
  const supabase = getSupabase();
  const storeId = await vortexGetCurrentStoreId();
  if (!supabase || !storeId) return [];
  const { data, error } = await supabase
    .from('vortex_public_table_requests')
    .select('*')
    .eq('store_id', storeId)
    .eq('status', 'pending')
    .order('created_at', { ascending: false });
  return error ? [] : (data || []);
}

async function dbResolvePublicTableRequest(requestId) {
  const supabase = getSupabase();
  const storeId = await vortexGetCurrentStoreId();
  if (!supabase || !storeId) return { error: new Error('Estabelecimento ativo não identificado.') };
  return await supabase
    .from('vortex_public_table_requests')
    .update({ status: 'attended', handled_at: new Date().toISOString() })
    .eq('store_id', storeId)
    .eq('id', String(requestId));
}

async function dbSaveIntegration(platform, credentials) {
  const supabase = getSupabase();
  const storeId = await vortexGetCurrentStoreId();
  if (!supabase) return { error: new Error('Supabase não inicializado') };
  if (!storeId) return { error: new Error('Estabelecimento ativo não identificado.') };
  return await supabase.from('vortex_integrations').upsert([{
    store_id: storeId,
    platform: String(platform),
    connected: true,
    credentials: credentials || {},
    updated_at: new Date().toISOString()
  }], { onConflict: 'store_id,platform' });
}

async function dbFetchIntegrations() {
  const supabase = getSupabase();
  const storeId = await vortexGetCurrentStoreId();
  if (!supabase || !storeId) return [];
  const { data, error } = await supabase.from('vortex_integrations')
    .select('platform, connected, credentials, updated_at')
    .eq('store_id', storeId);
  return error ? [] : (data || []);
}

async function dbDeleteRecord(tableName, id) {
  const supabase = getSupabase();
  if (!supabase) return { error: 'Supabase não inicializado' };
  const storeId = await vortexGetCurrentStoreId();
  if (!storeId) return { error: new Error('Estabelecimento ativo não identificado.') };
  const { data, error } = await supabase.from(tableName).delete().eq('id', String(id)).eq('store_id', storeId);
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


// ============================================================
// AUTENTICAÇÃO CENTRAL — SUPABASE AUTH
// Esta etapa disponibiliza login, sessão e proteção de acesso às páginas internas.
// A autorização por restaurante e a segurança dos dados dependem das políticas RLS.
// ============================================================

async function vortexSignIn(email, password) {
  const supabase = getSupabase();
  if (!supabase) return { data: null, error: new Error('Conexão com Supabase indisponível.') };

  const { data, error } = await supabase.auth.signInWithPassword({
    email: String(email || '').trim(),
    password: String(password || '')
  });

  return { data, error };
}

async function vortexSignOut() {
  const supabase = getSupabase();
  if (!supabase) return { error: new Error('Conexão com Supabase indisponível.') };
  return await supabase.auth.signOut();
}

async function vortexGetSession() {
  const supabase = getSupabase();
  if (!supabase) return { session: null, error: new Error('Conexão com Supabase indisponível.') };

  const { data, error } = await supabase.auth.getSession();
  return { session: data ? data.session : null, error };
}

async function vortexGetCurrentUser() {
  const supabase = getSupabase();
  if (!supabase) return { user: null, error: new Error('Conexão com Supabase indisponível.') };

  const { data, error } = await supabase.auth.getUser();
  return { user: data ? data.user : null, error };
}


async function vortexSignUp(email, password, storeData) {
  const supabase = getSupabase();
  if (!supabase) return { data: null, error: new Error('Conexão com Supabase indisponível.') };

  const metadata = {
    store_name: String(storeData.store_name || '').trim(),
    contact_name: String(storeData.contact_name || '').trim(),
    document: String(storeData.document || '').trim(),
    whatsapp: String(storeData.whatsapp || '').trim(),
    legal_name: String(storeData.legal_name || '').trim()
  };

  const emailRedirectTo = new URL('login.html', window.location.href).href;
  const { data, error } = await supabase.auth.signUp({
    email: String(email || '').trim(),
    password: String(password || ''),
    options: {
      data: metadata,
      emailRedirectTo
    }
  });
  if (error) return { data, error };

  if (data && data.session) {
    const registration = await vortexCompleteStoreRegistration();
    if (registration.error) return { data, error: registration.error };
    return { data, registration, needsEmailConfirmation: false, error: null };
  }

  return { data, registration: null, needsEmailConfirmation: true, error: null };
}

async function vortexCompleteStoreRegistration() {
  const supabase = getSupabase();
  if (!supabase) return { data: null, error: new Error('Conexão com Supabase indisponível.') };
  const { data: sessionData, error: sessionError } = await supabase.auth.getSession();
  if (sessionError) return { data: null, error: sessionError };
  if (!sessionData || !sessionData.session) {
    return { data: null, error: new Error('Confirme seu e-mail e entre na sua conta para concluir o cadastro.') };
  }
  const { data, error } = await supabase.rpc('rpc_complete_store_registration');
  return { data, error };
}

async function vortexGetSubscription(storeId) {
  const supabase = getSupabase();
  if (!supabase) return { data: null, error: new Error('Conexão com Supabase indisponível.') };
  const { data, error } = await supabase
    .from('vortex_subscriptions')
    .select('id, store_id, plan_code, status, trial_started_at, trial_ends_at, current_period_start, current_period_end, grace_period_ends_at')
    .eq('store_id', storeId)
    .maybeSingle();
  return { data, error };
}

async function vortexGetCurrentStoreId() {
  if (window.VORTEX_ACTIVE_STORE_ID) return String(window.VORTEX_ACTIVE_STORE_ID);
  const context = await vortexGetCurrentStoreContext();
  if (context.error || !context.store) return null;
  return String(context.store.id);
}

async function vortexGetCurrentStoreContext() {
  const supabase = getSupabase();
  if (!supabase) return { store: null, subscription: null, error: new Error('Conexão com Supabase indisponível.') };

  const { data: userData, error: userError } = await supabase.auth.getUser();
  if (userError) return { store: null, subscription: null, error: userError };
  if (!userData || !userData.user) return { store: null, subscription: null, error: new Error('Entre na sua conta para consultar a assinatura.') };

  const { data: membership, error: membershipError } = await supabase
    .from('vortex_store_members')
    .select('store_id, role')
    .eq('user_id', userData.user.id)
    .eq('status', 'active')
    .maybeSingle();
  if (membershipError) return { store: null, subscription: null, error: membershipError };
  if (!membership) return { store: null, subscription: null, error: new Error('Nenhum estabelecimento ativo foi encontrado para esta conta.') };

  const { data: store, error: storeError } = await supabase
    .from('vortex_stores')
    .select('id, name, created_at')
    .eq('id', membership.store_id)
    .maybeSingle();
  if (storeError) return { store: null, subscription: null, error: storeError };
  if (!store) return { store: null, subscription: null, error: new Error('Não foi possível localizar os dados do estabelecimento.') };

  const subscriptionResult = await vortexGetSubscription(store.id);
  if (subscriptionResult.error) return { store, subscription: null, error: subscriptionResult.error };
  if (window.VortexStoreStorage) window.VortexStoreStorage.setStoreId(store.id);
  return { store, subscription: subscriptionResult.data, error: null };
}

async function vortexResetPassword(email) {
  const supabase = getSupabase();
  if (!supabase) return { error: new Error('Conexão com Supabase indisponível.') };
  const redirectTo = window.location.origin + window.location.pathname;
  return await supabase.auth.resetPasswordForEmail(String(email || '').trim(), { redirectTo });
}

async function vortexUpdatePassword(newPassword) {
  const supabase = getSupabase();
  if (!supabase) return { error: new Error('Conexão com Supabase indisponível.') };
  return await supabase.auth.updateUser({ password: String(newPassword || '') });
}

window.VortexAuth = {
  signIn: vortexSignIn,
  signUp: vortexSignUp,
  completeStoreRegistration: vortexCompleteStoreRegistration,
  getSubscription: vortexGetSubscription,
  getCurrentStoreContext: vortexGetCurrentStoreContext,
  getCurrentStoreId: vortexGetCurrentStoreId,
  resetPassword: vortexResetPassword,
  updatePassword: vortexUpdatePassword,
  signOut: vortexSignOut,
  getSession: vortexGetSession,
  getCurrentUser: vortexGetCurrentUser,
  requireAuthenticatedPage: vortexRequireAuthenticatedPage
};

function vortexRequireAuthenticatedPage() {
  const protectedPages = new Set([
    'index.html',
    'modulo-mensalidade.html',
    'modulo2-cardapio.html',
    'modulo3-pdv.html',
    'modulo5-mesas.html',
    'modulo6-cardapio-online.html',
    'modulo7-8-kds-pedidos.html',
    'modulo9-equipe.html',
    'modulo10-relatorios.html',
    'modulo12-estoque.html',
    'modulo13-fichas-tecnicas.html',
    'modulo14-compras.html',
    'modulo15-financeiro.html',
    'modulo16-contas.html',
    'modulo17-caixa-turno.html',
    'modulo18-crm.html',
    'modulo19-fiscal.html',
    'modulo21-delivery.html',
    'modulo-configuracoes.html',
    'modulo-cupons.html',
    'modulo-fidelidade.html',
    'modulo-impressoras.html',
    'modulo-integracoes.html',
    'modulo-marketing.html',
    'modulo-suporte.html'
  ]);

  const currentPage = window.location.pathname.split('/').pop() || 'index.html';
  if (!protectedPages.has(currentPage)) return;

  // Evita exibir a página enquanto a sessão é validada.
  document.documentElement.style.visibility = 'hidden';
  const loginUrl = new URL('login.html', window.location.href).href;
  const supabase = getSupabase();

  if (!supabase) {
    window.location.replace(loginUrl);
    return;
  }

  let redirecting = false;
  const redirectToLogin = function() {
    if (redirecting) return;
    redirecting = true;
    window.location.replace(loginUrl);
  };

  supabase.auth.onAuthStateChange(function(event) {
    if (event === 'SIGNED_OUT') redirectToLogin();
  });

  vortexGetSession()
    .then(function(result) {
      if (result.error || !result.session) {
        redirectToLogin();
        return;
      }

      // Identifica a loja antes de liberar a página. Assim, o armazenamento
      // local e as consultas dos módulos já começam no contexto correto.
      return vortexGetCurrentStoreContext().then(function(context) {
        if (context.error || !context.store) {
          console.error('Não foi possível identificar o estabelecimento ativo:', context.error);
          redirectToLogin();
          return;
        }
        document.documentElement.style.visibility = '';
      });
    })
    .catch(redirectToLogin);
}

// Ativa a verificação somente nas páginas internas listadas acima.
// Login, landing page e páginas públicas de clientes permanecem abertas.
vortexRequireAuthenticatedPage();
