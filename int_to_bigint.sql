\echo 'This utility helps you migrate int4 to bigint'
\if :{?schema_name}
 /*get variable from user*/
\else
  \prompt 'Schema name: [public]: ' schema_name
  select :'schema_name' = '' as res \gset
  \if :res
    \set schema_name public
  \endif
\endif

--Check schema existence
select not exists (select 1 from information_schema.schemata where schema_name = :'schema_name') as res \gset
\if :res
  \echo 'Can''t find schema ':'schema_name'
  \q
\endif

\if :{?tbl_name}
  /*get variable from user*/
\else
  \prompt 'Table name: ' tbl_name
\endif

--Check table existence
select not exists (select 1 from pg_tables where tablename = :'tbl_name' and schemaname = :'schema_name') as res \gset
\if :res
  \echo 'Can''t find table ':'tbl_name' 'in schema ':'schema_name'
  \q
\else
  select format('%I.%I',:'schema_name',:'tbl_name') as res \gset
  \pset pager on
  \d+ :res
  \pset pager off
  -- Finding the table OID
  select pgc.oid as oid from pg_class pgc inner join pg_namespace pgn on pgc.relnamespace = pgn.oid WHERE relname=:'tbl_name' and pgn.nspname=:'schema_name' \gset
\endif

\if :{?col_name}
 /*get variable from user*/
\else 
  \prompt 'int4 column name: ' col_name
\endif 
--Check column existence
select not exists (select 1 from information_schema.columns where table_schema = :'schema_name' and table_name = :'tbl_name' and column_name = :'col_name') as res  \gset
\if :res
  \echo 'Can''t find column: ':'col_name'
  \q
\endif

--Check if the found column has integer type
select data_type != 'integer' as res from information_schema.columns where table_schema = :'schema_name' and table_name = :'tbl_name' and column_name = :'col_name' \gset
\if :res
  \echo 'Type must be integer'
  \q
\endif

\set new_colname new_:col_name
\set old_colname old_:col_name

select setting::int >= 140000 as res from pg_settings where name = 'server_version_num' \gset
--If version 14.0 or higher it is possible to sort by ctid
\if :res
  \set ver_14 true
  \if :{?batch_size}
    /*get variable from user*/
  \else
    \prompt 'Blocks in batch [1000]: ' batch_size
  \endif 
  --Inquire about the number of blocks in a batch
  select :'batch_size' = '' as res \gset
  \if :res
    \set batch_size 1000
  \else
    select :'batch_size' !~ '^[0-9\.]+$' as res \gset
    \if :res
       \echo 'Count blocks must be integer!'
       \q
    \endif
  \endif
\else
  --If version 14 or older choose a specific field and set a range for it
  --The range should be integer or date
  \set ver_14 false
  \echo -n 'Field name that will be used to split data into equal batches (type: integer, bigint, date, timestamp): [':'col_name']:
  \if :{?batch_field_name}
   /*get variable from user*/
  \else
    \prompt ' ' batch_field_name
  \endif 
  --\set batch_field_name created_at

  select :'batch_field_name' = '' as res \gset
  \if :res
    \set batch_field_name :col_name
  \endif
  --Check existence of the field
  select not exists (select 1  from information_schema.columns where table_schema = :'schema_name' and table_name = :'tbl_name' and column_name = :'batch_field_name') as res \gset
  \if :res
     \echo 'Field ':'batch_field_name' not found!
     \q
  \endif

  --Check that there is a non-partial index that starts at the specified field, otherwise warn that everything will be very slow.
  select (count(*) = 0) as res
  from pg_index pgi
        inner join pg_class pgc on pgi.indexrelid = pgc.oid
  where indexrelid in (select indexrelid from pg_stat_all_indexes where relid = :oid) and
  (select attnum
  from pg_attribute
  where attrelid = :oid
  and attnum > 0 and attname = :'batch_field_name') = ((string_to_array(indkey::text, ' ')::int2[])[1]) and indpred is null \gset
  \if :res
    \echo 'There are no suitable indexes for speeding up work on the selected field (either the field is not in the 1st place in the index, or the index is partial, or there are no indexes containing this field)'
    \echo 'Consider using another field as the field will need to be split into batches, otherwise the process can be VERY slow'
  \endif

  --If the specified field has type integer or bigint
  select (data_type = 'integer' or data_type = 'bigint') as res from information_schema.columns where table_schema = :'schema_name' and table_name = :'tbl_name' and column_name = :'batch_field_name' \gset
  \if :res
    \set batch_field_is_int true
    --Set the batch size
    \prompt 'rows in batch [50000]: ' batch_size_int
    select :'batch_size_int' = '' as res \gset
    \if :res
      \set batch_size_int 50000
    \else
      select :'batch_size_int' !~ '^[0-9\.]+$' as res \gset
      \if :res
         \echo 'A number must be entered'
         \q
      \endif
    \endif
  \else
     \set batch_field_is_int false
     --If not integer or bigint
     select data_type in('date', 'timestamp with time zone', 'timestamp without time zone') as res from information_schema.columns where table_schema = :'schema_name' and table_name = :'tbl_name' and column_name = :'batch_field_name' \gset
     \if :res
       --If type of the field related to a date
       --Set batch size in the standard interval description
       \prompt 'batch size interval [1 day]: ' batch_size_date
       select :'batch_size_date' = '' as res \gset
       \if :res
         \set batch_size_date '1 day'
       \endif

       --Checking that the entered value is an interval
       --Created random set of symbols, to ensure the uniqueness of the function name.
        select substr(md5(random()::text), 1, 5) as rnd_str \gset
        create or replace function _is_interval_:rnd_str(text) returns boolean
           language plpgsql as
        $$begin
           perform cast ($1 as interval);
           return true;
        exception
           when invalid_datetime_format then
                  return false;
        end;$$;
        select not _is_interval_:rnd_str(:'batch_size_date') as res \gset
        drop function _is_interval_:rnd_str;
        \if :res
           \echo 'The entered value must be of the interval type!'
           \q
        \endif
     \else
        --If not integer neither is related to date
        \echo 'Unsupported data type'
        \q
     \endif
  \endif
\endif

\if :{?pg_sleep_interval}
 /*get variable from user*/
\else
  \prompt 'Sleep after N batches [50]: ' pg_sleep_interval
\endif

select :'pg_sleep_interval' = '' as res \gset
\if :res
  \set pg_sleep_interval 50
\else
  select :'pg_sleep_interval' !~ '^[0-9\.]+$' as res \gset
  \if :res
     \echo 'A number must be entered'
     \q
  \endif
\endif

\if :{?pg_sleep_value}
 /*get variable from user*/
\else
 \prompt 'Sleep duration N sec [1]: ' pg_sleep_value
\endif

select :'pg_sleep_value' = '' as res \gset
\if :res
  \set pg_sleep_value 1
\else
  select :'pg_sleep_value' !~ '^[0-9\.]+$' as res \gset
  \if :res
     \echo 'A number must be entered'
     \q
  \endif
\endif

\if :{?vacuum_interval}
 /*get variable from user*/
\else
  \prompt 'Vacuum after every N% rows completed [10]: ' vacuum_interval
\endif

select :'vacuum_interval' = '' as res \gset
\if :res
  \set vacuum_interval 10
\else
  select :'vacuum_interval' !~ '^[0-9\.]+$' as res \gset
  \if :res
     \echo 'A number must be entered'
     \q
  \endif
\endif

\if :{?vacuum_cost_delay}
 /*get variable from user*/
\else
  \prompt 'vacuum_cost_delay (0..100 ms) [0]: ' vacuum_cost_delay
\endif

select :'vacuum_cost_delay' = '' as res \gset
\if :res
  \set vacuum_cost_delay 0
\else
  select :'vacuum_cost_delay' !~ '^[0-9\.]+$' as res \gset
  \if :res
     \echo 'A number must be entered'
     \q
  \else
     select not (:vacuum_cost_delay::integer>=0 and :vacuum_cost_delay::integer <=100) as res \gset
     \if :res
        \echo 'vacuum_cost_delay must be in [0..100]!'
        \q
     \endif
  \endif
\endif

--We obtained the threshold of n_dead_tuples after which vacuum will be triggered (with a possible deviation of +10 batches).
\set vacuum_batch 1
select relpages != 0 as res from pg_class where oid = :oid \gset
\if :res
  select round((reltuples/relpages*pg_relation_size(pg_class.oid)/(select current_setting('block_size'))::int) * :vacuum_interval/100) as vacuum_batch from pg_class where oid = :oid \gset
\endif 

\echo
\echo ========================
\echo Information about table:
select 
  case 
	when reltuples <= 0 then 0
  else 
	  (reltuples/relpages*pg_relation_size(pg_class.oid)/(select current_setting('block_size'))::int)::int 
  end as n_live_tuple,
  relpages as n_pages,
  pg_size_pretty(pg_relation_size(pg_class.oid)) as tbl_size,
  pg_size_pretty(pg_indexes_size(pg_class.oid)) as indexes_size,
  pg_size_pretty(pg_total_relation_size(pg_class.oid)) as total_size
from pg_class
where oid = :oid;
select pgc.relname as index_name, pg_size_pretty(pg_relation_size(indexrelid)) index_size from pg_index pgi inner join pg_class pgc on pgi.indexrelid = pgc.oid where pgi.indrelid = :oid;

--Start procedure
\pset format unaligned
\pset tuples_only on

--Step 1. Added column, created a function and a trigger
select format('migr_%s_step_1.sql',:'tbl_name') as fname \gset
\out ./:fname
select 'begin;';
select '  set local statement_timeout to ''1000ms'';';
select format('  alter table %I.%I add column %I bigint;'||E'\n',:'schema_name',:'tbl_name',:'new_colname');

select format(
'  CREATE FUNCTION %I."%s_migr_f"()
  returns trigger as $$
  begin
    new.%I := new.%I;
    return new;
  end $$ language plpgsql;'||E'\n',:'schema_name',:'tbl_name', :'new_colname', :'col_name');

SELECT format(
'  CREATE TRIGGER "%s_migr_t"
  before insert or update on %I.%I
  for each row
  execute function %I."%s_migr_f"();', :'tbl_name', :'schema_name', :'tbl_name', :'schema_name',:'tbl_name');
select 'commit;';

select $$select 'The next step may take a long time. Try running it in tmux or screen!' as "Notice";$$;

\o
\echo 'Created ':'fname' - Add column, trigger and function

--Step 2. Copied data from one column to another
select format('migr_%s_step_2.sql',:'tbl_name') as fname \gset
\out ./:fname
select 'set lock_timeout to ''100ms'';';
select 'set session_replication_role to ''replica'';';
select 'set deadlock_timeout to ''600s'';';
select format('set vacuum_cost_delay to %s;',:vacuum_cost_delay);
select 'select now() as start_time \gset';
select '\set cnt_err_vac 0'||E'\n';

\if :ver_14
  /*ctid*/
  select relpages+10000 as n_pages from pg_class where oid = :oid \gset
  select format('update %I.%I set %I = %I where %I is distinct from %I and ctid >=''(%s,0)'' and ctid<''(%s,0)'';',:'schema_name',:'tbl_name',:'new_colname',:'col_name',:'col_name',:'new_colname',batch_start,batch_start+:batch_size)||
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
  from generate_series(0, (SELECT relpages+10000 FROM pg_class where oid = :oid), :batch_size) as batch_start;

\elif :batch_field_is_int
  /*integer or bigint*/
  select least(max(:"batch_field_name")::bigint + :batch_size_int::int + 100000, 2^31-1) as max_value, min(:"batch_field_name") as min_value from :"schema_name".:"tbl_name" \gset
  select format('update %I.%I set %I = %I where %I is distinct from %I and %I >= %s and %I < %s;',
                 :'schema_name',:'tbl_name',:'new_colname',:'col_name',:'col_name',:'new_colname',:'batch_field_name',batch_start,:'batch_field_name', batch_start+:batch_size_int::int)||
  case when ROW_NUMBER () OVER (ORDER BY batch_start) % :pg_sleep_interval = 0 then
    format(E'\n'||'select date_trunc(''sec'',now()) as now, ''%s/%s(%s%%)'' as rows_processed, date_trunc(''sec'',now()-:''start_time''::timestamp) as elapsed,',
      batch_start,:'max_value', round((batch_start::bigint - :min_value)*100.0/(:max_value - :min_value),2))||
    format(' date_trunc(''sec'',(%s - %s)*(now()-:''start_time''::timestamp)/(%s - %s) - (now()-:''start_time''::timestamp)) as estimate;'||E'\n'||'select pg_sleep(%s);',
      :'max_value', :'min_value', batch_start, :'min_value', :pg_sleep_value)
  else '' end ||
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
  from generate_series((select min(:"batch_field_name") from :"schema_name".:"tbl_name"), :max_value, :batch_size_int) as batch_start;
\else
  /*date, timestamp*/
  select (max(:"batch_field_name") + :'batch_size_date'::interval*100)::date as max_value, min(:"batch_field_name")::date as min_value from :"schema_name".:"tbl_name" \gset
  select format('update %I.%I set %I = %I where %I is distinct from %I and %I >= ''%s'' and %I < ''%s'';', :'schema_name',:'tbl_name',:'new_colname',:'col_name',:'col_name',:'new_colname',:'batch_field_name',batch_start::date,:'batch_field_name', batch_start::date+:'batch_size_date'::interval)||
    case when ROW_NUMBER () OVER (ORDER BY batch_start) % :pg_sleep_interval = 0 then
    format(E'\n'||'select date_trunc(''sec'',now()) as now, ''%s/%s(%s%%)'' as rows_processed, date_trunc(''sec'',now()-:''start_time''::timestamp) as elapsed,',batch_start::date,:'max_value', (batch_start::date -:'min_value'::date)*100/(:'max_value'::date - :'min_value'::date))||
    format('date_trunc(''sec'',(''%s''::date - ''%s''::date)*(now()-:''start_time''::timestamp)/(''%s''::date - ''%s''::date) - (now()-:''start_time''::timestamp)) as estimate;'||E'\n'||'select pg_sleep(%s);',
        :'max_value', :'min_value', batch_start, :'min_value', :pg_sleep_value)
    else '' end ||
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
  else ''       end
  from generate_series(date :'min_value', :'max_value', :'batch_size_date') as batch_start;
\endif

select 'reset lock_timeout;';
select format('vacuum %I.%I;',:'schema_name',:'tbl_name');
select 'select now()-:''start_time''::timestamp as total_elapsed;';

select $$select 'The non-updated rows are being counted, please wait.' as "Information";$$;
select format('select count(*) cnt from %I.%I where %I is distinct from %I \gset',:'schema_name',:'tbl_name',:'col_name',:'new_colname');
select $$
select :cnt = 0 as res \gset
\if :res
  \echo 'You can proceed to the next step.'
\else
  \echo 'The number of rows that have not been updated: ':cnt
  \echo 'It might be better if you repeat step 2.'
\endif
$$;

select $$select 'Please check index and constraint list on step 3!' as "Notice";$$;
\o
\echo 'Created ':'fname' - Copy data from old column to new
--\set

--Step 3. Working with index, sequences and constraints.
--Pullout of all indexes, that are related to the field that we’ve migrated.
select substr(md5(random()::text), 1, 5) as rnd_str \gset
select format('migr_%s_step_3.sql',:'tbl_name') as fname \gset
/*Create table idx_name, md5(idx_name) and fill it in:*/

select E'\n'||'Creating temporary table for indexes:';
create temporary table idx_name_tmp(indexrelid oid, relname text, md5_idx_name text);

insert into idx_name_tmp

SELECT
    pgi.indexrelid, pgc.relname, md5(pgc.relname)
FROM
    pg_index pgi
    INNER JOIN pg_class pgc ON pgi.indexrelid = pgc.oid
WHERE
    /*selected all indexes that belong to this table*/
    pgi.indrelid = :oid
    AND
    /*Now we impose additional conditions*/
    (
        /*The index should be built according to our field - comparison with indkey*/
       (SELECT attnum FROM pg_attribute WHERE attrelid = :oid AND attnum > 0 AND attname = :'col_name') = ANY (string_to_array(indkey::text, ' ')::int2[]) OR
    /*Don't forget the functional indexes - indkey = 0*/
       ('0' = ANY (string_to_array(indkey::text, ' ')::int2[]) AND split_part(pg_get_indexdef(indexrelid), ' USING ', 2) LIKE '%('||:'col_name'||')%') OR
    /*And partial indexes*/
       ((pg_get_indexdef(indexrelid) LIKE '%WHERE%')
        AND (   split_part(pg_get_indexdef(indexrelid), ' USING ', 2) LIKE '%(' || quote_ident(:'col_name') || ' %'
             OR split_part(pg_get_indexdef(indexrelid), ' USING ', 2) LIKE '% ' || quote_ident(:'col_name') || ')%'))
        );
\out ./:fname
--We retrieve indexes built in our field (excluding indexes where this field is specified in the conditions)
/*
1) "(id," -> "(new_id,"
2) "(id)" -> "(new_id)"
3) ", id)" -> ", new_id)"
4) ", id," -> ", new_id,"
5) " id " -> " new_id "
*/

select replace(replace(replace(split_part(pg_get_indexdef(indexrelid),' USING ', 1), 'INDEX', 'INDEX CONCURRENTLY'), relname, quote_ident(md5(relname))),'""','"')||' USING '||
replace(replace(replace(replace(split_part(pg_get_indexdef(indexrelid),' USING ', 2),
   '('||quote_ident(:'col_name')||',','('||quote_ident(:'new_colname')||','),
   '('||quote_ident(:'col_name')||')', '('||quote_ident(:'new_colname')||')'),
   ', '||quote_ident(:'col_name')||')', ', '||quote_ident(:'new_colname')||')'),
   ', '||quote_ident(:'col_name')||',',', '||quote_ident(:'new_colname')||',')||';'
from idx_name_tmp
where (pg_get_indexdef(indexrelid) not like '%WHERE%')
union
select replace(split_part(replace(replace(pg_get_indexdef(indexrelid), 'INDEX', 'INDEX CONCURRENTLY'), relname, quote_ident(md5(relname))),' USING ', 1),'""','"')||' USING '||
replace(
	replace(
		replace(
			replace(
				split_part(pg_get_indexdef(indexrelid),' USING ', 2), 
					'('||quote_ident(:'col_name')||' ','('||quote_ident(:'new_colname')||' ')
			,' '||quote_ident(:'col_name')||')',' '||quote_ident(:'new_colname')||')')
		,' '||quote_ident(:'col_name')||' ',' '||quote_ident(:'new_colname')||' ')
	, '('||quote_ident(:'col_name')||',','('||quote_ident(:'new_colname')||',')||';'
from idx_name_tmp
where (pg_get_indexdef(indexrelid) like '%WHERE%') and (split_part(pg_get_indexdef(indexrelid),' USING ', 2) like '%('||quote_ident(:'col_name')||',%' or split_part(pg_get_indexdef(indexrelid),' USING ', 2) like '% '||quote_ident(:'col_name')||')%' or split_part(pg_get_indexdef(indexrelid),' USING ', 2) like '%('||quote_ident(:'col_name')||' %');
--Created a temporary index
select format('CREATE INDEX CONCURRENTLY "_%s_%s" on %I.%I(%I) where %I is distinct from %I;', :'tbl_name', :'rnd_str', :'schema_name', :'tbl_name', :'col_name', :'col_name', :'new_colname');
select '--Please check constraint list:';
--Creating constraints

--Check the number of constants, and if it is not equal to 0, then enclose the next block in begin/end
select count(*)!=0 as res FROM pg_catalog.pg_constraint r
WHERE r.conrelid = :oid AND r.contype = 'c'
and (pg_catalog.pg_get_constraintdef(r.oid, true) like '%('||quote_ident(:'col_name')||' %' or
     pg_catalog.pg_get_constraintdef(r.oid, true) like '% '||quote_ident(:'col_name')||' %' or
     pg_catalog.pg_get_constraintdef(r.oid, true) like '% '||quote_ident(:'col_name')||')%') \gset

\if :res
  select $$begin;$$;
  select $$  set local statement_timeout = '1s';$$;
  SELECT format('  alter table %I.%I add constraint ',:'schema_name',:'tbl_name')||r.conname||'_new '||trim(trailing 'NOT VALID' from replace(pg_catalog.pg_get_constraintdef(r.oid, true), :'col_name', :'new_colname'))||' not valid;'
  FROM pg_catalog.pg_constraint r
  WHERE r.conrelid = :oid AND r.contype = 'c'
  and (pg_catalog.pg_get_constraintdef(r.oid, true) like '%('||quote_ident(:'col_name')||' %' or
       pg_catalog.pg_get_constraintdef(r.oid, true) like '% '||quote_ident(:'col_name')||' %' or
       pg_catalog.pg_get_constraintdef(r.oid, true) like '% '||quote_ident(:'col_name')||')%')
  ORDER BY 1;
  select $$commit;$$;
\endif

--Check not null
select attnotnull as res from pg_attribute where attrelid = :oid and attname = :'col_name' and attnum > 0 \gset
\if :res
  select $$begin;$$;
  select $$  set local statement_timeout = '1s';$$;
  select format('  alter table %I.%I add constraint %s_%s_not_null check (%I is not null) not valid;', :'schema_name', :'tbl_name', :'tbl_name', :'new_colname', :'new_colname');
  select $$commit;$$;
  select format('alter table %I.%I validate constraint %s_%s_not_null;',:'schema_name', :'tbl_name', :'tbl_name', :'new_colname');
\endif

\o
\echo 'Created ':'fname' - Indexes and constraints

--Finding PrimaryKey with our col_name
\set new_pk_idx ''
select count(*) cnt from pg_constraint pgc
  inner join pg_attribute pga on pgc.conrelid = pga.attrelid
where pgc.conrelid = :oid and contype = 'p' and attnum = any (conkey) and attname = :'col_name' \gset

select :cnt = 1 as res \gset
\if :res
  --If such a PK is found, then write its name to pk_name, otherwise leave this variable empty
    select pgc.conname as pk_name
    from pg_constraint pgc
      inner join pg_attribute pga on pgc.conrelid = pga.attrelid
    where pgc.conrelid = :oid and contype = 'p' and attnum = any (conkey) and attname = :'col_name' \gset

    --Finding index name, based on which a new PK will be built
    select md5_idx_name as new_pk_idx
    from pg_class pgc
            inner join idx_name_tmp idx on pgc.relname = idx.relname
    where oid = (select indexrelid from pg_index where indrelid = (select oid from pg_class where oid = :oid) and indisprimary) \gset
\endif

-- Finding default value
SELECT default_value, default_value IS NOT NULL AS default_value_exists
FROM (
  SELECT
    (SELECT pg_catalog.pg_get_expr(d.adbin, d.adrelid, true)
     FROM pg_catalog.pg_attrdef d
     WHERE d.adrelid = a.attrelid AND d.adnum = a.attnum AND a.atthasdef) AS default_value
  FROM pg_catalog.pg_attribute a
  WHERE a.attrelid = :oid
    AND attname=:'col_name' AND a.attnum > 0 AND NOT a.attisdropped) AS t \gset

--Locating sequence name
\set seq_name ''
\set ident_name ''
\set ident_type ''

SELECT count(*) as cnt
FROM pg_catalog.pg_attribute a
WHERE a.attrelid = :oid
  AND a.attname=:'col_name' AND a.attnum > 0 AND NOT a.attisdropped AND a.atthasdef \gset

select :cnt = 1 as res \gset
\if :res
  SELECT
    split_part((SELECT pg_catalog.pg_get_expr(d.adbin, d.adrelid, true) FROM pg_catalog.pg_attrdef d WHERE d.adrelid = a.attrelid AND d.adnum = a.attnum AND a.atthasdef),chr(39),2)::regclass::oid as seq_oid,
    split_part((SELECT pg_catalog.pg_get_expr(d.adbin, d.adrelid, true) FROM pg_catalog.pg_attrdef d WHERE d.adrelid = a.attrelid AND d.adnum = a.attnum AND a.atthasdef),chr(39),2) as seq_name
    FROM pg_catalog.pg_attribute a
    WHERE a.attrelid = :oid
      AND a.attname=:'col_name' AND a.attnum > 0 AND NOT a.attisdropped AND a.atthasdef \gset
\endif

select :'seq_name' = '' as res \gset
\if :res
  -- If identity
  select count(*) as cnt from pg_attribute where attrelid = :oid and attname = :'col_name' and attidentity != '' \gset
  select :cnt = 1 as res \gset
  \if :res
        select split_part(pg_get_serial_sequence(quote_ident(:'schema_name')||'.'||quote_ident(:'tbl_name'), :'col_name'), '.', 2) as ident_name \gset
        select case attidentity when 'd' then 'by default' when 'a' then 'always' end as ident_type from pg_attribute where attrelid = :oid and attname = :'col_name' \gset
  \endif
\endif

--Foreign keys
select E'\n'||'Creating temporary table for constraints:';
create temporary table fk_names_tmp(type int, command text, fk_name text, relname text, condef text);

insert into fk_names_tmp SELECT 1, 'alter table '||conrelid::pg_catalog.regclass::text||' drop constraint '||quote_ident(conname)||';',
conname, conrelid::pg_catalog.regclass AS ontable,
       pg_catalog.pg_get_constraintdef(oid, true) AS condef
 FROM pg_catalog.pg_constraint c
 WHERE confrelid IN (SELECT pg_catalog.pg_partition_ancestors(:oid)
                     UNION ALL VALUES (:oid))
       AND contype = 'f' AND conparentid = 0
           AND pg_catalog.pg_get_constraintdef(oid, true) like '%('||quote_ident(:'col_name')||')%'
ORDER BY conname;

insert into fk_names_tmp SELECT 2, 'alter table '||conrelid::pg_catalog.regclass::text||' add constraint '||quote_ident(conname)||' '||pg_catalog.pg_get_constraintdef(oid, true)::text||' NOT VALID;',
conname, conrelid::pg_catalog.regclass AS ontable,
        pg_catalog.pg_get_constraintdef(oid, true) AS condef
  FROM pg_catalog.pg_constraint c
 WHERE confrelid IN (SELECT pg_catalog.pg_partition_ancestors(:oid)
                     UNION ALL VALUES (:oid))
       AND contype = 'f' AND conparentid = 0
           AND pg_catalog.pg_get_constraintdef(oid, true) like '%('||quote_ident(:'col_name')||')%'
ORDER BY conname;

--Step 4. The sequence of commands for transition itself
select format('migr_%s_step_4.sql',:'tbl_name') as fname \gset
\out ./:fname

--Updating all the fields where values in the new column and the old one do not match (to speed up the search the temporary index was created during step 3)
--Moving away from seq_scan - here the optimizer can mistakenly incur unnecessary costs
select 'set enable_seqscan to 0;';
select format('update %I.%I set %I = %I where %I is distinct from %I;',:'schema_name',:'tbl_name', :'new_colname', :'col_name', :'col_name', :'new_colname')||E'\n';
select 'set enable_seqscan to 1;';
select 'select now() as start_time \gset';
select '\timing on';
select 'BEGIN;';
select '  set local statement_timeout to ''20s'';';
select format('  lock table  %I.%I in access exclusive mode;',      :'schema_name', :'tbl_name');

select '  '||command from fk_names_tmp where type = 1;
--IF generated as identity
select :'ident_name' != '' as res \gset
\if :res
  select format('  select nextval(''%I''::regclass) as start_new_id \gset',:'ident_name');
  --PK removal is only necessary if pk is actually affected
  \if :{?pk_name}
    select format('  alter table %I.%I drop constraint %I;',          :'schema_name', :'tbl_name', :'pk_name');
  \endif
  select format('  alter table %I.%I alter column %I drop identity;', :'schema_name', :'tbl_name', :'col_name');
  select format('  alter table %I.%I alter %I drop not null;',:'schema_name', :'tbl_name', :'col_name');
\else
  --PK removal is only necessary if pk is actually affected
  \if :{?pk_name}
    select format('  alter table %I.%I drop constraint %I;',          :'schema_name', :'tbl_name', :'pk_name');
  \endif
  --It won't do any harm, even if it's not set
  select format('  alter table %I.%I alter %I drop default;',       :'schema_name', :'tbl_name', :'col_name');
  select format('  alter table %I.%I alter %I drop not null;',:'schema_name', :'tbl_name', :'col_name');
\endif

-- not null
select attnotnull as res from pg_attribute where attrelid = :oid and attnum >=0 and attname = :'col_name' \gset
\if :res
  select format('  alter table %I.%I alter %I set not null;',:'schema_name', :'tbl_name', :'new_colname');
\endif

select attnotnull as res from pg_attribute where attrelid = :oid and attname = :'col_name' and attnum > 0 \gset
\if :res
  select format('  alter table %I.%I drop constraint if exists %s_%s_not_null;',:'schema_name', :'tbl_name', :'tbl_name', :'new_colname');
\endif

select format('  alter table %I.%I rename %I to %I;',           :'schema_name', :'tbl_name', :'col_name', :'old_colname');
select format('  alter table %I.%I rename %I to %I;',           :'schema_name', :'tbl_name', :'new_colname', :'col_name');
\if :default_value_exists
  select format('  alter table %I.%I alter %I set default %s;',:'schema_name', :'tbl_name', :'col_name', :'default_value');
\endif

--If the sequence name is not specified, then the next block of code is not executed
select :'seq_name' != '' as res \gset
\if :res
  select format('  alter sequence %s owned by %I.%I.%I;', :'seq_name', :'schema_name', :'tbl_name', :'col_name');
  SELECT pg_catalog.format_type(seqtypid, NULL)='integer' as res FROM pg_catalog.pg_sequence WHERE seqrelid = :'seq_oid' \gset
  \if :res
    select format('  alter sequence %s as bigint;',:'seq_name');
  \endif 
  SELECT seqmax != 9223372036854775807 as res FROM pg_catalog.pg_sequence WHERE seqrelid = :'seq_oid' \gset
  \if :res
    select seqmax as seqmax from pg_catalog.pg_sequence where seqrelid = :'seq_oid' \gset
    select format('  select $$Please note! The sequence has an upper threshold (%s) set different from the standard one. $$||E''\n''||$$It may be worth running the command: alter sequence %I no maxvalue;$$ as "Notice";',:'seqmax',:'seq_name');
  \endif
\endif

--If  generated as identity
select :'ident_name' != '' as res \gset
\if :res
  select format('  alter table %I.%I alter column %I add generated %s as identity (start with :start_new_id);',:'schema_name', :'tbl_name',:'col_name', :'ident_type');
\endif

\if :{?pk_name}
  select format('  alter table %I.%I add constraint %I primary key using index %I;',:'schema_name', :'tbl_name', :'pk_name', :'new_pk_idx');
\endif

select '  '||command from fk_names_tmp where type = 2;
select format('  drop trigger "%s_migr_t" on %I.%I;', :'tbl_name', :'schema_name', :'tbl_name');
select format('  drop function %I."%s_migr_f"();',:'schema_name',:'tbl_name');
select 'COMMIT;';
select '\timing off';
select 'select now()-:''start_time''::timestamp as total_elapsed;';
select $$select 'If using connection pooler you may need to perform reconnect since table definition was changed and the cached plan result type may also have changed.' as "Notice";$$;
select $$select 'Please check the result before proceeding to step 5.' as "Notice";$$;
\o
\echo 'Created ':'fname' - Change columns

--Step 5. The final step: generating the file should only occur after the first 4 steps have been completed.
--It is recommended to perform a reconnect for the bouncers
--\echo 'If using connection pooler then you will may need to perform reconnect there since table definition was changed and the cached plan result type may have changed.'

--Remove related to the old field indexes.
select format('migr_%s_step_5.sql',:'tbl_name') as fname \gset
\out ./:fname
select '\set schema_name '||:'schema_name';
select '\set tbl_name '||:'tbl_name';
select '\set col_name '||:'col_name';
select '\set old_colname '||:'old_colname'||E'\n';

select $$select format('%I.%I',:'schema_name',:'tbl_name') as res \gset$$;
select $$\pset pager on$$;
select $$\d+ :res$$;
select $$\pset pager off$$;

select '\pset format unaligned';
select '\pset tuples_only on';

select $$select '--Check the list of indexes to be deleted and execute the commands' as "Notice";$$||E'\n';
--select '';

select $$select pgc.oid as oid from pg_class pgc inner join pg_namespace pgn on pgc.relnamespace = pgn.oid WHERE relname=:'tbl_name' and pgn.nspname=:'schema_name' \gset$$;
select $$select 'drop index concurrently "'||schemaname||'"."'||indexname||'";'
from pg_indexes
where schemaname=:'schema_name' and tablename=:'tbl_name' and (indexdef like '%('||:'old_colname'||'%' or indexdef like '%'||:'old_colname'||',%' or indexdef like '%'||:'old_colname'||')%' or
indexdef like '%("'||:'old_colname'||'%' or indexdef like '%"'||:'old_colname'||'",%' or indexdef like '%'||:'old_colname'||'")%');$$;
select '';

select 'select $$alter index '||quote_ident(:'schema_name')||'.'||quote_ident(md5_idx_name)||' rename to '||quote_ident(relname)||';$$;' from idx_name_tmp where md5_idx_name != :'new_pk_idx';

--Remove the old field
select $$select 'SET statement_timeout to ''1000ms'';';$$;
select $$select format('alter table %I.%I drop column %I;', :'schema_name', :'tbl_name', :'old_colname');$$;
select $$select 'reset statement_timeout;';$$;
--Validate constraints
select $$SELECT format('alter table %I.%I validate constraint %I;',:'schema_name',:'tbl_name',r.conname) as new_def2
FROM pg_catalog.pg_constraint r
WHERE r.conrelid = :oid AND r.contype in ('c')
and pg_catalog.pg_get_constraintdef(r.oid, true) like '% NOT VALID%'
and (pg_catalog.pg_get_constraintdef(r.oid, true) like '%('||quote_ident(:'col_name')||' %' or
     pg_catalog.pg_get_constraintdef(r.oid, true) like '% '||quote_ident(:'col_name')||' %' or
     pg_catalog.pg_get_constraintdef(r.oid, true) like '% '||quote_ident(:'col_name')||')%');$$;
select coalesce((select 'alter table '||relname||' validate constraint '||quote_ident(fk_name)||';' from fk_names_tmp where type = 2),'') as res \gset
\qecho select :'res' ;

select $$select '--Information about table:' as "Notice";$$||E'\n';
--Information about table:
select $$select '\pset format aligned';$$;
select $$select '\pset tuples_only off';$$;
select $m$ select $$select 
  case 
	when reltuples <= 0 then 0
  else 
	  (reltuples/relpages*pg_relation_size(pg_class.oid)/(select current_setting('block_size'))::int)::int 
  end as n_live_tuple,
  relpages as n_pages,
  pg_size_pretty(pg_relation_size(pg_class.oid)) as tbl_size,
  pg_size_pretty(pg_indexes_size(pg_class.oid)) as indexes_size,
  pg_size_pretty(pg_total_relation_size(pg_class.oid)) as total_size
from pg_class
where oid = $$||:oid||';'; $m$;

select $m$ select $$select pgc.relname as index_name, pg_size_pretty(pg_relation_size(indexrelid)) index_size from pg_index pgi inner join pg_class pgc on pgi.indexrelid = pgc.oid where pgi.indrelid = $$||:oid||';'; $m$;
\o
\echo 'Created ':'fname' - Create commands for delete obsolete column and indexes
--Finish procedure
\pset format aligned
\pset tuples_only off

