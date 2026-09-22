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
  -- DELETE em tabela com RLS só é publicado com a linha antiga inteira: o
  -- Realtime precisa dela para decidir se o assinante podia ver aquela linha.
  -- Com replica identity default (a PK) o evento é engolido em silêncio e
  -- quem sai do site só some 20 s depois, pelo TTL. Medido em 22/09/2026.
  execute 'alter table public.ressarc_presence replica identity full';
end $$;

-- A política p_presence_sel (ressarc_sou_ativo()) vale também para o
-- Realtime: cada assinante só recebe o evento da linha que ele poderia
-- ler por SELECT. Quem não está ativo não enxerga ninguém.

select tablename as tabela_publicada
  from pg_publication_tables
 where pubname = 'supabase_realtime' and schemaname = 'public'
 order by 1;
