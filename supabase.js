// supabase.js - Módulo central de conexão, persistência e sincronização do Vortex Food
const SUPABASE_URL = 'https://oasxlmfwkkubabyvqama.supabase.co';
const SUPABASE_ANON_KEY = 'sb_publishable_r3Ob9dbgz52-_ziLLe9-_w_wvimzPkk';

// Armazenamento local separado por estabelecimento e funcionário.
// Preferências visuais ficam no dispositivo; impressora é compartilhada entre
// funcionários da mesma loja naquele aparelho.
(function installVortexStoreStorage() {
  if (window.__VORTEX_STORE_STORAGE_INSTALLED) return;
  window.__VORTEX_STORE_STORAGE_INSTALLED = true;
  const proto = Storage.prototype;
  const nativeGet = proto.getItem;
  const nativeSet = proto.setItem;
  const nativeRemove = proto.removeItem;
  const nativeKey = proto.key;
  const deviceKeys = new Set(['vortex_active_printer','vortex_printer_settings','vortex_store_logo']);
  const isTenantKey = key => String(key).startsWith('vortex_') && key !== 'vortex_theme';
  const scopedKey = key => {
    if (!window.VORTEX_ACTIVE_STORE_ID) return null;
    if (deviceKeys.has(String(key))) {
      return 'vortex_store_' + window.VORTEX_ACTIVE_STORE_ID + '::device::' + key;
    }
    if (!window.VORTEX_ACTIVE_USER_ID) return null;
    return 'vortex_store_' + window.VORTEX_ACTIVE_STORE_ID + '::' + window.VORTEX_ACTIVE_USER_ID + '::' + key;
  };

  // Antes da identificação da loja, dados operacionais não são lidos nem gravados.
  // Isso impede que dados de demonstração ou de uma sessão sem login sejam
  // transferidos acidentalmente para o primeiro estabelecimento conectado.
  proto.getItem = function(key) {
    if (this === window.localStorage && isTenantKey(key)) {
      const targetKey = scopedKey(key);
      if (!targetKey) return null;
      return nativeGet.call(this, targetKey);
    }
    return nativeGet.call(this, key);
  };
  proto.setItem = function(key, value) {
    if (this === window.localStorage && isTenantKey(key)) {
      const targetKey = scopedKey(key);
      if (!targetKey) return;
      return nativeSet.call(this, targetKey, value);
    }
    return nativeSet.call(this, key, value);
  };
  proto.removeItem = function(key) {
    if (this === window.localStorage && isTenantKey(key)) {
      const targetKey = scopedKey(key);
      if (!targetKey) return;
      return nativeRemove.call(this, targetKey);
    }
    return nativeRemove.call(this, key);
  };

  window.VortexStoreStorage = {
    setStoreId(storeId, userId, role) {
      if (!storeId || !userId) return;
      const normalizedStore = String(storeId);
      const normalizedUser = String(userId);
      const changedUser = window.VORTEX_ACTIVE_USER_ID !== normalizedUser;
      window.VORTEX_ACTIVE_STORE_ID = normalizedStore;
      window.VORTEX_ACTIVE_USER_ID = normalizedUser;

      // Configurações da impressora e logotipo local são compartilhados pelo aparelho dentro da loja, não por funcionário.
      const devicePrefix = 'vortex_store_' + normalizedStore + '::device::';
      const userPrefixForDevice = 'vortex_store_' + normalizedStore + '::' + normalizedUser + '::';
      for (const key of deviceKeys) {
        const deviceKey = devicePrefix + key;
        const userKey = userPrefixForDevice + key;
        if (nativeGet.call(window.localStorage, deviceKey) === null) {
          const userValue = nativeGet.call(window.localStorage, userKey);
          const legacyValue = nativeGet.call(window.localStorage, key);
          if (userValue !== null) nativeSet.call(window.localStorage, deviceKey, userValue);
          else if (legacyValue !== null) nativeSet.call(window.localStorage, deviceKey, legacyValue);
        }
      }

      // Migra o cache antigo (somente loja) para a conta do proprietário.
      // Funcionários nunca herdam caches deixados por outra conta no dispositivo.
      if (role === 'owner' && changedUser) {
        const legacyPrefix = 'vortex_store_' + normalizedStore + '::';
        const userPrefix = legacyPrefix + normalizedUser + '::';
        const storage = window.localStorage;
        for (let i = storage.length - 1; i >= 0; i--) {
          const oldKey = nativeKey.call(storage, i);
          if (!oldKey || !oldKey.startsWith(legacyPrefix) || oldKey.startsWith(userPrefix) || oldKey.startsWith(devicePrefix)) continue;
          const suffix = oldKey.slice(legacyPrefix.length);
          const newKey = userPrefix + suffix;
          if (nativeGet.call(storage, newKey) === null) {
            nativeSet.call(storage, newKey, nativeGet.call(storage, oldKey));
          }
        }
      }
    },
    clearSession() {
      window.VORTEX_ACTIVE_STORE_ID = null;
      window.VORTEX_ACTIVE_USER_ID = null;
      window.VORTEX_AUTH_CONTEXT = null;
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
  const { data, error } = await supabase.rpc('rpc_get_store_operational_settings');
  if (error) return null;
  return data || null;
}

// Valida o vínculo ativo da conta e a mesma função de acesso usada pelas políticas RLS.
async function vortexResolveStoreIdForWrite() {
  const supabase = getSupabase();
  if (!supabase) return { storeId: null, error: new Error('Supabase não inicializado.') };

  // A fonte de verdade é a sessão autenticada + vínculo ativo retornado pelo banco.
  // A política RLS continua sendo a autoridade final para permitir cada gravação.
  const { data: userData, error: userError } = await supabase.auth.getUser();
  if (userError) return { storeId: null, error: userError };
  if (!userData || !userData.user) {
    return { storeId: null, error: new Error('Sessão autenticada não encontrada. Entre novamente.') };
  }

  const { data: membership, error: membershipError } = await supabase
    .from('vortex_store_members')
    .select('store_id, role')
    .eq('user_id', userData.user.id)
    .eq('status', 'active')
    .maybeSingle();

  if (membershipError) return { storeId: null, error: membershipError };
  if (!membership || !membership.store_id) {
    return { storeId: null, error: new Error('Nenhum vínculo ativo com estabelecimento foi encontrado para esta conta.') };
  }

  const storeId = String(membership.store_id);
  if (window.VortexStoreStorage) window.VortexStoreStorage.setStoreId(storeId, userData.user.id, membership.role);
  else { window.VORTEX_ACTIVE_STORE_ID = storeId; window.VORTEX_ACTIVE_USER_ID = userData.user.id; }

  return { storeId, error: null };
}

// Vendas
async function dbSaveSale(saleData) {
  const supabase = getSupabase();
  if (!supabase) return { error: 'Supabase não inicializado' };
  const resolvedStore = await vortexResolveStoreIdForWrite();
  if (resolvedStore.error || !resolvedStore.storeId) return { error: resolvedStore.error || new Error('Estabelecimento ativo não identificado.') };
  const storeId = resolvedStore.storeId;

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

  const { data, error } = await supabase.rpc('rpc_create_sale', { p_store_id: storeId, p_sale: record });
  if (error) console.error('Erro ao salvar venda:', error);

  try {
    const localRecord = { ...record, cloudSyncPending: !!error };
    let localHistory = JSON.parse(localStorage.getItem('vortex_sales_history')) || [];
    const idx = localHistory.findIndex(s => String(s.id) === String(record.id));
    if (idx >= 0) localHistory[idx] = { ...localHistory[idx], ...localRecord };
    else localHistory.unshift(localRecord);
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

  let localPending = [];
  try {
    const cached = JSON.parse(localStorage.getItem('vortex_sales_history')) || [];
    localPending = Array.isArray(cached) ? cached.filter(sale => sale && sale.cloudSyncPending === true) : [];
  } catch(e) {}
  const mergedSales = new Map(mapped.map(sale => [String(sale.id), sale]));
  localPending.forEach(sale => mergedSales.set(String(sale.id), sale));
  const finalSales = Array.from(mergedSales.values());
  try { localStorage.setItem('vortex_sales_history', JSON.stringify(finalSales)); } catch(e) {}
  return finalSales;
}

// KDS Orders
async function dbSaveKdsOrder(orderData) {
  const supabase = getSupabase();
  if (!supabase) return { error: 'Supabase não inicializado' };
  const resolvedStore = await vortexResolveStoreIdForWrite();
  if (resolvedStore.error || !resolvedStore.storeId) return { error: resolvedStore.error || new Error('Estabelecimento ativo não identificado.') };
  const storeId = resolvedStore.storeId;

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

  const { data, error } = await supabase.rpc('rpc_create_kds_order', { p_store_id: storeId, p_order: record });
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

// Grava pedidos KDS com as colunas mínimas já utilizadas por PDV e Mesas.
async function dbSaveKdsOrderMinimal(orderData) {
  const supabase = getSupabase();
  if (!supabase) return { data: null, error: new Error('Supabase não inicializado.') };
  const resolved = await vortexResolveStoreIdForWrite();
  if (resolved.error || !resolved.storeId) return { data: null, error: resolved.error || new Error('Estabelecimento ativo não identificado.') };
  const record = {
    store_id: resolved.storeId, id: String(orderData.id), origin: orderData.origin || 'Balcão',
    client: orderData.client || 'Cliente Balcão', address: orderData.address || '',
    payment: orderData.payment || 'Dinheiro', time: orderData.time || '',
    date: orderData.date || new Date().toISOString().slice(0, 10),
    items: Array.isArray(orderData.items) ? orderData.items : [], total: Number(orderData.total) || 0,
    observation: orderData.observation || '', status: orderData.status || 'new', code: orderData.code || String(orderData.id)
  };
  const { data, error } = await supabase.rpc('rpc_create_kds_order', { p_store_id: resolved.storeId, p_order: record });
  try {
    const localRecord = { ...record, cloudSyncPending: !!error };
    let localOrders = JSON.parse(localStorage.getItem('vortex_kds_orders')) || [];
    const index = localOrders.findIndex(order => String(order.id) === String(record.id));
    if (index >= 0) localOrders[index] = { ...localOrders[index], ...localRecord };
    else localOrders.unshift(localRecord);
    localStorage.setItem('vortex_kds_orders', JSON.stringify(localOrders));
  } catch(e) {}
  return { data, error };
}

async function dbUpdateKdsOrder(orderId, updates) {
  const supabase = getSupabase();
  if (!supabase) return { data: null, error: new Error('Supabase não inicializado.') };
  const resolved = await vortexResolveStoreIdForWrite();
  if (resolved.error || !resolved.storeId) return { data: null, error: resolved.error || new Error('Estabelecimento ativo não identificado.') };
  const safeUpdates = { ...(updates || {}) };
  delete safeUpdates.id; delete safeUpdates.store_id;
  if (Object.keys(safeUpdates).length !== 1 || !safeUpdates.status) {
    return { data: null, error: new Error('Atualização inválida. Alterações de pedido precisam usar uma operação autorizada.') };
  }
  const { data, error } = await supabase.rpc('rpc_update_kds_order_status', {
    p_store_id: resolved.storeId,
    p_order_id: String(orderId),
    p_status: String(safeUpdates.status)
  });
  return { data, error };
}

async function dbFetchKdsOrders() {
  const supabase = getSupabase();
  const storeId = await vortexGetCurrentStoreId();
  if (!storeId) return [];
  if (!supabase) return JSON.parse(localStorage.getItem('vortex_kds_orders')) || [];

  const { data, error } = await supabase.rpc('rpc_get_kds_orders');
  if (error || !Array.isArray(data)) return JSON.parse(localStorage.getItem('vortex_kds_orders')) || [];

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
    code: '',
    displayId: item.displayId || item.displayid || null,
    courier: item.courier || '',
    courier_member_id: item.courier_member_id || null,
    created_by: item.created_by || null
  }));

  // Entregadores recebem somente os pedidos atribuídos retornados pela RPC;
  // nunca mesclam uma lista local antiga que possa conter pedidos de outros motoboys.
  if (window.VORTEX_AUTH_CONTEXT?.profile_key === 'delivery') {
    try { localStorage.setItem('vortex_kds_orders', JSON.stringify(remoteMapped)); } catch (e) {}
    return remoteMapped;
  }

  let localOrders = [];
  try {
    localOrders = JSON.parse(localStorage.getItem('vortex_kds_orders')) || [];
    if (!Array.isArray(localOrders)) localOrders = [];
  } catch (e) {
    localOrders = [];
  }

  const localMap = new Map(localOrders.map(order => {
    const safeOrder = { ...order };
    if (String(safeOrder.origin || '').toLowerCase().includes('delivery')) delete safeOrder.code;
    return [String(safeOrder.id), safeOrder];
  }));
  remoteMapped.forEach(remoteOrder => {
    const localOrder = localMap.get(String(remoteOrder.id)) || {};
    localMap.set(String(remoteOrder.id), {
      ...localOrder,
      ...remoteOrder,
      displayId: remoteOrder.displayId || localOrder.displayId || localOrder.displayid || null
    });
  });

  const mergedOrders = Array.from(localMap.values());
  try { localStorage.setItem('vortex_kds_orders', JSON.stringify(mergedOrders)); } catch (e) {}
  return mergedOrders;
}

/**
 * REGRA CENTRAL DE CONSUMO DE ESTOQUE AO ENTRAR EM PREPARO (IDEMPOTENTE)
 */
async function processStockConsumptionForOrder(order) {
  if (!order || !order.id) return { success: true, skipped: true, reason: 'no_order' };
  const supabase = getSupabase();
  const storeId = await vortexGetCurrentStoreId();
  if (!supabase || !storeId) return { success: false, skipped: false, error: new Error('Conexão ou estabelecimento não disponível para sincronizar o estoque.') };
  try {
    // O banco busca o pedido, a ficha técnica e os insumos. O navegador não
    // envia quantidades de baixa que poderiam ser adulteradas.
    const { data, error } = await supabase.rpc('rpc_consume_stock_for_order_secure', {
      p_store_id: storeId,
      p_order_id: String(order.id)
    });
    if (error) throw error;
    if (!data || data.success !== true) throw new Error((data && data.message) || 'O banco não confirmou o consumo do estoque.');
    const [cloudStock, cloudMovements] = await Promise.all([
      typeof dbFetchStock === 'function' ? dbFetchStock() : Promise.resolve(null),
      typeof dbFetchStockMovements === 'function' ? dbFetchStockMovements() : Promise.resolve(null)
    ]);
    if (Array.isArray(cloudStock)) localStorage.setItem('vortex_stock_items', JSON.stringify(cloudStock));
    if (Array.isArray(cloudMovements)) localStorage.setItem('vortex_stock_movements', JSON.stringify(cloudMovements));
    return { success: true, skipped: !!data.skipped, movements: Number(data.movements) || 0, data };
  } catch (e) {
    console.error('Erro ao processar consumo automático de estoque:', e);
    return { success: false, skipped: false, error: e };
  }
}

// Cancelamento Idempotente Central
async function dbCancelOrder(orderId, reason = 'Cancelado via operação') {
  const supabase = getSupabase();
  const resolved = await vortexResolveStoreIdForWrite();
  if (resolved.error || !resolved.storeId) return { success: false, error: resolved.error || new Error('Estabelecimento ativo não identificado.') };
  const cancelTimestamp = new Date().toISOString();

  if (supabase) {
    try {
      // A RPC identifica a loja pelo vínculo autenticado e atualiza somente
      // os registros correspondentes dentro dessa loja.
      const { data, error } = await supabase.rpc('rpc_cancel_order', {
        p_order_id: String(orderId),
        p_reason: reason
      });

      if (error) throw error;
      if (!data || data.success !== true) {
        return { success: false, error: new Error((data && data.message) || 'O banco não confirmou o cancelamento.') };
      }

      updateLocalCachesAfterCancel(orderId, reason, cancelTimestamp);
      return { success: true, data };
    } catch (clientErr) {
      return { success: false, error: clientErr };
    }
  }

  return { success: false, error: new Error('Conexão com o servidor indisponível. O cancelamento não foi realizado.') };
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
  if (!items.length) return { data: { success: true, processed: 0 }, error: null };

  const records = items.map(i => ({
    id: String(i.id),
    name: i.name,
    category: i.category,
    unit: i.unit,
    qty: parseFloat(i.qty) || 0,
    cost: i.cost == null ? null : (parseFloat(i.cost) || 0),
    min_stock: parseFloat(i.minStock) || 0,
    barcode: i.barcode || ''
  }));
  const { data, error } = await supabase.rpc('rpc_save_stock_items', {
    p_store_id: storeId,
    p_items: records
  });
  return { data, error };
}

async function dbDeleteStockItem(itemId) {
  const supabase = getSupabase();
  if (!supabase) return { error: new Error('Supabase não inicializado') };
  const storeId = await vortexGetCurrentStoreId();
  if (!storeId) return { error: new Error('Estabelecimento ativo não identificado.') };
  const { data, error } = await supabase.rpc('rpc_delete_stock_item', {
    p_store_id: storeId,
    p_item_id: String(itemId)
  });
  return { data, error };
}

async function dbAdjustStockItem(itemId, type, qty, unitCost, reason, idempotencyKey) {
  const supabase = getSupabase();
  if (!supabase) return { error: new Error('Supabase não inicializado') };
  const storeId = await vortexGetCurrentStoreId();
  if (!storeId) return { error: new Error('Estabelecimento ativo não identificado.') };
  const { data, error } = await supabase.rpc('rpc_adjust_stock_item', {
    p_store_id: storeId,
    p_item_id: String(itemId),
    p_type: String(type),
    p_qty: Number(qty) || 0,
    p_unit_cost: Number(unitCost) || 0,
    p_reason: String(reason || ''),
    p_idempotency_key: String(idempotencyKey || '')
  });
  return { data, error };
}

async function dbSaveStockMovements(movements) {
  return { error: new Error('Movimentações manuais precisam ser registradas junto com o ajuste de quantidade pelo módulo de Estoque.') };
}

async function dbFetchStockMovements() {
  const supabase = getSupabase();
  if (!supabase) return null;
  const storeId = await vortexGetCurrentStoreId();
  if (!storeId) return [];
  const { data, error } = await supabase.rpc('rpc_get_stock_movements', { p_store_id: storeId });
  if (error || !Array.isArray(data)) return null;
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
  const { data, error } = await supabase.rpc('rpc_get_stock_items', { p_store_id: storeId });
  if (error || !Array.isArray(data)) return null;
  return data.map(i => ({
    id: i.id,
    name: i.name,
    category: i.category,
    unit: i.unit,
    qty: parseFloat(i.qty) || 0,
    cost: i.cost == null ? null : (parseFloat(i.cost) || 0),
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

async function dbSaveCashFinancialEntry(entryData, shiftId, movementData) {
  const supabase = getSupabase();
  if (!supabase) return { data: null, error: new Error('Supabase não inicializado.') };
  const storeId = await vortexGetCurrentStoreId();
  if (!storeId) return { data: null, error: new Error('Estabelecimento ativo não identificado.') };
  const { data, error } = await supabase.rpc('rpc_record_cash_movement', {
    p_store_id: storeId,
    p_shift_id: String(shiftId || ''),
    p_entry_id: String(entryData.id || ''),
    p_type: String(entryData.type || ''),
    p_movement_type: String(movementData.type || ''),
    p_description: String(entryData.description || movementData.reason || ''),
    p_value: Number(entryData.value) || 0,
    p_date: String(entryData.date || new Date().toISOString().slice(0,10))
  });
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
  const data = await dbFetchStoreDocument('coupons');
  return Array.isArray(data) ? data : null;
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
  const data = await dbFetchStoreDocument('customers');
  return Array.isArray(data) ? data : null;
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
  const { data, error } = await supabase.rpc('rpc_save_store_document', {
    p_document_key: String(documentKey),
    p_data: documentData
  });
  return { data, error };
}

async function dbFetchStoreDocument(documentKey) {
  const supabase = getSupabase();
  const storeId = await vortexGetCurrentStoreId();
  if (!supabase || !storeId) return null;
  const { data, error } = await supabase.rpc('rpc_get_store_document', {
    p_document_key: String(documentKey)
  });
  if (error) return null;
  return data;
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

/* Quantidade de mesas sincronizada por estabelecimento e validada também no banco. */
async function dbSyncPublicTableCount(localCount) {
  const supabase = getSupabase();
  const storeId = await vortexGetCurrentStoreId();
  if (!supabase || !storeId) return { data: null, error: new Error('Estabelecimento ativo não identificado.') };

  const tableSettings = await dbFetchStoreDocument('table_settings');
  const cloudCount = Number(tableSettings && tableSettings.totalTablesCount);
  if (Number.isInteger(cloudCount) && cloudCount >= 1 && cloudCount <= 200) {
    return { data: cloudCount, error: null };
  }

  const initialCount = Number.isInteger(Number(localCount))
    ? Math.max(1, Math.min(200, Number(localCount)))
    : 10;
  if (!window.VORTEX_AUTH_CONTEXT?.permissions?.includes('tables.manage_qr')) {
    return { data: initialCount, error: null };
  }
  const saved = await dbSaveStoreDocument('table_settings', { totalTablesCount: initialCount });
  if (saved && saved.error) return { data: null, error: saved.error };
  return { data: initialCount, error: null };
}

async function dbSavePublicTableCount(count) {
  const safeCount = Number(count);
  if (!Number.isInteger(safeCount) || safeCount < 1 || safeCount > 200) {
    return { error: new Error('A quantidade de mesas deve ficar entre 1 e 200.') };
  }
  return await dbSaveStoreDocument('table_settings', { totalTablesCount: safeCount });
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
  const { data, error } = await supabase.rpc('rpc_get_integrations');
  return error || !Array.isArray(data) ? [] : data;
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
  const result = await supabase.auth.signOut();
  if (!result.error && window.VortexStoreStorage) window.VortexStoreStorage.clearSession();
  return result;
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
  if (!userData || !userData.user) return { store: null, subscription: null, error: new Error('Entre na sua conta para consultar o estabelecimento.') };

  const { data: permissionContext, error: permissionError } = await supabase.rpc('rpc_get_my_permissions');
  if (permissionError || !permissionContext || !permissionContext.store_id) {
    return { store: null, subscription: null, error: permissionError || new Error('As permissões desta conta não foram encontradas.') };
  }

  const { data: store, error: storeError } = await supabase.rpc('rpc_get_my_store_context');
  if (storeError) return { store: null, subscription: null, error: storeError };
  if (!store || String(store.id) !== String(permissionContext.store_id)) {
    return { store: null, subscription: null, error: new Error('Não foi possível validar o estabelecimento ativo desta conta.') };
  }
  if (store.status !== 'active') {
    return { store: null, subscription: null, error: new Error('Este estabelecimento está inativo. Entre em contato com o suporte.') };
  }

  if (window.VortexStoreStorage) window.VortexStoreStorage.setStoreId(store.id, userData.user.id, permissionContext.role);
  else {
    window.VORTEX_ACTIVE_STORE_ID = String(store.id);
    window.VORTEX_ACTIVE_USER_ID = userData.user.id;
  }

  window.VORTEX_AUTH_CONTEXT = {
    ...permissionContext,
    user_id: userData.user.id,
    email: userData.user.email || permissionContext.email || '',
    store_name: store.name || ''
  };

  // Se as permissões mudaram desde a última sessão, remove apenas caches de
  // módulos que esta conta deixou de poder consultar. Os dados na nuvem não são alterados.
  try {
    const currentPermissions = new Set(Array.isArray(permissionContext.permissions) ? permissionContext.permissions : []);
    const previousSignature = localStorage.getItem('vortex_permission_cache_signature');
    const currentSignature = JSON.stringify(Array.from(currentPermissions).sort());
    if (previousSignature && previousSignature !== currentSignature) {
      const hasAny = keys => keys.some(key => currentPermissions.has(key));
      const clearKeys = keys => keys.forEach(key => localStorage.removeItem(key));
      if (!hasAny(['pdv.history','reports.view','finance.view'])) clearKeys(['vortex_sales_history']);
      // Qualquer mudança de permissões invalida a cópia local de pedidos; a nuvem devolverá novamente apenas os campos autorizados.\n      clearKeys(['vortex_kds_orders']);
      if (!currentPermissions.has('stock.view')) clearKeys(['vortex_stock_items','vortex_stock_movements']);
      if (!hasAny(['finance.view','reports.financial'])) clearKeys(['vortex_financial_entries','vortex_bank_accounts']);
      if (!currentPermissions.has('cash.view')) clearKeys(['vortex_closed_shifts','vortex_current_cash']);
      if (!currentPermissions.has('team.view')) clearKeys(['vortex_team_members','vortex_team_sync_pending']);
      if (!hasAny(['delivery.manage','delivery.manage_couriers'])) clearKeys(['vortex_couriers','vortex_courier_history']);
      if (!hasAny(['integrations.view','integrations.manage'])) {
        clearKeys(['vortex_integrations_data']);
      } else if (!currentPermissions.has('integrations.manage')) {
        try {
          const integrationCache = JSON.parse(localStorage.getItem('vortex_integrations_data') || '{}') || {};
          Object.keys(integrationCache).forEach(platform => {
            integrationCache[platform] = { connected: !!integrationCache[platform]?.connected, credentials: null };
          });
          localStorage.setItem('vortex_integrations_data', JSON.stringify(integrationCache));
        } catch (error) {
          clearKeys(['vortex_integrations_data']);
        }
      }
      if (!hasAny(['recipes.view','reports.view'])) clearKeys(['vortex_recipes_catalog','vortex_fichas_tecnicas']);
      if (!hasAny(['purchases.view','purchases.manage'])) clearKeys(['vortex_compras_data']);
      if (!hasAny(['accounts.view','accounts.manage'])) clearKeys(['vortex_contas_data']);
      if (!hasAny(['crm.view','crm.manage'])) clearKeys(['vortex_customers_catalog']);
      if (!currentPermissions.has('coupons.manage')) clearKeys(['vortex_coupons_catalog']);
      if (!currentPermissions.has('loyalty.manage')) clearKeys(['vortex_loyalty_settings','vortex_clients_loyalty','vortex_loyalty_rewards']);
      if (!hasAny(['catalog.view','delivery.manage'])) clearKeys(['vortex_products_catalog','vortex_groups_catalog','vortex_complements_catalog','vortex_cardapio_produtos','vortex_trash_catalog','vortex_synced_catalog']);
      if (!currentPermissions.has('tables.view')) clearKeys(['vortex_table_carts','vortex_total_tables','vortex_qr_enabled']);
      if (!hasAny(['fiscal.view','fiscal.manage'])) clearKeys(['vortex_fiscal_config','vortex_invoices_list']);
    }
    if (!currentPermissions.has('stock.view_costs')) {
      const costKeys = new Set(['cost','costPrice','custo','totalCost','unitCost','unit_cost','averageCost','average_cost']);
      const stripCosts = value => {
        if (Array.isArray(value)) return value.map(stripCosts);
        if (value && typeof value === 'object') {
          const safe = {};
          Object.keys(value).forEach(key => {
            if (!costKeys.has(key)) safe[key] = stripCosts(value[key]);
          });
          return safe;
        }
        return value;
      };
      ['vortex_stock_items','vortex_stock_movements','vortex_products_catalog','vortex_cardapio_produtos','vortex_synced_catalog','vortex_recipes_catalog','vortex_fichas_tecnicas'].forEach(key => {
        try {
          const raw = localStorage.getItem(key);
          if (raw) localStorage.setItem(key, JSON.stringify(stripCosts(JSON.parse(raw))));
        } catch (error) {}
      });
    }
    localStorage.setItem('vortex_permission_cache_signature', currentSignature);
  } catch (cachePolicyError) {
    console.warn('Não foi possível atualizar a política de cache das permissões:', cachePolicyError);
  }

  // Remove códigos antigos de Delivery do cache da conta atual.
  try {
    const cachedOrders = JSON.parse(localStorage.getItem('vortex_kds_orders') || '[]');
    if (Array.isArray(cachedOrders)) {
      let changed = false;
      const safeOrders = cachedOrders.map(order => {
        if (String(order.origin || '').toLowerCase().includes('delivery') && Object.prototype.hasOwnProperty.call(order, 'code')) {
          const safeOrder = { ...order };
          delete safeOrder.code;
          changed = true;
          return safeOrder;
        }
        return order;
      });
      if (changed) localStorage.setItem('vortex_kds_orders', JSON.stringify(safeOrders));
    }
  } catch (error) {
    console.warn('Não foi possível limpar códigos antigos do cache local de Delivery:', error);
  }

  const canViewSubscription = Array.isArray(permissionContext.permissions)
    && permissionContext.permissions.includes('subscription.view');
  const subscriptionResult = canViewSubscription
    ? await vortexGetSubscription(store.id)
    : { data: null, error: null };

  return {
    store,
    subscription: subscriptionResult.error ? null : subscriptionResult.data,
    subscriptionError: subscriptionResult.error || null,
    member: permissionContext,
    permissions: permissionContext.permissions || [],
    error: null
  };
}
async function vortexGetMyPermissions() {
  const supabase = getSupabase();
  if (!supabase) return { data: null, error: new Error('Conexão com Supabase indisponível.') };
  const { data, error } = await supabase.rpc('rpc_get_my_permissions');
  if (!error && data) window.VORTEX_AUTH_CONTEXT = data;
  return { data, error };
}

async function vortexAcceptStaffInvitation() {
  const supabase = getSupabase();
  if (!supabase) return { data: null, error: new Error('Conexão com Supabase indisponível.') };
  return await supabase.rpc('rpc_accept_staff_invitation');
}

async function vortexResolveLoginAccount() {
  const supabase = getSupabase();
  if (!supabase) return { data: null, error: new Error('Conexão com Supabase indisponível.') };

  const { data: state, error: stateError } = await supabase.rpc('rpc_get_my_account_state');
  if (stateError || !state) return { data: null, error: stateError || new Error('Não foi possível verificar o tipo da conta.') };

  if (state.state === 'unregistered') {
    const registration = await vortexCompleteStoreRegistration();
    if (registration.error) return registration;
  } else if (state.state === 'invitation_pending') {
    const accepted = await vortexAcceptStaffInvitation();
    if (accepted.error) return accepted;
  } else if (state.state !== 'active') {
    return { data: null, error: new Error('Esta conta está inativa ou precisa de revisão. Entre em contato com o proprietário da loja.') };
  }

  return await vortexGetMyPermissions();
}

async function vortexGetPermissionCatalog() {
  const supabase = getSupabase();
  if (!supabase) return { data: null, error: new Error('Conexão com Supabase indisponível.') };
  return await supabase.rpc('rpc_get_permission_catalog');
}

async function vortexGetMemberPermissionSettings(targetUserId) {
  const supabase = getSupabase();
  if (!supabase) return { data: null, error: new Error('Conexão com Supabase indisponível.') };
  return await supabase.rpc('rpc_get_member_permission_settings', { p_target_user_id: String(targetUserId) });
}

async function vortexInviteStaff(staffRecordId, email, profileKey) {
  const supabase = getSupabase();
  if (!supabase) return { data: null, error: new Error('Conexão com Supabase indisponível.') };
  return await supabase.functions.invoke('invite-staff', {
    body: {
      staff_record_id: String(staffRecordId),
      email: String(email || '').trim(),
      profile_key: String(profileKey || 'attendant')
    }
  });
}

async function vortexManageStaffAccount(staffRecordId, action) {
  const supabase = getSupabase();
  if (!supabase) return { data: null, error: new Error('Conexão com Supabase indisponível.') };
  return await supabase.functions.invoke('manage-staff-account', {
    body: { staff_record_id: String(staffRecordId), action: String(action || '') }
  });
}

async function vortexManageStaffPermissions(targetUserId, profileKey, overrides, currentPassword) {
  const supabase = getSupabase();
  if (!supabase) return { data: null, error: new Error('Conexão com Supabase indisponível.') };
  return await supabase.functions.invoke('manage-staff-permissions', {
    body: {
      target_user_id: String(targetUserId),
      profile_key: String(profileKey || ''),
      overrides: Array.isArray(overrides) ? overrides : [],
      current_password: String(currentPassword || '')
    }
  });
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
  requireAuthenticatedPage: vortexRequireAuthenticatedPage,
  resolveLoginAccount: vortexResolveLoginAccount,
  getMyPermissions: vortexGetMyPermissions,
  acceptStaffInvitation: vortexAcceptStaffInvitation,
  getPermissionCatalog: vortexGetPermissionCatalog,
  getMemberPermissionSettings: vortexGetMemberPermissionSettings,
  inviteStaff: vortexInviteStaff,
  manageStaffPermissions: vortexManageStaffPermissions,
  manageStaffAccount: vortexManageStaffAccount
};

const VORTEX_PAGE_PERMISSION_MAP = {
  'index.html': 'dashboard.view',
  'modulo-mensalidade.html': 'subscription.view',
  'modulo2-cardapio.html': 'catalog.view',
  'modulo3-pdv.html': 'pdv.view',
  'modulo5-mesas.html': 'tables.view',
  'modulo6-cardapio-online.html': 'catalog.view',
  'modulo7-8-kds-pedidos.html': 'kds.view',
  'modulo9-equipe.html': 'team.view',
  'modulo10-relatorios.html': 'reports.view',
  'modulo12-estoque.html': 'stock.view',
  'modulo13-fichas-tecnicas.html': 'recipes.view',
  'modulo14-compras.html': 'purchases.view',
  'modulo15-financeiro.html': 'finance.view',
  'modulo16-contas.html': 'accounts.view',
  'modulo17-caixa-turno.html': 'cash.view',
  'modulo18-crm.html': 'crm.view',
  'modulo19-fiscal.html': 'fiscal.view',
  'modulo21-delivery.html': 'delivery.view',
  'modulo-configuracoes.html': 'settings.view',
  'modulo-dados-estabelecimento.html': 'settings.view',
  'modulo-cupons.html': 'coupons.manage',
  'modulo-fidelidade.html': 'loyalty.manage',
  'modulo-impressoras.html': 'printers.manage',
  'modulo-integracoes.html': 'integrations.view',
  'modulo-marketing.html': 'marketing.manage'
};

const VORTEX_PERMISSION_LABELS = {
  'dashboard.view': 'Proprietário, Administrador, Gerente, Atendente, Cozinha e Entregador',
  'pdv.view': 'Proprietário, Administrador, Gerente e Atendente',
  'tables.view': 'Proprietário, Administrador, Gerente e Atendente',
  'delivery.view': 'Proprietário, Administrador, Gerente, Atendente e Entregador',
  'kds.view': 'Proprietário, Administrador, Gerente, Atendente e Cozinha',
  'team.view': 'Proprietário, Administrador e Gerente',
  'catalog.view': 'Proprietário, Administrador e Gerente',
  'recipes.view': 'Proprietário, Administrador e Gerente',
  'stock.view': 'Proprietário, Administrador e Gerente',
  'purchases.view': 'Proprietário, Administrador e Gerente',
  'finance.view': 'Proprietário, Administrador e Gerente',
  'accounts.view': 'Proprietário, Administrador e Gerente',
  'cash.view': 'Proprietário, Administrador, Gerente e Atendente',
  'reports.view': 'Proprietário, Administrador e Gerente',
  'crm.view': 'Proprietário, Administrador e Gerente',
  'coupons.manage': 'Proprietário, Administrador e Gerente',
  'loyalty.manage': 'Proprietário, Administrador e Gerente',
  'marketing.manage': 'Proprietário, Administrador e Gerente',
  'integrations.view': 'Proprietário e Administrador',
  'settings.view': 'Proprietário e Administrador',
  'printers.manage': 'Proprietário, Administrador e Gerente',
  'fiscal.view': 'Proprietário, Administrador e Gerente',
  'subscription.view': 'Proprietário e Administrador'
};

function vortexPermissionHas(permissionKey) {
  const permissions = window.VORTEX_AUTH_CONTEXT && window.VORTEX_AUTH_CONTEXT.permissions;
  return Array.isArray(permissions) && permissions.includes(permissionKey);
}

function vortexShowAccessDeniedModal(profiles) {
  if (!document.body || document.getElementById('vortexAccessDeniedOverlay')) return;
  const overlay = document.createElement('div');
  overlay.id = 'vortexAccessDeniedOverlay';
  overlay.innerHTML = `
    <section id="vortexAccessDeniedCard" role="dialog" aria-modal="true" aria-labelledby="vortexAccessDeniedTitle">
      <div class="vortex-access-denied-icon" aria-hidden="true">🔒</div>
      <h2 id="vortexAccessDeniedTitle">Acesso não autorizado</h2>
      <p>Seu perfil atual não tem permissão para acessar este módulo.</p>
      <p class="vortex-access-denied-profiles"><strong>Perfis autorizados:</strong> <span id="vortexAccessDeniedProfiles"></span></p>
      <p>Solicite ao proprietário uma revisão das suas permissões.</p>
      <div class="vortex-access-denied-actions"><button type="button" id="vortexAccessDeniedClose">Entendi</button></div>
    </section>`;
  document.body.appendChild(overlay);
  document.getElementById('vortexAccessDeniedProfiles').textContent = String(profiles || 'Proprietário e Administrador');
  const close = () => {
    overlay.remove();
    document.removeEventListener('keydown', escapeHandler);
  };
  const escapeHandler = event => { if (event.key === 'Escape') close(); };
  document.getElementById('vortexAccessDeniedClose').addEventListener('click', close);
  overlay.addEventListener('click', event => { if (event.target === overlay) close(); });
  document.addEventListener('keydown', escapeHandler);
  document.getElementById('vortexAccessDeniedClose').focus();
}

function vortexRenderEmployeeChrome(context) {
  if (!context || !document.body) return;
  if (document.readyState === 'loading') {
    if (!window.__VORTEX_CHROME_WAITING) {
      window.__VORTEX_CHROME_WAITING = true;
      document.addEventListener('DOMContentLoaded', function() {
        window.__VORTEX_CHROME_WAITING = false;
        vortexRenderEmployeeChrome(window.VORTEX_AUTH_CONTEXT);
      }, { once: true });
    }
    return;
  }

  const profileLabels = {
    owner: 'Proprietário',
    administrator: 'Administrador',
    manager: 'Gerente',
    attendant: 'Atendente',
    kitchen: 'Equipe de cozinha',
    delivery: 'Entregador'
  };
  const profileLabel = profileLabels[context.profile_key] || 'Equipe';
  const displayName = context.display_name || context.email || 'Usuário';
  const header = document.querySelector('header');

  if (!document.getElementById('vortexEmployeeIdentity')) {
    const identity = document.createElement('div');
    identity.id = 'vortexEmployeeIdentity';
    identity.innerHTML = `
      <div class="vortex-identity-copy">
        <strong>${displayName.replace(/[<>]/g, '')}</strong>
        <span>${profileLabel} · <span class="vortex-connected">Conectado</span></span>
      </div>
      <div class="vortex-identity-actions">
        <button type="button" id="vortexLockButton">🔒 Bloquear tela</button>
        <button type="button" id="vortexSwitchButton">⇄ Trocar usuário</button>
      </div>`;
    if (header) header.appendChild(identity);
    else document.body.insertBefore(identity, document.body.firstChild);
    document.getElementById('vortexLockButton').addEventListener('click', function() { vortexShowLockScreen(false); });
    document.getElementById('vortexSwitchButton').addEventListener('click', vortexSwitchUser);
  }

  const blockedPermission = new URLSearchParams(window.location.search).get('blocked');
  if (blockedPermission && !window.__VORTEX_BLOCKED_NOTICE_SHOWN) {
    window.__VORTEX_BLOCKED_NOTICE_SHOWN = true;
    const profiles = VORTEX_PERMISSION_LABELS[blockedPermission] || 'Proprietário e Administrador';
    window.setTimeout(() => vortexShowAccessDeniedModal(profiles), 150);
  }

  // Navegação centralizada: módulos de conta e estabelecimento aparecem
  // em todas as páginas internas sem exigir edição manual de cada menu.
  document.querySelectorAll('.sidebar-nav').forEach(nav => {
    if (nav.querySelector('[data-vortex-account-navigation="true"]')) return;
    const section = document.createElement('div');
    section.className = 'nav-section';
    section.dataset.vortexAccountNavigation = 'true';
    section.innerHTML = `
      <span class="nav-section-title">CONTA & ESTABELECIMENTO</span>
      <a href="modulo-dados-estabelecimento.html" class="nav-link"><span class="nav-icon">🏪</span><span class="nav-text">Dados do Estabelecimento</span></a>
    `;
    nav.appendChild(section);
  });
  document.querySelectorAll('.sidebar-menu').forEach(nav => {
    if (nav.querySelector('[data-vortex-account-navigation="true"]')) return;
    const group = document.createElement('div');
    group.dataset.vortexAccountNavigation = 'true';
    group.innerHTML = `
      <div class="menu-group-label">Conta & Estabelecimento</div>
      <a href="modulo-dados-estabelecimento.html" class="menu-item nav-link">🏪 Dados do Estabelecimento</a>
    `;
    nav.appendChild(group);
  });

  document.querySelectorAll('.nav-link[href]').forEach(link => {
    if (link.dataset.vortexPermissionApplied === 'true') return;
    const href = link.getAttribute('href') || '';
    const page = href.split('/').pop().split('?')[0];
    const permission = VORTEX_PAGE_PERMISSION_MAP[page];
    if (!permission) return;
    link.dataset.vortexPermissionApplied = 'true';
    const allowed = vortexPermissionHas(permission);
    const state = document.createElement('span');
    state.className = 'vortex-permission-state ' + (allowed ? 'is-allowed' : 'is-blocked');
    state.textContent = allowed ? '🔓✅' : '🔒❌';
    state.setAttribute('aria-label', allowed ? 'Acesso permitido' : 'Acesso bloqueado');
    state.title = allowed ? 'Acesso permitido' : 'Acesso bloqueado';
    link.appendChild(state);
    if (!allowed) {
      link.classList.add('vortex-nav-blocked');
      link.setAttribute('aria-disabled', 'true');
      link.addEventListener('click', function(event) {
        event.preventDefault();
        const profiles = VORTEX_PERMISSION_LABELS[permission] || 'Proprietário e Administrador';
        vortexShowAccessDeniedModal(profiles);
      });
    }
  });

  if (!document.getElementById('vortexEmployeeChromeStyles')) {
    const style = document.createElement('style');
    style.id = 'vortexEmployeeChromeStyles';
    style.textContent = `
      #vortexEmployeeIdentity{display:flex;align-items:center;justify-content:space-between;gap:12px;flex-wrap:wrap;width:100%;padding:10px 12px;margin-top:10px;border:1px solid var(--border,#334155);border-radius:10px;background:var(--bg-card,#1e293b);font-size:12px}
      .vortex-identity-copy{display:flex;flex-direction:column;gap:3px;color:var(--text-muted,#94a3b8)}
      .vortex-identity-copy strong{font-size:13px;color:var(--text-main,#f8fafc)}
      .vortex-connected{color:#22c55e;font-weight:700}
      .vortex-identity-actions{display:flex;gap:7px;flex-wrap:wrap}
      .vortex-identity-actions button{border:1px solid var(--border,#334155);border-radius:7px;background:transparent;color:var(--text-main,#f8fafc);padding:7px 9px;font-size:11px;font-weight:700;cursor:pointer}
      .vortex-permission-state{margin-left:auto;font-size:12px;font-weight:700;white-space:nowrap;letter-spacing:.02em}
      .vortex-permission-state.is-allowed{color:#22c55e}
      .vortex-permission-state.is-blocked{color:#f87171}
      .vortex-nav-blocked{opacity:.65;cursor:not-allowed}
      #vortexAccessDeniedOverlay{position:fixed;inset:0;z-index:100000;background:rgba(2,6,23,.76);backdrop-filter:blur(4px);display:flex;align-items:center;justify-content:center;padding:20px}
      #vortexAccessDeniedCard{width:min(100%,430px);background:var(--bg-card,#1e293b);color:var(--text-main,#f8fafc);border:1px solid var(--border,#475569);border-radius:18px;padding:26px;box-shadow:0 24px 80px rgba(0,0,0,.38);font-family:inherit}
      .vortex-access-denied-icon{width:48px;height:48px;display:grid;place-items:center;border-radius:14px;background:rgba(248,113,113,.13);font-size:25px;margin-bottom:14px}
      #vortexAccessDeniedCard h2{font-size:19px;margin:0 0 12px;color:var(--text-main,#f8fafc)}
      #vortexAccessDeniedCard p{font-size:13px;line-height:1.6;color:var(--text-muted,#cbd5e1);margin:8px 0}
      #vortexAccessDeniedCard .vortex-access-denied-profiles{padding:10px 12px;border:1px solid var(--border,#475569);border-radius:9px;background:rgba(148,163,184,.07)}
      #vortexAccessDeniedCard .vortex-access-denied-profiles strong{color:var(--text-main,#f8fafc)}
      .vortex-access-denied-actions{display:flex;justify-content:flex-end;margin-top:20px}
      #vortexAccessDeniedClose{border:0;border-radius:9px;background:#f97316;color:#fff;padding:10px 20px;font-size:13px;font-weight:700;cursor:pointer}
      #vortexAccessDeniedClose:hover{background:#ea580c}
      #vortexLockOverlay{position:fixed;inset:0;z-index:99999;background:rgba(2,6,23,.97);display:flex;align-items:center;justify-content:center;padding:20px}
      #vortexLockCard{width:min(100%,390px);background:#1e293b;color:#f8fafc;border:1px solid #475569;border-radius:16px;padding:24px}
      #vortexLockCard input{width:100%;padding:12px;margin:12px 0;background:#0f172a;color:#fff;border:1px solid #475569;border-radius:8px}
      #vortexLockCard button{padding:11px 14px;border:0;border-radius:8px;background:#f97316;color:#fff;font-weight:700;cursor:pointer}
      #vortexLockCard button:disabled{opacity:.65;cursor:wait}
      #vortexLockError{color:#fca5a5;font-size:12px;min-height:18px;line-height:1.5}
      @media(max-width:600px){#vortexEmployeeIdentity{align-items:flex-start}.vortex-identity-actions{width:100%}.vortex-identity-actions button{flex:1}}
    `;
    document.head.appendChild(style);
  }
}

const VORTEX_SESSION_LOCK_KEY = 'vf_session_locks_v1';

function vortexLockIdentity(context = window.VORTEX_AUTH_CONTEXT || {}) {
  const storeId = context.store_id || window.VORTEX_ACTIVE_STORE_ID;
  const userId = context.user_id || window.VORTEX_ACTIVE_USER_ID;
  if (!storeId || !userId) return null;
  return String(storeId) + '::' + String(userId);
}

function vortexReadSessionLocks() {
  const raw = localStorage.getItem(VORTEX_SESSION_LOCK_KEY);
  if (!raw) return {};
  try {
    const parsed = JSON.parse(raw);
    return parsed && parsed.locks && typeof parsed.locks === 'object' ? parsed.locks : {};
  } catch (error) {
    return {};
  }
}

function vortexSetSessionLocked(locked) {
  try {
    const identity = vortexLockIdentity();
    if (!identity) throw new Error('Identidade da sessão ainda não foi identificada.');
    const locks = vortexReadSessionLocks();
    if (locked) locks[identity] = new Date().toISOString();
    else delete locks[identity];

    if (Object.keys(locks).length) {
      const value = JSON.stringify({ locks: locks });
      localStorage.setItem(VORTEX_SESSION_LOCK_KEY, value);
      sessionStorage.setItem(VORTEX_SESSION_LOCK_KEY, value);
    } else {
      localStorage.removeItem(VORTEX_SESSION_LOCK_KEY);
      sessionStorage.removeItem(VORTEX_SESSION_LOCK_KEY);
    }
  } catch (error) {
    console.warn('Não foi possível atualizar o estado de bloqueio local:', error);
  }
}

function vortexIsSessionLocked(context = window.VORTEX_AUTH_CONTEXT || {}) {
  try {
    const identity = vortexLockIdentity(context);
    const locks = vortexReadSessionLocks();

    // Migra o marcador individual da versão anterior sem afetar outros funcionários.
    if (identity) {
      const legacyKey = 'vf_session_locked::' + identity;
      if (localStorage.getItem(legacyKey) === '1') {
        locks[identity] = new Date().toISOString();
        localStorage.setItem(VORTEX_SESSION_LOCK_KEY, JSON.stringify({ locks: locks }));
        localStorage.removeItem(legacyKey);
      }
      return Object.prototype.hasOwnProperty.call(locks, identity);
    }

    // Antes de identificar a conta, qualquer marcador exige que a página
    // permaneça oculta até que o contexto autenticado seja carregado.
    return Object.keys(locks).length > 0;
  } catch (error) {
    // Falha fechada: não libera a página se não conseguir consultar o marcador.
    return true;
  }
}
function vortexShowLockScreen(fromOtherTab = false) {
  if (document.getElementById('vortexLockOverlay')) return;
  const context = window.VORTEX_AUTH_CONTEXT || {};
  if (!fromOtherTab) vortexSetSessionLocked(true);

  const overlay = document.createElement('div');
  overlay.id = 'vortexLockOverlay';
  overlay.innerHTML = `
    <div id="vortexLockCard" role="dialog" aria-modal="true" aria-labelledby="vortexLockTitle">
      <div style="font-size:28px;margin-bottom:8px">🔒</div>
      <h2 id="vortexLockTitle" style="font-size:20px;margin-bottom:8px">Tela bloqueada</h2>
      <p style="font-size:13px;line-height:1.5;color:#cbd5e1">Esta sessão pertence a <strong>${String(context.display_name || context.email || 'este usuário').replace(/[<>]/g, '')}</strong>. Informe sua senha para continuar.</p>
      <input id="vortexUnlockPassword" type="password" autocomplete="current-password" placeholder="Sua senha" aria-label="Senha do usuário atual">
      <div id="vortexLockError" role="alert" aria-live="polite"></div>
      <button type="button" id="vortexUnlockButton">Desbloquear</button>
    </div>`;
  document.body.appendChild(overlay);

  const unlock = async function() {
    const button = document.getElementById('vortexUnlockButton');
    const errorBox = document.getElementById('vortexLockError');
    const passwordInput = document.getElementById('vortexUnlockPassword');
    const password = passwordInput ? passwordInput.value : '';
    if (!password) {
      errorBox.textContent = 'Digite sua senha para desbloquear a tela.';
      passwordInput?.focus();
      return;
    }

    button.disabled = true;
    button.textContent = 'Verificando...';
    errorBox.textContent = '';
    try {
      const supabase = getSupabase();
      if (!supabase) throw new Error('Conexão com Supabase indisponível. A tela continua bloqueada.');

      const { data: verification, error: verificationError } = await supabase.functions.invoke('verify-current-password', {
        body: { password }
      });
      if (verificationError) {
        let functionErrorBody = null;
        try {
          if (verificationError.context && typeof verificationError.context.json === 'function') {
            functionErrorBody = await verificationError.context.json();
          }
        } catch (parseError) {}

        if (verificationError.context?.status === 401
          && String(functionErrorBody?.error || '').toLowerCase().includes('senha incorreta')) {
          throw new Error('Senha incorreta.');
        }

        console.error('Falha ao chamar verify-current-password:', {
          name: verificationError.name,
          message: verificationError.message,
          status: verificationError.context?.status,
          body: functionErrorBody
        });
        throw new Error('Não foi possível conectar ao serviço de validação. Verifique sua conexão e tente novamente.');
      }
      if (!verification || verification.success !== true) {
        throw new Error((verification && verification.error) || 'Senha incorreta. A tela continua bloqueada.');
      }

      const freshContext = await vortexGetCurrentStoreContext();
      if (freshContext.error || !freshContext.store || String(freshContext.store.id) !== String(context.store_id)) {
        throw new Error('Esta conta não possui mais acesso ativo à loja. Entre em contato com o proprietário.');
      }

      const previousSignature = JSON.stringify([...(context.permissions || [])].sort());
      const currentSignature = JSON.stringify([...(freshContext.permissions || [])].sort());
      if (previousSignature !== currentSignature || context.profile_key !== freshContext.member?.profile_key) {
        vortexSetSessionLocked(false);
        window.location.reload();
        return;
      }

      vortexSetSessionLocked(false);
      overlay.remove();
    } catch (error) {
      errorBox.textContent = error && error.message ? error.message : 'Não foi possível desbloquear. A tela continua bloqueada.';
      passwordInput.value = '';
      passwordInput.focus();
    } finally {
      if (document.getElementById('vortexUnlockButton')) {
        button.disabled = false;
        button.textContent = 'Desbloquear';
      }
    }
  };

  document.getElementById('vortexUnlockButton').addEventListener('click', unlock);
  document.getElementById('vortexUnlockPassword').addEventListener('keydown', event => {
    if (event.key === 'Enter') unlock();
  });
  document.getElementById('vortexUnlockPassword').focus();
}

async function vortexSwitchUser() {
  vortexSetSessionLocked(false);
  const result = await vortexSignOut();
  if (result.error) {
    window.alert('Não foi possível encerrar a sessão. Tente novamente.');
    return;
  }
  window.location.href = 'login.html?switch=1';
}

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
        const currentPage = window.location.pathname.split('/').pop() || 'index.html';
        const requiredPermission = VORTEX_PAGE_PERMISSION_MAP[currentPage];
        if (requiredPermission && !vortexPermissionHas(requiredPermission)) {
          window.location.replace('index.html?blocked=' + encodeURIComponent(requiredPermission));
          return;
        }
        vortexRenderEmployeeChrome(window.VORTEX_AUTH_CONTEXT);
        // O overlay é criado enquanto o documento ainda está oculto, impedindo
        // que o painel apareça por um instante durante refresh ou restauração.
        if (vortexIsSessionLocked(window.VORTEX_AUTH_CONTEXT)) vortexShowLockScreen(true);
        document.documentElement.style.visibility = '';
      });
    })
    .catch(redirectToLogin);
}

// Mantém o bloqueio sincronizado entre abas abertas no mesmo dispositivo.
window.addEventListener('storage', function(event) {
  if (event.key !== VORTEX_SESSION_LOCK_KEY) return;
  if (vortexIsSessionLocked(window.VORTEX_AUTH_CONTEXT)) {
    vortexShowLockScreen(true);
  } else {
    try { sessionStorage.removeItem(VORTEX_SESSION_LOCK_KEY); } catch (error) {}
    const overlay = document.getElementById('vortexLockOverlay');
    if (overlay) {
      overlay.remove();
      window.location.reload();
    }
  }
});

// O bfcache restaura a página sem executar novamente todos os scripts.
// Por isso, revalida a sessão e o marcador antes de mostrar o conteúdo.
window.addEventListener('pageshow', async function(event) {
  if (!event.persisted) return;
  if (!vortexIsSessionLocked()) return;

  document.documentElement.style.visibility = 'hidden';
  try {
    const context = await vortexGetCurrentStoreContext();
    if (context && !context.error && context.store) {
      if (vortexIsSessionLocked(window.VORTEX_AUTH_CONTEXT)) {
        vortexShowLockScreen(true);
      } else {
        // A conta/loja validada não possui bloqueio ativo.
        document.documentElement.style.visibility = '';
      }
    } else {
      // Não apaga o marcador quando não foi possível validar a sessão.
      // Mantém a página bloqueada até uma validação confiável.
      vortexShowLockScreen(true);
    }
  } catch (error) {
    console.error('Não foi possível restaurar a tela bloqueada:', error);
    vortexShowLockScreen(true);
  } finally {
    document.documentElement.style.visibility = '';
  }
});

// Identidade central do estabelecimento: o mesmo nome é aplicado em todos os módulos.
let vortexSidebarCanonicalStoreName = '';
let vortexSidebarNameObserver = null;

function vortexSetSidebarStoreName(name) {
  const normalized = String(name || '').trim() || 'MEU ESTABELECIMENTO';
  vortexSidebarCanonicalStoreName = normalized;
  document.querySelectorAll('#sidebarStoreName').forEach(element => {
    if (element.textContent !== normalized) element.textContent = normalized;
  });
  return normalized;
}

async function vortexRefreshSidebarStoreName() {
  if (!document.getElementById('sidebarStoreName')) return;
  let localSettings = {};
  try { localSettings = JSON.parse(localStorage.getItem('vortex_store_settings') || '{}') || {}; } catch (error) {}

  let cloudSettings = null;
  let relationalSettings = null;
  try {
    await vortexGetCurrentStoreId();
    cloudSettings = await dbFetchStoreDocument('settings');
    relationalSettings = await dbFetchStoreSettings();
  } catch (error) {
    console.warn('Não foi possível atualizar o nome do estabelecimento pela nuvem:', error);
  }

  const savedName = cloudSettings && (cloudSettings.storeName || cloudSettings.store_name || cloudSettings.nome)
    || relationalSettings && relationalSettings.store_name
    || localSettings.storeName || localSettings.store_name || localSettings.nome;
  const normalized = vortexSetSidebarStoreName(savedName);

  try {
    localSettings.storeName = normalized;
    localStorage.setItem('vortex_store_settings', JSON.stringify(localSettings));
  } catch (error) {}

  const element = document.getElementById('sidebarStoreName');
  if (element && !vortexSidebarNameObserver && typeof MutationObserver !== 'undefined') {
    vortexSidebarNameObserver = new MutationObserver(() => {
      if (vortexSidebarCanonicalStoreName && element.textContent !== vortexSidebarCanonicalStoreName) {
        element.textContent = vortexSidebarCanonicalStoreName;
      }
    });
    vortexSidebarNameObserver.observe(element, { childList: true, characterData: true, subtree: true });
  }
}

// Aguarda o carregamento da tela e corrige nomes locais antigos ou desatualizados.
window.addEventListener('load', function() {
  setTimeout(function() { vortexRefreshSidebarStoreName(); }, 400);
});

// Ativa a verificação somente nas páginas internas listadas acima.
// Login, landing page e páginas públicas de clientes permanecem abertas.
vortexRequireAuthenticatedPage();
