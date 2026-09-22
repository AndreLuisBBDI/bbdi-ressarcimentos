-- =====================================================================
-- Ressarcimento de Transportadoras — equipe
-- Rodar DEPOIS do 01-schema.sql, no SQL Editor (roda como postgres, sem RLS).
-- Idempotente: pode rodar de novo, atualiza quem já existe.
-- =====================================================================
--
-- COMO FUNCIONA
--   1. Este script grava os CONVITES (e-mail -> nome, setor, admin).
--   2. Você cria a conta de cada um em Authentication > Users > Add user.
--   3. O trigger tg_auth_provisionar copia o convite para ressarc_usuarios
--      no instante em que a conta nasce. Nada de copiar UUID à mão.
--   E-mail que não estiver nesta lista cria conta mas não enxerga nada.
--
-- SETOR: todos os e-mails novos são financeiroN@, então foram cadastrados
--   como FIN — inclusive Júlia e Igor, que não estavam no app antes.
--   Trocar é um UPDATE numa linha; ver o rodapé.
-- =====================================================================

insert into public.ressarc_convites (email, slug, nome, telefone, setor, admin) values
  ('estoque@bbdi.com.br',            'andre-luis', 'André Luís',                  null,            'LOG', true ),
  ('financeiro7.bbdi@gmail.com',     'mariana',    'Mariana Gautério',            '51 99116-3800', 'FIN', false),
  ('financeiro1@bbdi.com.br',        'marcelo',    'Marcelo Vicente de Siqueira', '51 99392-3221', 'FIN', false),
  ('financeiro13@bbdi.com.br',       'luana',      'Luana Nogueira Rontani',      '51 99264-3917', 'FIN', false),
  ('financeiro4.bbdi@gmail.com',     'julia',      'Júlia de Almeida Lodi',       '51 99373-9343', 'FIN', false),
  ('financeiro12.bbdi@gmail.com',    'igor',       'Igor Ferreira Santos',        '51 99453-6898', 'FIN', false)
on conflict (email) do update set
  slug     = excluded.slug,
  nome     = excluded.nome,
  telefone = excluded.telefone,
  setor    = excluded.setor,
  admin    = excluded.admin;

-- ---------------------------------------------------------------------
-- Quem saiu da lista: fica cadastrado, sem conta e sem acesso (auth_id nulo).
-- Serve para o histórico não ficar com "solicitante: emilly" órfão.
-- Para trazer alguém de volta: inserir o e-mail em ressarc_convites e
-- criar a conta — o trigger religa o auth_id e marca ativo = true.
-- ---------------------------------------------------------------------
insert into public.ressarc_usuarios (slug, nome, setor, admin, ativo) values
  ('emilly',     'Emilly',     'SAC', false, false),
  ('luciane',    'Luciane',    'SAC', false, false),
  ('herivelton', 'Herivelton', 'FIN', false, false)
on conflict (slug) do nothing;

-- ---------------------------------------------------------------------
-- Confere o que ficou. O SQL Editor só mostra o último resultado.
-- ---------------------------------------------------------------------
select c.slug, c.nome, c.setor, c.admin, c.email,
       case when u.auth_id is null then 'falta criar a conta' else 'conta criada' end as conta
  from public.ressarc_convites c
  left join public.ressarc_usuarios u on u.slug = c.slug
 order by c.admin desc, c.nome;

-- =====================================================================
-- Depois, se precisar:
--   update public.ressarc_convites set setor = 'SAC' where slug = 'julia';
--   update public.ressarc_usuarios set setor = 'SAC' where slug = 'julia';
--   update public.ressarc_usuarios set ativo = false where slug = 'fulano';
-- =====================================================================
