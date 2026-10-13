const { createClient } = require('@supabase/supabase-js');

const SUPABASE_URL = process.env.SUPABASE_URL || 'https://sjwddjcsrtudbvqnmhyd.supabase.co';
const SUPABASE_KEY = process.env.SUPABASE_KEY || 'sb_publishable_ZKX9qmvzwEBsfKjfMHsHdQ_edDGBtMv';

const supabase = createClient(SUPABASE_URL, SUPABASE_KEY);

async function cadastrarRestaurante() {
  console.log('Tentando cadastrar o restaurante no Supabase...');
  
  const { data, error } = await supabase
    .from('restaurants')
    .insert([
      { name: 'Hamburgueria Vortex' }
    ]);

  if (error) {
    console.error('Erro ao cadastrar:', error.message);
  } else {
    console.log('Restaurante cadastrado com sucesso!', data);
  }
}

cadastrarRestaurante();
                
