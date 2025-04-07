\set schema_name public
\set tbl_name largetable
\set new_colname id
\set seq_name largetable_seq_id
/*---------------------------*/
\set batch_size 1000
\set pg_sleep_interval 50
\set pg_sleep_value 1
\set vacuum_interval 10
\set vacuum_cost_delay 0
/*---------------------------*/
select oid as schema_oid from pg_namespace where nspname = :'schema_name' \gset
select pgc.oid as oid from pg_class pgc WHERE relname=:'tbl_name' and relnamespace = :'schema_oid' \gset
select r.rolname as owner from pg_class pgc inner join pg_roles r on pgc.relowner = r.oid where pgc.oid = :oid \gset
select round((reltuples/relpages*pg_relation_size(pg_class.oid)/(select current_setting('block_size'))::int) * :vacuum_interval/100) as vacuum_batch from pg_class where oid = :oid \gset
select relpages+least(relpages/4, 10000) as n_pages from pg_class where oid = :'oid' \gset
\pset format unaligned
\pset tuples_only on

select format('create_PK_%s.sql',:'tbl_name') as fname \gset
\out ./:fname

select 'set statement_timeout to ''100ms'';';
select format('alter table %I.%I add column %I bigint;',:'schema_name',:'tbl_name',:'new_colname');
select format('create sequence %I.%I as bigint owned by %I.%I;',:'schema_name',:'seq_name',:'tbl_name',:'new_colname');
select format('alter table %I.%I alter column %I set default nextval($$%I$$);',:'schema_name',:'tbl_name',:'new_colname',:'seq_name');
select format('alter sequence %I.%I owner to %I;',:'schema_name',:'seq_name',:'owner');
select format('reset statement_timeout;'||E'\n');

select 'set lock_timeout to ''100ms'';';
select 'set session_replication_role to ''replica'';';
select 'set deadlock_timeout to ''600s'';';
select format('set vacuum_cost_delay to %s;',:vacuum_cost_delay);
select 'select now() as start_time \gset';
select '\set cnt_err_vac 0'||E'\n';

-- Ver Pg14+
select format('update %I.%I set %I = nextval($$%I$$) where %I is null and ctid >=''(%s,0)'' and ctid<''(%s,0)'';',:'schema_name',:'tbl_name',:'new_colname',:'seq_name',:'new_colname',batch_start,batch_start+:batch_size)||
    case when ROW_NUMBER () OVER (ORDER BY batch_start) % :pg_sleep_interval = 0 then
      format(E'\n'||'select date_trunc(''sec'',now()) as now, ''%s/%s(%s%%)'' as pages_processed, date_trunc(''sec'',now()-:''start_time''::timestamp) as elapsed,
        date_trunc(''sec'',(now()-:''start_time''::timestamp)/round(%s*100.0/%s,1)*100 - (now()-:''start_time''::timestamp)) as estimate;'||E'\n'||'select pg_sleep(%s);',batch_start,:n_pages,round(batch_start*100.0/:n_pages,1),batch_start,:n_pages,:pg_sleep_value) else '' end ||
    case when ROW_NUMBER () OVER (ORDER BY batch_start) % 10 = 0 then
      format(E'\n'||
          'select n_dead_tup >= %s as res from pg_stat_all_tables where relid = %s \gset',:vacuum_batch, :oid)||E'\n'||
          '\if :res'||E'\n'||
          '  reset lock_timeout;'||E'\n'||
          format('  vacuum %I.%I;',:'schema_name', :'tbl_name')||E'\n'||
          /*pg_sleep for update n_dead_tup*/
          format('  select pg_sleep(0.6);')||E'\n'||
          format('  select  n_dead_tup < %s as res from pg_stat_all_tables where relid = %s \gset',:vacuum_batch, :oid)||E'\n'||
          '  \if :res'||E'\n'||
          '    \set cnt_err_vac 0'||E'\n'||
          '  \else'||E'\n'||
          '    select :cnt_err_vac::int + 1 as cnt_err_vac \gset'||E'\n'||
          '    select :cnt_err_vac >= 3 as res \gset'||E'\n'||
          '    \if :res'||E'\n'||
          '       \echo ''Can not perform a vacuum on the table. There may be a competing long-running transaction. Get rid of it and start over from step 2.'''||E'\n'||
          '       \q'||E'\n'||
          '    \endif'||E'\n'||
          '  \endif '||E'\n'||
          '  set lock_timeout to ''100ms'';'||E'\n'||
          '\endif'
    else ''
    end
from generate_series(0, (SELECT relpages+least(relpages/4, 10000) FROM pg_class where oid = :oid), :batch_size) as batch_start;
select '';
select substr(md5(random()::text), 1, 5) as rnd_str \gset
select $$set statement_timeout to '100ms';$$;
select format('alter table %I.%I add constraint %s_%s check (%I is not null) not valid;',:'schema_name',:'tbl_name',:'tbl_name',:'rnd_str',:'new_colname');
select $$reset statement_timeout;$$;
select format('alter table %I.%I validate constraint %s_%s;',:'schema_name',:'tbl_name',:'tbl_name',:'rnd_str');
select $$set statement_timeout to '100ms';$$;
select format('alter table %I.%I alter column %I set not null;',:'schema_name',:'tbl_name',:'new_colname');
select format('alter table %I.%I drop constraint %s_%s;',:'schema_name',:'tbl_name',:'tbl_name',:'rnd_str');
select $$reset statement_timeout;$$;
select format('create unique index concurrently %s_%s_idx on %I.%I(%I);',:'tbl_name',:'new_colname',:'schema_name',:'tbl_name',:'new_colname');
select $$set statement_timeout to '100ms';$$;
select format('alter table %I.%I add constraint %s_%s_pkey primary key using index largetable_id_idx;',:'schema_name',:'tbl_name',:'tbl_name',:'new_colname');
select $$reset statement_timeout;$$;
select format('\d %I.%I',:'schema_name',:'tbl_name');
\out
