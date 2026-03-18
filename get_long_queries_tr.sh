#!/bin/bash
#Example: get_long_queries_tr.sh postgresql-$(date -d '-0 day' +%Y-%m-%d).log >> out.txt

logfile="$1"
maxlen=10000

if [[ -z "$logfile" || ! -f "$logfile" ]]; then  
  echo "Usage: $0 <postgresql_log_file>" >&2  
  exit 1  
fi

awk -v maxlen="$maxlen" '
BEGIN{
    collecting=0
    block=""
}

# новая запись лога
$1 ~ /^[0-9]{4}-[0-9]{2}-[0-9]{2}$/ {

    if (collecting) {

        if (length(block) > maxlen)
            block = substr(block,1,maxlen) "\n\n-- QUERY TRUNCATED TO " maxlen " CHARACTERS --\n"

        print block "\n------------------------\n"
    }

    collecting=0
    block=""
}

# duration >= 10000 ms
/duration: [1-9][0-9]{4,}\.[0-9]+ ms/ {
    collecting=1
    block=$0 ORS
    next
}

collecting {
    block = block $0 ORS
}

END{
    if (collecting) {

        if (length(block) > maxlen)
            block = substr(block,1,maxlen) "\n\n-- QUERY TRUNCATED TO " maxlen " CHARACTERS --\n"

        print block "\n------------------------\n"
    }
}
' "$logfile"
