-- =====================================================================
-- Teste do tempo real da presença — para rodar com o site ABERTO e
-- LOGADO numa aba, olhando a bolinha verde do canto superior direito.
-- Roda como postgres (o SQL Editor ignora RLS), então simula o colega.
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
-- (rodar depois, selecionando só estas duas linhas)
-- delete from public.ressarc_presence p using public.ressarc_usuarios u
--  where p.usuario = u.auth_id and lower(u.email) <> lower('estoque@bbdi.com.br');
