#!/usr/bin/env bash
# Example: ./analyze_slow_queries.sh /var/log/postrgesql/postgresql-$(date +%F).log

# Output:
#COUNT    AVG(ms)      MAX(ms)      QUERY
#34       15432.55     42111.22     SELECT * FROM users WHERE id=?
#12       14322.11     21122.33     UPDATE orders SET status=? WHERE id=?
#8        12011.33     19011.55     SELECT * FROM payments WHERE user_id=?

logfile="$1"

if [[ -z "$logfile" || ! -f "$logfile" ]]; then
    echo "Usage: $0 <postgres_log>" >&2
    exit 1
fi

printf "%-8s %-12s %-12s %s\n" "COUNT" "AVG(ms)" "MAX(ms)" "QUERY"

grep -E "duration: [1-9][0-9]{4,}\.[0-9]+ ms" "$logfile" |
awk '

function normalize(q) {

    gsub(/\047[^\047]*\047/, "?", q)   # строки
    gsub(/[0-9]+/, "?", q)             # числа
    gsub(/[[:space:]]+/, " ", q)       # пробелы
    gsub(/\([^\)]*\)/, "(?)", q)       # длинные строки IN (...)
    return q
}

{
    match($0, /duration: ([0-9]+\.[0-9]+)/, d)
    duration = d[1]

    query=$0
    sub(/.*statement: /,"",query)

    query = normalize(query)

    count[query]++
    total[query]+=duration

    if (duration > max[query])
        max[query]=duration
}

END{

    for (q in count) {

        avg = total[q]/count[q]

        printf "%-8d %-12.2f %-12.2f %s\n",
            count[q], avg, max[q], q
    }
}
' |
sort -k3 -nr |
head -20

