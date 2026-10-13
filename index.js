const express = require('express');
const { createClient } = require('@supabase/supabase-js');

const app = express();
app.use(express.json()); // Permite ler dados em formato JSON

const SUPABASE_URL = process.env.SUPABASE_URL || 'https://sjwddjcsrtudbvqnmhyd.supabase.co';
const SUPABASE_KEY = process.env.SUPABASE_KEY || 'sb_publishable_ZKX9qmvzwEBsfKjfMHsHdQ_edDGBtMv';

const supabase = createClient(SUPABASE_URL, SUPABASE_KEY);

// Rota de teste para ver se a API está online
app.get('/', (req, res) => {
  res.send('API do Vortex Food está online e a funcionar!');
});

// Rota para cadastrar um restaurante via requisição
app.post('/restaurants', async (req, res) => {
  const restaurantName = req.body.name || 'Hamburgueria Vortex';

  const { data, error } = await supabase
    .from('restaurants')
    .insert([{ name: restaurantName }]);

  if (error) {
    return res.status(500).json({ success: false, error: error.message });
  }

  return res.status(201).json({ success: true, message: 'Restaurante cadastrado com sucesso!', data });
});

// Porta onde o servidor vai escutar (o Render define isto automaticamente)
const PORT = process.env.PORT || 3000;
app.listen(PORT, () => {
  console.log(`Servidor do Vortex Food a correr na porta ${PORT}`);
});
