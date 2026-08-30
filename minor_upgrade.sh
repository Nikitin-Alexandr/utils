#!/bin/bash
# Получаем тип OS
IS_DEBIAN=0
if [ -f /etc/os-release ]; then
    . /etc/os-release
    case "$ID" in
        debian|ubuntu|linuxmint)
            ;;
        rhel|centos|fedora|rocky|almalinux|ol)
            IS_DEBIAN=1
            ;;
        *)
            echo "Unknown: $ID"
            ;;
    esac
else
    echo "/etc/os-release not found"
	IS_DEBIAN=2
fi

if [ $IS_DEBIAN -eq 2 ]; then
    echo "Unknown OS"
    exit 1
fi

# Получаем номера версий запущенных PostgreSQL
#echo 'Prepare:'
VERSIONS=()
for pid in $(pgrep -f "(postgres|postmaster).*-D"); do
    DATA_DIR=$(ps -p "$pid" -o cmd= | grep -oP '(?<=-D )\S+')
    if [ -f "$DATA_DIR/PG_VERSION" ]; then
		VERSIONS+=("$(cat "$DATA_DIR/PG_VERSION")")
    fi
done

# Убираем дубликаты - к примеру у нас есть несколько запущенных экземпляров одной и той же версии
VERSIONS=($(printf '%s\n' "${VERSIONS[@]}" | sort -u))

if [ ${#VERSIONS[@]} -eq 0 ]; then
    echo "Нет запущенных PostgreSQL"
    exit 1
fi

if [ "$IS_DEBIAN" -eq 0 ]; then
	echo 'sudo apt update'
fi	


echo 'Informataion about services:'
{ systemctl list-units --all --type=service 'pgbouncer*' 'postgresql*' 'patroni*' 'pgq*' --no-legend --plain; systemctl list-unit-files --type=service 'pgbouncer*' 'postgresql*' 'patroni*' 'pgq*' --no-legend; } | awk '!seen[$1]++ {print $1}' | while read s; do printf "%-50s enabled=%-10s active=%-10s\n" "$s" "$(systemctl is-enabled $s 2>/dev/null)" "$(systemctl is-active $s 2>/dev/null)"; done | sort -t@ -k1,1 -k2
printf '\n'

for VERSION in "${VERSIONS[@]}"; do
	#Для найденных PostgreSQL формируем команды загрузки обновленной версии
	if [ "$IS_DEBIAN" -eq 0 ]; then
		prefix='sudo apt-get install --download-only postgresql'
	else
		prefix='dnf install --downloadonly postgresql'
	fi
	echo "$prefix"-"$VERSION"
done

echo 'Postgres:'
# Проверка того, что в обнаруженных постгресах есть репликации
for pid in $(pgrep -f "(postgres|postmaster).*-D"); do
    DATA_DIR=$(ps -p "$pid" -o cmd= | grep -oP '(?<=-D )\S+')
	#echo $DATA_DIR
    if [ -f "$DATA_DIR/postmaster.pid" ]; then
		PORT=$(sed -n '4p' "$DATA_DIR/postmaster.pid")
		echo -n 'port:' $PORT $DATA_DIR
		if psql -p "$PORT" -Atqc "SELECT EXISTS (SELECT 1 FROM pg_stat_replication);" | grep -q t; then
                  echo "  Has replica(s)"
                else
                  echo "  No replicas"
                fi
                echo 'Extensions:'
                for db in $( psql -p $PORT -Xt1c 'SELECT datname FROM pg_database WHERE datallowconn ORDER BY datname;' ); do 
                  psql -d $db -p $PORT -F ' ' -XAt1c 'SELECT rpad(current_database(), 40) AS db_name, rpad(extname, 30), extversion FROM pg_extension where extname!=$$plpgsql$$ ORDER BY extname;';
                done
                printf '\n'
    fi
done

echo 'PGBouncers:'
PGBOUNCER_COUNT=$(pgrep -cx pgbouncer)
if [ "$PGBOUNCER_COUNT" -eq 0 ]; then
	echo 'There are no running pgbouncers'
	#План на случай отсутствия баунсеров
elif [ "$PGBOUNCER_COUNT" -eq 1 ]; then
	echo 'One pgbouncer has been launched'
	#План на случай одного баунсера, предполагаем, что раз уж он один, то запущен не через so_reuseport, в дальшейшем вставить проверку.
        pgrep -x pgbouncer | while read pid; do
                cmd=$(ps -p "$pid" -o cmd=)
                config_file=$(echo "$cmd" | awk '{print $NF}')
                socket=$(grep "^unix_socket_dir\b" $config_file|awk -F '=' '{print $2}')
                socket=${socket:-/tmp}
                port=`ss -tulnp4|grep pgbouncer | awk -F':' '{print $2}'|awk '{print $1}'`
                if [[ "$config_file" == *.ini ]] && [[ -f "$config_file" ]]; then
                   echo 'PID:'$pid 'PORT:'$port 'socket:' $socket
                   echo 'Commands:'
                   echo "psql -U pgbouncer --port $port -h $socket -c 'show state'"
                   echo "psql -U pgbouncer --port $port -h $socket -c 'pause'"
                   echo "psql -U pgbouncer --port $port -h $socket -c 'resume'"
                fi
        done
else
        #Тут подстава может быть такой, что у нескольких PG могут быть разные баунсеры, и обычные и so_reuseport, и мы не знаем какой баунсер за какой кластер PG отвечает 
        #Поэтому мы можем только дать рекомендации по взаимодействию с ними.
	#План на случай нескольких баунсеров (как с so_reuseport так и без него).
	pgrep -x pgbouncer | while read pid; do
		cmd=$(ps -p "$pid" -o cmd=)
		config_file=$(echo "$cmd" | awk '{print $NF}')
		socket=$(grep "^unix_socket_dir\b" $config_file|awk -F '=' '{print $2}')
		socket=${socket:-/tmp}
		port=$(ss -ltnp | awk -v pid="$pid" '
                   $0 ~ ("pid=" pid ",") {
                   split($4, a, ":")
                   print a[length(a)]
                   }
		'|uniq)
		if [[ "$config_file" == *.ini ]] && [[ -f "$config_file" ]]; then
#		    echo 'PID:'$pid 'PORT:'$port 'socket:' $socket	
                    echo 'PID:'$pid 'PORT:'$port 'SO_REUSEPORT:' `psql -A -U pgbouncer --port $port -h $socket -c 'show config'|grep so_reuseport|awk -F '|' '{print $2}'`
		fi
	done
fi

echo -e "\nUpgrade:"
if [ "$IS_DEBIAN" -eq 0 ]; then
	echo 'cat > /usr/sbin/policy-rc.d <<EOF
#!/bin/sh
echo "All runlevel operations denied by policy" >&2
exit 101
EOF
chmod +x /usr/sbin/policy-rc.d'	
fi		

# Добавляем команды на checkpoint и длительные транзакции
for pid in $(pgrep -f "(postgres|postmaster).*-D"); do
    DATA_DIR=$(ps -p "$pid" -o cmd= | grep -oP '(?<=-D )\S+')
    if [ -f "$DATA_DIR/postmaster.pid" ]; then
       PORT=$(sed -n '4p' "$DATA_DIR/postmaster.pid")
       echo 'First, on the master, then on the replicas, you need to run the following commands:'
       echo 'psql -p' $PORT -c \'checkpoint\'
       echo 'psql -p' $PORT -f ~/stuff/sql/db_activity9.6.sql
       printf '\n'
    fi
done


for VERSION in "${VERSIONS[@]}"; do
	#Для найденных PostgreSQL формируем команды загрузки обновленной версии
	if [ "$IS_DEBIAN" -eq 0 ]; then
		echo 'sudo NEEDRESTART_MODE=l apt-get install --only-upgrade postgresql'-"$VERSION"
		echo 'sudo apt install postgresql-client'-"$VERSION"
	else
		echo 'systemctl mask postgresql'-"$VERSION"
		echo 'dnf install postgresql'-"$VERSION"
		echo 'systemctl unmask postgresql'-"$VERSION"
	fi
done

printf '\n'

#Нужно добавить команды рестарта БД и в зависимости от того, есть тут баунсеры или нет, сформировать для них команды паузы и resume
if [ "$PGBOUNCER_COUNT" -ne 0 ]; then
  echo 'pgbouncer - pause'
fi

echo 'It is necessary to restart postgresql'

if [ "$PGBOUNCER_COUNT" -ne 0 ]; then
  echo 'pgbouncer - resume'
fi

printf '\n'

echo "psql -c 'select version()'"
echo "check logs"
echo "psql -c 'select * from pg_stat_activity'"

if [ "$IS_DEBIAN" -eq 0 ]; then
	echo 'rm /usr/sbin/policy-rc.d'	
fi	
