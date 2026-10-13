const express = require('express');
const cors = require('cors');
const { createClient } = require('@supabase/supabase-js');

const app = express();
app.use(express.json());
app.use(cors()); // Libera o acesso para testarmos de qualquer lugar

const SUPABASE_URL = process.env.SUPABASE_URL || 'https://sjwddjcsrtudbvqnmhyd.supabase.co';
const SUPABASE_KEY = process.env.SUPABASE_KEY || 'sb_publishable_ZKX9qmvzwEBsfKjfMHsHdQ_edDGBtMv';

const supabase = createClient(SUPABASE_URL, SUPABASE_KEY);

app.get('/', (req, res) => {
  res.send('API do Vortex Food está online e a funcionar!');
});

app.post('/restaurants', async (req, res) => {
  const restaurantName = req.body.name || 'Hamburgueria Vortex';
  const { data, error } = await supabase.from('restaurants').insert([{ name: restaurantName }]);
  if (error) return res.status(500).json({ success: false, error: error.message });
  return res.status(201).json({ success: true, message: 'Restaurante cadastrado com sucesso!', data });
});

app.post('/products', async (req, res) => {
  const { restaurant_id, name, price, description } = req.body;
  if (!name || !price) {
    return res.status(400).json({ success: false, error: 'Nome e preço são obrigatórios!' });
  }
  const { data, error } = await supabase.from('products').insert([{ restaurant_id: restaurant_id || null, name, price, description }]);
  if (error) return res.status(500).json({ success: false, error: error.message });
  return res.status(201).json({ success: true, message: 'Produto cadastrado com sucesso!', data });
});

app.get('/products', async (req, res) => {
  const { data, error } = await supabase.from('products').select('*');
  if (error) return res.status(500).json({ success: false, error: error.message });
  return res.status(200).json({ success: true, products: data });
});

const PORT = process.env.PORT || 3000;
app.listen(PORT, () => {
  console.log(`Servidor a correr na porta ${PORT}`);
});
