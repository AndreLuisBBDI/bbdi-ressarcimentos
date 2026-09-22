-- =====================================================================
-- Teste do tempo real da presença — para rodar com o site ABERTO e
-- LOGADO numa aba, olhando a bolinha verde do canto superior direito.
-- Roda como postgres (o SQL Editor ignora RLS), então simula o colega.
--
-- Rodar um PASSO de cada vez, selecionando as linhas do passo antes de
-- clicar Run. Medido em 22/09/2026: o evento chega ao navegador em
-- 1,2 s a 1,6 s.
-- =====================================================================

-- PASSO 1 — coloca um colega online. A contagem tem que subir na hora,
-- sem F5, e o nome dele tem que ficar verde na lista.
insert into public.ressarc_presence (usuario, slug, nome, setor, visto_em)
select u.auth_id, u.slug, u.nome, u.setor, now()
  from public.ressarc_usuarios u
 where u.auth_id is not null
   and u.ativo
   and lower(u.email) <> lower('estoque@bbdi.com.br')
 order by u.nome
 limit 1
on conflict (usuario) do update set visto_em = now();

select nome, setor, visto_em from public.ressarc_presence order by visto_em desc;

-- PASSO 2 — tira o colega. A contagem tem que cair na hora.
--
-- Sair é um UPDATE, não um DELETE. O Postgres NÃO publica o DELETE desta
-- tabela (replica identity default; ver 04-realtime.sql), então um delete
-- some do banco e o navegador do colega continua mostrando a pessoa
-- online até o TTL vencer. Empurrar o visto_em para trás é um UPDATE, é
-- publicado, e o cliente trata como saída. É exatamente o que o botão
-- "Sair" e o fechamento da aba fazem no site.
update public.ressarc_presence p
   set visto_em = now() - interval '1 hour'
  from public.ressarc_usuarios u
 where p.usuario = u.auth_id
   and lower(u.email) <> lower('estoque@bbdi.com.br');

-- PASSO 3 — limpeza. Só depois de terminar o teste: apaga a linha do
-- colega simulado. Some do banco sem avisar ninguém (ver acima), e é por
-- isso que este passo vem DEPOIS do PASSO 2, nunca no lugar dele.
delete from public.ressarc_presence p
 using public.ressarc_usuarios u
 where p.usuario = u.auth_id
   and lower(u.email) <> lower('estoque@bbdi.com.br');

select coalesce(nome, '(tabela vazia)') as ainda_na_tabela, visto_em
  from public.ressarc_presence
 order by visto_em desc;
