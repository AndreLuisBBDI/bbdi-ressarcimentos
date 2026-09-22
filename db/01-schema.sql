-- =====================================================================
-- Ressarcimento de Transportadoras — schema inicial (Supabase)
-- Rodar no SQL Editor do projeto novo, de uma vez.
-- Idempotente: pode rodar de novo sem quebrar.
-- =====================================================================

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------
-- 1. Pessoas — liga auth.users ao nome/setor que o app já usa
--    O 'slug' é o id que o código de hoje conhece ('andre-luis', 'emilly'...)
-- ---------------------------------------------------------------------
-- A chave é o slug, não o uuid do auth. Duas razões:
--  a) o solicitante do formulário pode ser gente que nunca faz login;
--  b) quem sai da equipe continua existindo no histórico, só perde o acesso.
-- 'auth_id' nulo = pessoa cadastrada sem conta. Nunca entra.
create table if not exists public.ressarc_usuarios (
  slug       text primary key,
  auth_id    uuid unique references auth.users(id) on delete set null,
  nome       text not null,
  email      text,
  telefone   text,
  setor      text not null check (setor in ('LOG','SAC','FIN')),
  admin      boolean not null default false,
  ativo      boolean not null default true,
  criado_em  timestamptz not null default now()
);

-- Convites: o cadastro que espera a conta nascer. Quando o e-mail aparece em
-- auth.users, o trigger lá embaixo copia nome/setor/admin para ressarc_usuarios.
-- Sem isso, o primeiro admin seria impossível: a política de INSERT exige um
-- admin que ainda não existe.
create table if not exists public.ressarc_convites (
  email    text primary key,
  slug     text unique not null,
  nome     text not null,
  telefone text,
  setor    text not null check (setor in ('LOG','SAC','FIN')),
  admin    boolean not null default false
);

-- Funções SECURITY DEFINER: uma política que lê ressarc_usuarios não pode
-- passar pela RLS da própria tabela, senão recursiona.
create or replace function public.ressarc_meu_setor() returns text
  language sql stable security definer set search_path = public as $$
  select setor from public.ressarc_usuarios where auth_id = auth.uid() and ativo
$$;

create or replace function public.ressarc_meu_slug() returns text
  language sql stable security definer set search_path = public as $$
  select slug from public.ressarc_usuarios where auth_id = auth.uid() and ativo
$$;

create or replace function public.ressarc_sou_admin() returns boolean
  language sql stable security definer set search_path = public as $$
  select coalesce((select admin from public.ressarc_usuarios
                   where auth_id = auth.uid() and ativo), false)
$$;

create or replace function public.ressarc_sou_ativo() returns boolean
  language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.ressarc_usuarios
                 where auth_id = auth.uid() and ativo)
$$;

-- Conta criada no painel do Auth -> vira usuário do app sozinho.
-- Se o e-mail não estiver convidado, a conta nasce sem acesso a nada:
-- ressarc_sou_ativo() devolve false e toda política nega.
create or replace function public.ressarc_provisionar() returns trigger
  language plpgsql security definer set search_path = public as $$
declare c public.ressarc_convites;
begin
  select * into c from public.ressarc_convites where lower(email) = lower(new.email);
  if found then
    insert into public.ressarc_usuarios (slug, auth_id, nome, email, telefone, setor, admin, ativo)
    values (c.slug, new.id, c.nome, new.email, c.telefone, c.setor, c.admin, true)
    on conflict (slug) do update
      set auth_id = excluded.auth_id, email = excluded.email, ativo = true;
  end if;
  return new;
end $$;

drop trigger if exists tg_auth_provisionar on auth.users;
create trigger tg_auth_provisionar after insert on auth.users
  for each row execute function public.ressarc_provisionar();

-- ---------------------------------------------------------------------
-- 2. Formulários
--    Colunas reais para o que o dashboard filtra e agrega; o resto
--    (itens[], observacoes, anexos[], assinaturaId, revisoes[], arquivoPdf)
--    fica em 'dados', que é exatamente o objeto que o app já manipula.
-- ---------------------------------------------------------------------
create table if not exists public.ressarc_forms (
  id                 uuid primary key,
  numero             text unique not null,
  transportadora_id  text not null,
  transportadora     text not null,
  cnpj               text,
  solicitante_id     text not null,
  solicitante        text not null,
  setor              text,
  filial             text not null,
  status             text not null check (status in ('Aberto','Finalizado','Cancelado')),
  total              numeric(14,2) not null default 0,
  criado_em          timestamptz not null default now(),
  finalizado_em      timestamptz,
  cancelado_em       timestamptz,
  reconciliacao      text,
  reconciliacao_nota text,
  hash               text,
  excluido           boolean not null default false,
  autor              uuid not null default auth.uid() references auth.users(id),
  dados              jsonb not null default '{}'::jsonb,
  atualizado_em      timestamptz not null default now()
);

create index if not exists ix_forms_transportadora on public.ressarc_forms (transportadora_id);
create index if not exists ix_forms_criado        on public.ressarc_forms (criado_em desc);
create index if not exists ix_forms_status        on public.ressarc_forms (status);
create index if not exists ix_forms_filial        on public.ressarc_forms (filial);
create index if not exists ix_forms_solicitante   on public.ressarc_forms (solicitante_id);

-- ---------------------------------------------------------------------
-- 3. Logs de auditoria — append-only de verdade (ver GRANTs no fim)
-- ---------------------------------------------------------------------
create table if not exists public.ressarc_logs (
  id                uuid primary key,
  at                timestamptz not null default now(),
  evento            text not null,
  evento_label      text,
  operador          text,
  operador_setor    text,
  solicitante       text,
  form_id           uuid,
  form_numero       text,
  transportadora_id text,
  transportadora    text,
  filial            text,
  status            text,
  total             numeric(14,2),
  nfs               jsonb,
  detalhe           text,
  autor             uuid not null default auth.uid()
);

create index if not exists ix_logs_at    on public.ressarc_logs (at desc);
create index if not exists ix_logs_form  on public.ressarc_logs (form_id);
create index if not exists ix_logs_event on public.ressarc_logs (evento);

-- ---------------------------------------------------------------------
-- 4. Configurações — linha única, compartilhada pela equipe
-- ---------------------------------------------------------------------
create table if not exists public.ressarc_settings (
  id             int primary key default 1 check (id = 1),
  dados          jsonb not null default '{}'::jsonb,
  atualizado_em  timestamptz not null default now(),
  atualizado_por uuid
);
insert into public.ressarc_settings (id, dados) values (1, '{}'::jsonb)
  on conflict (id) do nothing;

-- ---------------------------------------------------------------------
-- 5. Numeração RES-AAAA-0001 — atribuída pelo servidor.
--    Sem isso, dois usuários simultâneos tiram o mesmo número.
-- ---------------------------------------------------------------------
create table if not exists public.ressarc_sequences (
  ano   int primary key,
  valor int not null default 0
);

create or replace function public.ressarc_proximo_numero(p_ano int)
  returns int language plpgsql security definer set search_path = public as $$
declare v int;
begin
  if not public.ressarc_sou_ativo() then
    raise exception 'usuario sem acesso';
  end if;
  -- em ON CONFLICT a linha existente é referenciada sem o schema
  insert into public.ressarc_sequences (ano, valor) values (p_ano, 1)
    on conflict (ano) do update set valor = ressarc_sequences.valor + 1
    returning valor into v;
  return v;
end $$;

-- ---------------------------------------------------------------------
-- 6. Rascunhos e preferências — privados de cada pessoa
-- ---------------------------------------------------------------------
create table if not exists public.ressarc_drafts (
  usuario           uuid not null default auth.uid() references auth.users(id) on delete cascade,
  transportadora_id text not null,
  dados             jsonb not null,
  atualizado_em     timestamptz not null default now(),
  primary key (usuario, transportadora_id)
);

create table if not exists public.ressarc_prefs (
  usuario       uuid primary key default auth.uid() references auth.users(id) on delete cascade,
  dados         jsonb not null default '{}'::jsonb,
  atualizado_em timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- 7. Presença — quem está online de verdade (substitui os simulados)
-- ---------------------------------------------------------------------
create table if not exists public.ressarc_presence (
  usuario   uuid primary key default auth.uid() references auth.users(id) on delete cascade,
  slug      text,
  nome      text,
  setor     text,
  visto_em  timestamptz not null default now()
);
alter table public.ressarc_presence add column if not exists slug text;

-- ---------------------------------------------------------------------
-- 8. Anexos e assinaturas — metadados aqui, binário no Storage
-- ---------------------------------------------------------------------
create table if not exists public.ressarc_anexos (
  id        uuid primary key,
  form_id   uuid,
  nome      text not null,
  tipo      text,
  tamanho   bigint,
  caminho   text not null,          -- chave dentro do bucket
  kind      text not null default 'anexo' check (kind in ('anexo','assinatura')),
  autor     uuid not null default auth.uid(),
  criado_em timestamptz not null default now()
);
create index if not exists ix_anexos_form on public.ressarc_anexos (form_id);

-- ---------------------------------------------------------------------
-- 9. atualizado_em automático
-- ---------------------------------------------------------------------
create or replace function public.ressarc_touch() returns trigger
  language plpgsql as $$
begin new.atualizado_em = now(); return new; end $$;

-- Autor carimbado pelo servidor, nunca aceito do cliente.
-- Isso é o que permite o upsert funcionar: se a política de INSERT exigisse
-- autor = auth.uid(), reconciliar o formulário de outra pessoa seria negado,
-- porque o upsert do PostgREST precisa passar pelo WITH CHECK do INSERT.
create or replace function public.ressarc_set_autor() returns trigger
  language plpgsql as $$
begin
  if (tg_op = 'INSERT') then new.autor = auth.uid();
  else new.autor = old.autor; end if;
  return new;
end $$;

drop trigger if exists tg_forms_autor on public.ressarc_forms;
create trigger tg_forms_autor before insert or update on public.ressarc_forms
  for each row execute function public.ressarc_set_autor();

drop trigger if exists tg_logs_autor on public.ressarc_logs;
create trigger tg_logs_autor before insert on public.ressarc_logs
  for each row execute function public.ressarc_set_autor();

drop trigger if exists tg_anexos_autor on public.ressarc_anexos;
create trigger tg_anexos_autor before insert on public.ressarc_anexos
  for each row execute function public.ressarc_set_autor();

drop trigger if exists tg_forms_touch on public.ressarc_forms;
create trigger tg_forms_touch before update on public.ressarc_forms
  for each row execute function public.ressarc_touch();

drop trigger if exists tg_drafts_touch on public.ressarc_drafts;
create trigger tg_drafts_touch before update on public.ressarc_drafts
  for each row execute function public.ressarc_touch();

-- =====================================================================
-- 10. RLS
-- =====================================================================
alter table public.ressarc_usuarios  enable row level security;
alter table public.ressarc_convites  enable row level security;
alter table public.ressarc_forms     enable row level security;
alter table public.ressarc_logs      enable row level security;
alter table public.ressarc_settings  enable row level security;
alter table public.ressarc_sequences enable row level security;
alter table public.ressarc_drafts    enable row level security;
alter table public.ressarc_prefs     enable row level security;
alter table public.ressarc_presence  enable row level security;
alter table public.ressarc_anexos    enable row level security;

-- Pessoas: todo mundo ativo enxerga a equipe; só admin mexe no cadastro
drop policy if exists p_usuarios_sel on public.ressarc_usuarios;
create policy p_usuarios_sel on public.ressarc_usuarios for select
  to authenticated using (public.ressarc_sou_ativo());
drop policy if exists p_usuarios_ins on public.ressarc_usuarios;
create policy p_usuarios_ins on public.ressarc_usuarios for insert
  to authenticated with check (public.ressarc_sou_admin());
drop policy if exists p_usuarios_upd on public.ressarc_usuarios;
create policy p_usuarios_upd on public.ressarc_usuarios for update
  to authenticated using (public.ressarc_sou_admin()) with check (public.ressarc_sou_admin());

-- Convites: só o admin. Ninguém mais precisa ver telefone de colega.
drop policy if exists p_convites_all on public.ressarc_convites;
create policy p_convites_all on public.ressarc_convites for all
  to authenticated using (public.ressarc_sou_admin()) with check (public.ressarc_sou_admin());

-- Formulários: a equipe lê tudo (dashboard é coletivo); escreve autenticado e ativo.
-- Sem DELETE: cancelamento é soft delete, nada some.
drop policy if exists p_forms_sel on public.ressarc_forms;
create policy p_forms_sel on public.ressarc_forms for select
  to authenticated using (public.ressarc_sou_ativo());
drop policy if exists p_forms_ins on public.ressarc_forms;
create policy p_forms_ins on public.ressarc_forms for insert
  to authenticated with check (public.ressarc_sou_ativo());
drop policy if exists p_forms_upd on public.ressarc_forms;
create policy p_forms_upd on public.ressarc_forms for update
  to authenticated using (public.ressarc_sou_ativo()) with check (public.ressarc_sou_ativo());

-- Logs: lê e insere; UPDATE/DELETE nem existem como GRANT (ver abaixo)
drop policy if exists p_logs_sel on public.ressarc_logs;
create policy p_logs_sel on public.ressarc_logs for select
  to authenticated using (public.ressarc_sou_ativo());
drop policy if exists p_logs_ins on public.ressarc_logs;
create policy p_logs_ins on public.ressarc_logs for insert
  to authenticated with check (public.ressarc_sou_ativo());

-- Configurações: todos leem (o app precisa delas para desenhar a tela), só admin grava
drop policy if exists p_settings_sel on public.ressarc_settings;
create policy p_settings_sel on public.ressarc_settings for select
  to authenticated using (public.ressarc_sou_ativo());
drop policy if exists p_settings_upd on public.ressarc_settings;
create policy p_settings_upd on public.ressarc_settings for update
  to authenticated using (public.ressarc_sou_admin()) with check (public.ressarc_sou_admin());

-- Sequências: ninguém toca direto; só a função SECURITY DEFINER
drop policy if exists p_sequences_sel on public.ressarc_sequences;
create policy p_sequences_sel on public.ressarc_sequences for select
  to authenticated using (public.ressarc_sou_ativo());

-- Rascunho e preferência são de quem escreveu
drop policy if exists p_drafts_all on public.ressarc_drafts;
create policy p_drafts_all on public.ressarc_drafts for all
  to authenticated using (usuario = auth.uid()) with check (usuario = auth.uid());
drop policy if exists p_prefs_all on public.ressarc_prefs;
create policy p_prefs_all on public.ressarc_prefs for all
  to authenticated using (usuario = auth.uid()) with check (usuario = auth.uid());

-- Presença: todos veem quem está online, cada um só escreve a própria linha
drop policy if exists p_presence_sel on public.ressarc_presence;
create policy p_presence_sel on public.ressarc_presence for select
  to authenticated using (public.ressarc_sou_ativo());
drop policy if exists p_presence_all on public.ressarc_presence;
create policy p_presence_all on public.ressarc_presence for all
  to authenticated using (usuario = auth.uid()) with check (usuario = auth.uid());

-- Anexos (metadados)
drop policy if exists p_anexos_sel on public.ressarc_anexos;
create policy p_anexos_sel on public.ressarc_anexos for select
  to authenticated using (public.ressarc_sou_ativo());
drop policy if exists p_anexos_ins on public.ressarc_anexos;
create policy p_anexos_ins on public.ressarc_anexos for insert
  to authenticated with check (public.ressarc_sou_ativo());
drop policy if exists p_anexos_del on public.ressarc_anexos;
create policy p_anexos_del on public.ressarc_anexos for delete
  to authenticated using (autor = auth.uid() or public.ressarc_sou_admin());

-- =====================================================================
-- 11. GRANTs — a trava que a política não dá.
--     anon não toca em nada: o site é público, a base não é.
-- =====================================================================
revoke all on all tables    in schema public from anon;
revoke all on all functions in schema public from anon;
revoke all on all sequences in schema public from anon;
-- e nas tabelas que vierem depois, senão a próxima nasce aberta para anon
alter default privileges in schema public revoke all on tables    from anon;
alter default privileges in schema public revoke all on functions from anon;
alter default privileges in schema public revoke all on sequences from anon;

-- ---------------------------------------------------------------------
-- authenticated também começa do zero. Isto NÃO é redundante com os
-- grants abaixo: o Supabase já concede ALL a authenticated em toda tabela
-- criada no schema public, e GRANT só soma — nunca tira. Sem este revoke,
-- "grant select, insert" em ressarc_logs não impede um UPDATE: quem segura
-- é a RLS, e a RLS segura CALADA (update sem política afeta 0 linhas e não
-- levanta erro). Com o revoke, a mesma tentativa morre com 42501.
-- Tabela a tabela, de propósito: "all tables in schema public" pegaria
-- também o que não é deste app.
-- ---------------------------------------------------------------------
revoke all on public.ressarc_usuarios, public.ressarc_convites,
              public.ressarc_forms,    public.ressarc_logs,
              public.ressarc_settings, public.ressarc_sequences,
              public.ressarc_drafts,   public.ressarc_prefs,
              public.ressarc_presence, public.ressarc_anexos
  from authenticated;
alter default privileges in schema public revoke all on tables from authenticated;

grant select, insert, update on public.ressarc_forms    to authenticated;
grant select, insert         on public.ressarc_logs     to authenticated;  -- append-only
grant select, insert, update on public.ressarc_usuarios to authenticated;
grant select, update         on public.ressarc_settings to authenticated;
grant select                 on public.ressarc_sequences to authenticated;
grant select, insert, update, delete on public.ressarc_drafts   to authenticated;
grant select, insert, update, delete on public.ressarc_prefs    to authenticated;
grant select, insert, update, delete on public.ressarc_presence to authenticated;
grant select, insert, delete on public.ressarc_anexos   to authenticated;
grant execute on function public.ressarc_proximo_numero(int) to authenticated;
grant select, insert, update, delete on public.ressarc_convites to authenticated;
grant execute on function public.ressarc_meu_setor()  to authenticated;
grant execute on function public.ressarc_meu_slug()   to authenticated;
grant execute on function public.ressarc_sou_admin()  to authenticated;
grant execute on function public.ressarc_sou_ativo()  to authenticated;

-- =====================================================================
-- 12. Storage — bucket privado para anexos e assinaturas
-- =====================================================================
insert into storage.buckets (id, name, public) values ('ressarc-anexos','ressarc-anexos', false)
  on conflict (id) do nothing;

drop policy if exists p_bucket_sel on storage.objects;
create policy p_bucket_sel on storage.objects for select
  to authenticated using (bucket_id = 'ressarc-anexos' and public.ressarc_sou_ativo());

drop policy if exists p_bucket_ins on storage.objects;
create policy p_bucket_ins on storage.objects for insert
  to authenticated with check (bucket_id = 'ressarc-anexos' and public.ressarc_sou_ativo());

drop policy if exists p_bucket_del on storage.objects;
create policy p_bucket_del on storage.objects for delete
  to authenticated using (bucket_id = 'ressarc-anexos'
    and (owner = auth.uid() or public.ressarc_sou_admin()));
