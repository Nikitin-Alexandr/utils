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
echo 'Prepare:'
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
    fi
done

echo 'PGBouncers:'
PGBOUNCER_COUNT=$(pgrep -cx pgbouncer)
if [ "$PGBOUNCER_COUNT" -eq 0 ]; then
	echo 'There are no running pgbouncers'
	#План на случай отсутствия баунсеров
elif [ "$PGBOUNCER_COUNT" -eq 1 ]; then
	echo 'One pgbouncer has been launched'
	#План на случай одного баунсера
else
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
for VERSION in "${VERSIONS[@]}"; do
	#Для найденных PostgreSQL формируем команды загрузки обновленной версии
	#По идее сюда надо вставить чекпоинты что-то типа psql -p PORT -c 'checkpoint'
	#А также вставить проверку длительных транзакций
	if [ "$IS_DEBIAN" -eq 0 ]; then
		echo 'sudo NEEDRESTART_MODE=l apt-get install --only-upgrade postgresql'-"$VERSION"
		echo 'sudo apt install postgresql-client'-"$VERSION"
	else
		echo 'systemctl mask postgresql'-"$VERSION"
		echo 'dnf install postgresql'-"$VERSION"
		echo 'systemctl unmask postgresql'-"$VERSION"
	fi
done

echo "psql -c 'select version()'"
echo "check logs"
echo "psql -c 'select * from pg_stat_activity'"

if [ "$IS_DEBIAN" -eq 0 ]; then
	echo 'rm /usr/sbin/policy-rc.d'	
fi	
