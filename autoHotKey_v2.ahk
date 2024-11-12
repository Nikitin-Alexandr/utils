; for 2.x version AHK
Alt & 1::{
	old_clip := ClipboardAll()
	A_Clipboard := "\i ~/stuff/sql/db_activity9.6.sql"
	Send "+{Ins}{Enter}"
	Sleep 500
	A_Clipboard := old_clip
}
Exit

Alt & 2::{
	old_clip := ClipboardAll()
	A_Clipboard :="select pg_is_in_recovery();"
	Send "+{Ins}{Enter}"
	Sleep 500
	A_Clipboard := old_clip
}
Exit

^2::{
	old_clip := ClipboardAll()
	A_Clipboard := "SELECT client_addr AS client, usename AS user, application_name AS name, state, sync_state AS mode, backend_xmin, (pg_wal_lsn_diff(CASE WHEN pg_is_in_recovery() THEN pg_last_wal_replay_lsn() ELSE pg_current_wal_lsn() END,sent_lsn)/1024.0/1024)::numeric(10,1) AS pending_mb , (pg_wal_lsn_diff(sent_lsn,write_lsn)/1024.0/1024)::numeric(10,1) AS write_mb , (pg_wal_lsn_diff(write_lsn,flush_lsn)/1024.0/1024)::numeric(10,1) AS flush_mb , (pg_wal_lsn_diff(flush_lsn,replay_lsn)/1024.0/1024)::numeric(10,1) AS replay_mb , ((pg_wal_lsn_diff(CASE WHEN pg_is_in_recovery() THEN sent_lsn ELSE pg_current_wal_lsn() END,replay_lsn))::bigint/1024.0/1024)::numeric(10,1) AS total_mb , replay_lag::interval(0) replay_lag FROM pg_stat_replication;"
	Send "+{Ins}{Enter}"
	Sleep 500
	A_Clipboard := old_clip
}
Exit

Alt & 3::{
	old_clip := ClipboardAll()
	A_Clipboard :="\i ~/stuff/sql/locktree.sql"
	Send "+{Ins}{Enter}"
	Sleep 500
	A_Clipboard := old_clip
}
Exit

Alt & 4::{
	old_clip := ClipboardAll()
	A_Clipboard := "sudo -iu postgres"
	Send "+{Ins}{Enter}"
	Sleep 500
	A_Clipboard := old_clip
}
Exit

^4::{
	old_clip := ClipboardAll()
	A_Clipboard :="sudo -iu ubackup"
	Send "+{Ins}{Enter}"
	Sleep 500
	A_Clipboard := old_clip
}
Exit

Alt & 5::{
	old_clip := ClipboardAll()
	A_Clipboard :="begin; set idle_in_transaction_session_timeout='10s'; explain (analyze, buffers)   rollback;"
	Send "+{Ins}{Left 11}"
	Sleep 500
	A_Clipboard := old_clip
}
Exit

^5::{
	old_clip := ClipboardAll()
	A_Clipboard :="explain (analyze, buffers)"
	Send "+{Ins}{Space}"
	Sleep 500
	A_Clipboard := old_clip
}
Exit

Alt & 6::{
	old_clip := ClipboardAll()
	A_Clipboard :="select * from pg_stats where tablename = '' and attname = '' \gx"
	Send "+{Ins}{Left 22}"
	Sleep 500
	A_Clipboard := old_clip
}
Exit

Alt & 7::{
	old_clip := ClipboardAll()
	A_Clipboard :="cd /var/log/postgresql && ls"
	Send "+{Ins}{Enter}"
	Sleep 500
	A_Clipboard := old_clip
}
Exit

Alt & 8::{
	old_clip := ClipboardAll()
	A_Clipboard :="systemctl list-units -t service --all|grep postgres"
	Send "+{Ins}{Enter}"
	Sleep 500
	A_Clipboard := old_clip
}
Exit
