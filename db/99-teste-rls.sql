-- =====================================================================
-- Teste das políticas — exerce a RLS como um usuário autenticado.
-- Política existir não é política funcionar: isto usa o banco de verdade.
-- Tudo acontece dentro de begin/rollback: NADA fica gravado.
-- =====================================================================
begin;

create temp table r(n int, teste text, esperado text, obtido text) on commit drop;
grant all on r to authenticated;

-- Conta de teste com o e-mail do convite do admin. Morre no rollback.
-- Isto já é o primeiro teste: o trigger tg_auth_provisionar tem de criar a
-- linha em ressarc_usuarios sozinho, lendo ressarc_convites. É o caminho real
-- de "Add user" no painel, sem copiar UUID nenhum à mão.
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, created_at, updated_at)
values ('00000000-0000-4000-8000-0000000000aa','00000000-0000-0000-0000-000000000000',
        'authenticated','authenticated','estoque@bbdi.com.br','!',now(),now());
insert into r select 0,'trigger provisiona a partir do convite','andre-luis|LOG|true|true',
  coalesce((select slug||'|'||setor||'|'||admin::text||'|'||ativo::text
              from public.ressarc_usuarios where auth_id = '00000000-0000-4000-8000-0000000000aa'),
           'NAO PROVISIONOU');

-- E quem não tem convite cria conta mas não vira usuário do sistema.
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, created_at, updated_at)
values ('00000000-0000-4000-8000-0000000000cc','00000000-0000-0000-0000-000000000000',
        'authenticated','authenticated','estranho@invalido.local','!',now(),now());
insert into r select -1,'e-mail fora do convite NAO vira usuario','0',
  count(*)::text from public.ressarc_usuarios where auth_id = '00000000-0000-4000-8000-0000000000cc';

set local role authenticated;
set local request.jwt.claims = '{"sub":"00000000-0000-4000-8000-0000000000aa","role":"authenticated"}';

-- 1. Quem eu sou, segundo o servidor
insert into r values
 (1,'sou_ativo','true', public.ressarc_sou_ativo()::text),
 (2,'sou_admin','true', public.ressarc_sou_admin()::text),
 (3,'meu_slug','andre-luis', public.ressarc_meu_slug()),
 (4,'meu_setor','LOG', public.ressarc_meu_setor());

-- 2. Leituras que o app faz no boot
insert into r select 5,'le equipe','>=1', count(*)::text from public.ressarc_usuarios;
insert into r select 6,'le settings','1', count(*)::text from public.ressarc_settings;
insert into r select 7,'le convites (admin)','6', count(*)::text from public.ressarc_convites;

-- 3. Numeração vem do servidor
insert into r select 8,'rpc numero','1', public.ressarc_proximo_numero(2026)::text;

-- 4. Formulário: criar, ler, reconciliar
insert into public.ressarc_forms (id,numero,transportadora_id,transportadora,solicitante_id,solicitante,filial,status,total,dados)
values ('00000000-0000-4000-8000-0000000000f1','RES-2026-0001','jadlog','Jadlog','andre-luis','André Luís','0101','Aberto',1234.56,'{"itens":[]}');
insert into r select 9,'autor carimbado pelo servidor','00000000-0000-4000-8000-0000000000aa',
       autor::text from public.ressarc_forms where id='00000000-0000-4000-8000-0000000000f1';

update public.ressarc_forms set reconciliacao='Confirmado' where id='00000000-0000-4000-8000-0000000000f1';
insert into r select 10,'reconciliar','Confirmado', reconciliacao from public.ressarc_forms where id='00000000-0000-4000-8000-0000000000f1';

-- 5. Log entra
insert into public.ressarc_logs (id,evento,operador,form_id) values
 ('00000000-0000-4000-8000-0000000000e1','FORM_CRIADO','André Luís','00000000-0000-4000-8000-0000000000f1');
insert into r select 11,'log gravado','1', count(*)::text from public.ressarc_logs;

-- 6. O que TEM de ser negado.
--    Aqui se mede o EFEITO, não a exceção. Update ou delete barrado só pela
--    RLS afeta 0 linhas e NÃO levanta erro: "não deu erro" não é "não passou".
--    Por isso cada teste tenta, engole o erro e depois vai conferir o dado.
do $$ declare e text := 'sem erro (RLS calada)'; begin
  begin update public.ressarc_logs set detalhe = 'adulterado'
          where id = '00000000-0000-4000-8000-0000000000e1';
  exception when others then e := 'negado ('||sqlstate||')'; end;
  if exists (select 1 from public.ressarc_logs where detalhe = 'adulterado')
    then e := 'ADULTEROU O LOG'; end if;
  insert into r values (12,'log NAO pode ser alterado','negado',e);
end $$;

do $$ declare e text := 'sem erro (RLS calada)'; begin
  begin delete from public.ressarc_logs where id = '00000000-0000-4000-8000-0000000000e1';
  exception when others then e := 'negado ('||sqlstate||')'; end;
  if not exists (select 1 from public.ressarc_logs where id = '00000000-0000-4000-8000-0000000000e1')
    then e := 'APAGOU O LOG'; end if;
  insert into r values (13,'log NAO pode ser apagado','negado',e);
end $$;

do $$ declare e text := 'sem erro (RLS calada)'; begin
  begin delete from public.ressarc_forms where id = '00000000-0000-4000-8000-0000000000f1';
  exception when others then e := 'negado ('||sqlstate||')'; end;
  if not exists (select 1 from public.ressarc_forms where id = '00000000-0000-4000-8000-0000000000f1')
    then e := 'APAGOU O FORMULARIO'; end if;
  insert into r values (14,'formulario NAO pode ser apagado','negado',e);
end $$;

do $$ declare e text := 'sem erro (RLS calada)'; begin
  begin update public.ressarc_sequences set valor = 999;
  exception when others then e := 'negado ('||sqlstate||')'; end;
  if exists (select 1 from public.ressarc_sequences where valor = 999)
    then e := 'FORCOU A NUMERACAO'; end if;
  insert into r values (15,'numeracao NAO pode ser forcada','negado',e);
end $$;

-- 7. Rascunho, preferência e presença (cada um só mexe no seu)
insert into public.ressarc_drafts (usuario,transportadora_id,dados) values (auth.uid(),'jadlog','{"a":1}');
insert into public.ressarc_prefs (usuario,dados) values (auth.uid(),'{"ultimaAba":"dashboard"}');
insert into public.ressarc_presence (usuario,slug,nome,setor) values (auth.uid(),'andre-luis','André Luís','LOG');
insert into r select 16,'rascunho/pref/presenca','3',
 ((select count(*) from public.ressarc_drafts)+(select count(*) from public.ressarc_prefs)+(select count(*) from public.ressarc_presence))::text;

do $$ begin
  insert into public.ressarc_drafts (usuario,transportadora_id,dados)
  values ('00000000-0000-4000-8000-0000000000bb','jadlog','{}');
  insert into r values (17,'rascunho de OUTRO usuario','negado','PASSOU — FALHA');
exception when others then insert into r values (17,'rascunho de OUTRO usuario','negado','negado ('||sqlstate||')'); end $$;

-- 8. Agora como quem NÃO está no cadastro: não pode ver nada
set local request.jwt.claims = '{"sub":"00000000-0000-4000-8000-0000000000cc","role":"authenticated"}';
insert into r select 18,'conta sem cadastro ve formularios','0', count(*)::text from public.ressarc_forms;
insert into r select 19,'conta sem cadastro ve logs','0', count(*)::text from public.ressarc_logs;
insert into r select 20,'conta sem cadastro ve equipe','0', count(*)::text from public.ressarc_usuarios;
insert into r select 21,'conta sem cadastro ve convites','0', count(*)::text from public.ressarc_convites;
do $$ begin
  insert into public.ressarc_forms (id,numero,transportadora_id,transportadora,solicitante_id,solicitante,filial,status,total)
  values (gen_random_uuid(),'RES-2026-9999','x','x','x','x','0101','Aberto',0);
  insert into r values (22,'conta sem cadastro grava','negado','PASSOU — FALHA');
exception when others then insert into r values (22,'conta sem cadastro grava','negado','negado ('||sqlstate||')'); end $$;

reset role;
select n, teste, esperado, obtido,
       case when obtido = esperado
             or (esperado='>=1' and obtido::int >= 1)
             or (esperado='negado' and obtido like 'negado%') then 'ok' else '*** FALHOU ***' end as veredito
  from r order by n;

rollback;
