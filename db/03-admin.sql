-- =====================================================================
-- Ressarcimento — garante o ADMIN e reconcilia quem já tem conta.
-- Rodar no SQL Editor depois de criar as contas em Authentication > Users.
-- Idempotente: pode rodar quantas vezes quiser, não duplica nem apaga nada.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Reconcilia conta x convite.
--    O trigger tg_auth_provisionar já faz isso no instante em que a conta
--    nasce. Este passo cobre o que o trigger não pega: conta criada antes
--    do trigger existir, e-mail digitado com maiúscula, ou convite editado
--    depois que a conta já estava lá.
-- ---------------------------------------------------------------------
insert into public.ressarc_usuarios (slug, auth_id, nome, email, telefone, setor, admin, ativo)
select c.slug, a.id, c.nome, a.email, c.telefone, c.setor, c.admin, true
  from public.ressarc_convites c
  join auth.users a on lower(a.email) = lower(c.email)
on conflict (slug) do update set
  auth_id  = excluded.auth_id,
  email    = excluded.email,
  nome     = excluded.nome,
  telefone = excluded.telefone,
  setor    = excluded.setor,
  admin    = excluded.admin,
  ativo    = true;

-- ---------------------------------------------------------------------
-- 2. O admin, dito com todas as letras.
-- ---------------------------------------------------------------------
update public.ressarc_usuarios u
   set admin = true, ativo = true
  from auth.users a
 where u.auth_id = a.id
   and lower(a.email) = lower('estoque@bbdi.com.br');

-- ---------------------------------------------------------------------
-- 3. O quadro inteiro numa tela só (o SQL Editor mostra só o último
--    resultado). Em cima: conta que existe. Embaixo: convite sem conta.
--    "CONTA SEM CONVITE" = e-mail da conta não bate com nenhum convite;
--    essa pessoa entra no site e não enxerga nada.
-- ---------------------------------------------------------------------
select a.email,
       coalesce(u.nome,  c.nome,  '(sem cadastro)') as nome,
       coalesce(u.slug,  c.slug,  '-')              as slug,
       coalesce(u.setor, c.setor, '-')              as setor,
       coalesce(u.admin, false)                     as admin,
       case when u.slug is null then 'CONTA SEM CONVITE - confira o e-mail'
            when u.admin        then '>>> ADMIN <<<'
            else 'ok' end                           as situacao
  from auth.users a
  left join public.ressarc_usuarios u on u.auth_id = a.id
  left join public.ressarc_convites c on lower(c.email) = lower(a.email)
union all
select c.email, c.nome, c.slug, c.setor, c.admin, 'FALTA CRIAR A CONTA'
  from public.ressarc_convites c
 where not exists (select 1 from auth.users a where lower(a.email) = lower(c.email))
 order by 6, 1;
