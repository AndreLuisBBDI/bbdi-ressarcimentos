-- =====================================================================
-- Configurações: só o administrador. (22/09/2026)
--
-- O banco já estava certo — p_settings_upd exige ressarc_sou_admin(),
-- p_usuarios_ins/upd idem, p_convites_all idem. O que estava aberto era
-- a TELA: a aba aparecia para todo mundo e o portão pedia um PIN que
-- qualquer usuário ativo conseguia ler no próprio jsonb.
--
-- Aqui só resta tirar o PIN de dentro da base compartilhada. Ele não
-- guarda mais nada na nuvem (quem manda é a coluna admin) e continua
-- valendo no modo local, onde vem do padrão do próprio HTML.
--
-- Idempotente. Rodar inteiro; o último SELECT é a conferência.
-- =====================================================================

update public.ressarc_settings
   set dados = dados - 'adminPin'
 where id = 1 and dados ? 'adminPin';

-- ---------------------------------------------------------------------
-- Conferência: em cima quem manda em cada tabela da área de configuração,
-- no meio quem é admin, embaixo se o PIN saiu mesmo do jsonb.
-- ---------------------------------------------------------------------
select 'politica' as tipo,
       tablename || ' ' || cmd as item,
       coalesce(qual, with_check, '-') as regra
  from pg_policies
 where schemaname = 'public'
   and tablename in ('ressarc_settings', 'ressarc_usuarios', 'ressarc_convites')
union all
select 'admin', u.nome || ' (' || u.setor || ')', u.email
  from public.ressarc_usuarios u where u.admin and u.ativo
union all
select 'PIN no jsonb',
       case when (select dados ? 'adminPin' from public.ressarc_settings where id = 1)
            then 'AINDA ESTA LA' else 'removido' end,
       '-'
 order by 1, 2;
