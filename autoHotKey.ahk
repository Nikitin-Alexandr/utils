SendMode Input  ; Recommended for new scripts due to its superior speed and reliability.

Alt & 1::
temp := clipboard
clipboard := "\i ~/stuff/sql/db_activity9.6.sql"
Send, +{Ins}{Enter}
clipboard := temp
return

Alt & 2::
temp := clipboard
clipboard :="select pg_is_in_recovery();"
Send, +{Ins}{Enter}
clipboard := temp
return

^2::
temp := clipboard
clipboard := "SELECT client_addr AS client , usename AS user , application_name AS name , state, sync_state AS mode, backend_xmin , (pg_wal_lsn_diff(CASE WHEN pg_is_in_recovery() THEN pg_last_wal_replay_lsn() ELSE pg_current_wal_lsn() END,sent_lsn)/1024.0/1024)::numeric(10,1) AS pending_mb , (pg_wal_lsn_diff(sent_lsn,write_lsn)/1024.0/1024)::numeric(10,1) AS write_mb , (pg_wal_lsn_diff(write_lsn,flush_lsn)/1024.0/1024)::numeric(10,1) AS flush_mb , (pg_wal_lsn_diff(flush_lsn,replay_lsn)/1024.0/1024)::numeric(10,1) AS replay_mb , ((pg_wal_lsn_diff(CASE WHEN pg_is_in_recovery() THEN sent_lsn ELSE pg_current_wal_lsn() END,replay_lsn))::bigint/1024.0/1024)::numeric(10,1) AS total_mb , replay_lag::interval(0) replay_lag FROM pg_stat_replication;"
Send, +{Ins}{Enter}
clipboard := temp
return


Alt & 3::
temp := clipboard
clipboard :="\i ~/stuff/sql/locktree.sql"
Send, +{Ins}{Enter}
clipboard := temp
return

Alt & 4::
temp := clipboard
clipboard := "sudo -iu postgres"
Send, +{Ins}{Enter}
clipboard := temp
return

^4::
temp := clipboard
clipboard :="sudo -iu ubackup"
Send, +{Ins}{Enter}
clipboard := temp
return

Alt & 5::
temp := clipboard
clipboard :="begin; set idle_in_transaction_session_timeout='10s'; explain (analyze, buffers)   rollback;"
Send, +{Ins}{Left 11}
clipboard := temp
return

^5::
temp := clipboard
clipboard :="explain (analyze, buffers)"
Send, +{Ins}{Space}
clipboard := temp
return

Alt & 6::
temp := clipboard
clipboard :="select * from pg_stats where tablename = '' and attname = '' \gx"
Send, +{Ins}{Left 22}
clipboard := temp
return

Alt & 7::
temp := clipboard
clipboard :="cd /var/log/postgresql"
Send, +{Ins}{Enter}
clipboard :="ls"
Send, +{Ins}{Enter}
clipboard := temp
return

Alt & 8::
temp := clipboard
clipboard :="systemctl list-units -t service --all|grep postgres"
Send, +{Ins}{Enter}
clipboard := temp
return
