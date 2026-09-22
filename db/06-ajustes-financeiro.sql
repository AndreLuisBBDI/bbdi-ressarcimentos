-- =====================================================================
-- Ajustes pedidos pelo Financeiro (Mariana) em 22/09/2026.
-- Idempotente: pode rodar quantas vezes quiser.
--
--   1. Total Express no cadastro de transportadoras
--   2. Nota fiscal duplicada barrada NO SERVIDOR (não só na tela)
--   3. Solicitar ressarcimento passa a ser do Financeiro; os demais
--      setores continuam enxergando tudo
--
-- Rodar inteiro de uma vez. O último SELECT é a conferência.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Total Express. O cadastro mora no jsonb de ressarc_settings, então
--    mexer só no HTML não bastava: a lista salva ganha prioridade.
-- ---------------------------------------------------------------------
update public.ressarc_settings
   set dados = jsonb_set(dados, '{transportadoras}',
        coalesce(dados->'transportadoras', '[]'::jsonb) || jsonb_build_object(
          'id', 'total-express', 'nome', 'Total Express', 'cnpj', '73.939.449/0001-93',
          'email', '', 'whatsapp', '', 'ativo', true))
 where id = 1
   and not exists (
     select 1 from jsonb_array_elements(coalesce(dados->'transportadoras', '[]'::jsonb)) t
      where t->>'id' = 'total-express');

-- ---------------------------------------------------------------------
-- 2. Nota fiscal já incluída.
--    As notas ficam dentro do jsonb (dados->itens), onde nenhum índice
--    único alcança. A saída é uma coluna text[] mantida por gatilho, com
--    índice GIN, e a checagem dentro do próprio gatilho.
--
--    A checagem só vale para formulário FINALIZADO: rascunho (Aberto) é
--    gravado a cada tecla e travar ali daria erro no meio da digitação.
--    Cancelado e excluído não ocupam a nota.
-- ---------------------------------------------------------------------
alter table public.ressarc_forms add column if not exists nfs text[] not null default '{}';

-- Preenche o que já existe ANTES de o gatilho passar a barrar, senão um
-- histórico com duplicata trava a própria migração.
update public.ressarc_forms f
   set nfs = coalesce((
     select array_agg(distinct nf)
       from (select btrim(x->>'nf') as nf
               from jsonb_array_elements(
                 case when jsonb_typeof(f.dados->'itens') = 'array' then f.dados->'itens' else '[]'::jsonb end) x) s
      where nf is not null and nf <> ''), '{}'::text[]);

create index if not exists ix_forms_nfs on public.ressarc_forms using gin (nfs);

create or replace function public.ressarc_forms_nfs() returns trigger
language plpgsql security definer set search_path = public as $fn$
declare v_conflito text;
begin
  new.nfs := coalesce((
    select array_agg(distinct nf)
      from (select btrim(x->>'nf') as nf
              from jsonb_array_elements(
                case when jsonb_typeof(new.dados->'itens') = 'array' then new.dados->'itens' else '[]'::jsonb end) x) s
     where nf is not null and nf <> ''), '{}'::text[]);

  if new.status <> 'Finalizado' or new.excluido or new.nfs = '{}'::text[] then
    return new;
  end if;

  -- Reconciliação e cancelamento são UPDATE e não mexem nas notas: deixar
  -- passar, senão um conflito antigo trava a operação do dia a dia.
  if tg_op = 'UPDATE' and old.nfs = new.nfs and old.status = new.status then
    return new;
  end if;

  if coalesce((select (dados->>'bloquearNfDuplicada')::boolean from public.ressarc_settings where id = 1), true) is not true then
    return new;
  end if;

  select string_agg(distinct f.numero, ', ') into v_conflito
    from public.ressarc_forms f
   where f.id <> new.id and not f.excluido and f.status = 'Finalizado' and f.nfs && new.nfs;

  if v_conflito is not null then
    raise exception 'Nota fiscal ja incluida no formulario %', v_conflito
      using errcode = 'unique_violation',
            hint    = 'Consulte a nota no campo de busca do formulario antes de incluir.';
  end if;
  return new;
end $fn$;

drop trigger if exists tg_forms_nfs on public.ressarc_forms;
create trigger tg_forms_nfs before insert or update on public.ressarc_forms
  for each row execute function public.ressarc_forms_nfs();

-- A chave que liga e desliga o bloqueio (a tela de Configurações edita a mesma).
update public.ressarc_settings
   set dados = dados || '{"bloquearNfDuplicada": true}'::jsonb
 where id = 1 and dados->'bloquearNfDuplicada' is null;

-- ---------------------------------------------------------------------
-- 3. Quem solicita ressarcimento.
--    LOG e SAC deixam de abrir e de cancelar formulário; continuam com
--    dashboard, logs e relatórios. Admin passa por cima (é quem edita a
--    matriz). Vale na tela E na política de INSERT — sem isto seria
--    enfeite: bastaria o F12 para furar.
-- ---------------------------------------------------------------------
update public.ressarc_settings
   set dados = jsonb_set(
         jsonb_set(dados, '{permissoes,LOG}',
           coalesce(dados->'permissoes'->'LOG', '{}'::jsonb) || '{"formularios": false, "cancelar": false}'::jsonb),
         '{permissoes,SAC}',
           coalesce(dados->'permissoes'->'SAC', '{}'::jsonb) || '{"formularios": false, "cancelar": false}'::jsonb)
 where id = 1;

create or replace function public.ressarc_pode_solicitar() returns boolean
language sql stable security definer set search_path = public as $fn$
  select public.ressarc_sou_admin()
      or coalesce((
           select (s.dados->'permissoes'->u.setor->>'formularios')::boolean
             from public.ressarc_usuarios u
             join public.ressarc_settings s on s.id = 1
            where u.auth_id = auth.uid() and u.ativo), true);
$fn$;

drop policy if exists p_forms_ins on public.ressarc_forms;
create policy p_forms_ins on public.ressarc_forms for insert
  to authenticated with check (public.ressarc_sou_ativo() and public.ressarc_pode_solicitar());

-- ---------------------------------------------------------------------
-- 4. Conferência. Em cima o que ficou valendo; embaixo a nota fiscal que
--    já estava repetida ANTES desta migração (o gatilho não apaga nada,
--    só impede daqui para a frente).
-- ---------------------------------------------------------------------
select 'transportadora Total Express' as item,
       (select count(*)::text from jsonb_array_elements(dados->'transportadoras') t
         where t->>'id' = 'total-express') as valor
  from public.ressarc_settings where id = 1
union all
select 'LOG pode solicitar', coalesce((dados->'permissoes'->'LOG'->>'formularios'), 'nao definido')
  from public.ressarc_settings where id = 1
union all
select 'SAC pode solicitar', coalesce((dados->'permissoes'->'SAC'->>'formularios'), 'nao definido')
  from public.ressarc_settings where id = 1
union all
select 'FIN pode solicitar', coalesce((dados->'permissoes'->'FIN'->>'formularios'), 'nao definido')
  from public.ressarc_settings where id = 1
union all
select 'bloquear NF duplicada', coalesce((dados->>'bloquearNfDuplicada'), 'nao definido')
  from public.ressarc_settings where id = 1
union all
select 'formularios com NF mapeada', count(*)::text from public.ressarc_forms where nfs <> '{}'
union all
select 'NF repetida no historico', coalesce(string_agg(nf || ' (' || formularios || ')', ' | '), 'nenhuma')
  from (select nf, string_agg(numero, ', ') as formularios
          from (select unnest(nfs) as nf, numero from public.ressarc_forms
                 where status = 'Finalizado' and not excluido) z
         group by nf having count(*) > 1) w;
