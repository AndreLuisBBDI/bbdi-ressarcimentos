-- =====================================================================
-- Ressarcimento — liga o tempo real na presença.
-- Sem isto o WebSocket conecta, o cliente assina e nenhum evento chega:
-- o Postgres só publica o que está na publicação supabase_realtime.
-- Idempotente.
-- =====================================================================

do $$
begin
  if not exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    execute 'create publication supabase_realtime';
  end if;

  if not exists (select 1 from pg_publication_tables
                  where pubname = 'supabase_realtime'
                    and schemaname = 'public'
                    and tablename  = 'ressarc_presence') then
    execute 'alter publication supabase_realtime add table public.ressarc_presence';
  end if;
  -- NÃO ponha esta tabela em replica identity full. Testado em 22/09/2026:
  -- com full, o Realtime passa a avaliar a RLS linha a linha e cada pessoa
  -- só recebe o evento da própria linha — ninguém vê ninguém entrar. Com a
  -- identidade default os eventos de todos chegam em ~1,5 s. O preço é que
  -- o DELETE não é publicado, e por isso o cliente sai por UPDATE
  -- (visto_em jogado para trás) em vez de apagar a linha.
  execute 'alter table public.ressarc_presence replica identity default';
end $$;

-- A política p_presence_sel (ressarc_sou_ativo()) vale também para o
-- Realtime: cada assinante só recebe o evento da linha que ele poderia
-- ler por SELECT. Quem não está ativo não enxerga ninguém.

select tablename as tabela_publicada
  from pg_publication_tables
 where pubname = 'supabase_realtime' and schemaname = 'public'
 order by 1;
