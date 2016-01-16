#!/bin/bash
IGNOREDATABASESTRING="information_schema mysql performance_schema";

while getopts "p:u:c:i:" opt; do
  case $opt in
    p)
      MYSQL_PASS="-p$OPTARG"
      ;;
    u)
      MYSQL_USER="-u$OPTARG"
      ;;
    c)
      TARGET_CHARSET=$OPTARG
      ;;
    i)
      IGNOREDATABASESTRING="$IGNOREDATABASESTRING $OPTARG"
      ;;
    \?)
      echo "Invalid option: -$OPTARG" >&2
      ;;
  esac
done

function usage {
    echo "Usage $0 -u mysql_user -p mysql_password -c target_character_set [ -i ignore_databases ]"
    exit
}

if [ -z "$MYSQL_PASS" -o -z "$MYSQL_USER" -o -z "$TARGET_CHARSET" ];
then
    usage
fi

MYSQL="mysql --skip-column-names --batch $MYSQL_USER $MYSQL_PASS"
DATADIR=$($MYSQL -e "show variables like 'datadir'" 2>/dev/null | awk '{ print $2 }')
RANDOM_PREFIX="$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 10 | head -n 1)_"

i=0;
for database in $IGNOREDATABASESTRING;
do
    i=$i+1;
    IGNOREDATABASES[$i]=$database;
done;

i=0;
#oldIFS=$IFS; IFS=$'\n';
for database in $($MYSQL -e "show databases" 2>/dev/null);
do
    skip=
    for ignore in ${IGNOREDATABASES[@]};
    do
        [[ $ignore == $database ]] && { skip=1; break; }
    done;
    if [ -z "$skip" ];
    then
        i=$i+1;
        DATABASES[$i]=$database;
    fi
done
#IFS=$oldIFS;

if [ ${#DATABASES[@]} -eq 0 ]; then
    echo "No databases"
    exit;
fi

for database in ${DATABASES[@]};
do
    echo "Fixing database" $database
    tmp_database="$RANDOM_PREFIX$database"

    echo "Create temporary database" $tmp_database
    $MYSQL -e "create database \`$tmp_database\`" 2>/dev/null
    for table in $($MYSQL $database -e "show tables" 2>/dev/null);
    do
        echo -n "  Create and fix copy of $database.$table... ";
        $MYSQL $tmp_database -e "create table \`$table\` like \`$database\`.\`$table\`" 2>/dev/null

        COLUMNS="SELECT group_concat(concat('modify \`',column_name,'\` ',column_type, ' character set $TARGET_CHARSET',' default ', if(column_default is null, 'null', concat('\"',column_default,'\"')))) FROM information_schema.COLUMNS WHERE table_schema = '$tmp_database' AND table_name = '$table' and character_set_name != '$TARGET_CHARSET' and character_set_name != '';"
        MODIFIES=$($MYSQL -e "$COLUMNS" 2>/dev/null)
        if [[ $MODIFIES == "NULL" ]];
        then
            ALTER="alter table \`$table\` DEFAULT CHARACTER SET $TARGET_CHARSET";
        else
            ALTER="alter table \`$table\` DEFAULT CHARACTER SET $TARGET_CHARSET, $MODIFIES";
        fi

        $MYSQL $tmp_database -e "$ALTER" 2>/dev/null
        echo "DONE"
    done
    echo ""
done

echo -n "Stopping MYSQL... "
sudo service mysql stop
echo "DONE"; echo ""

echo "Copying fixed .frm files... "
for database in ${DATABASES[@]};
do
    tmp_database="$RANDOM_PREFIX$database"

    for file in $DATADIR$tmp_database/*.frm;
    do
        filename=$(basename $file)
        echo "  $database/$filename"
        #cp $DATADIR$tmp_database/$filename $DATADIR$database/$filename
    done
done

echo

echo -n "Starting MYSQL... "
sudo service mysql start
echo "DONE"; echo ""

for database in ${DATABASES[@]};
do
    tmp_database="$RANDOM_PREFIX$database"

    echo "Drop temporary database" $tmp_database
    $MYSQL -e "drop database \`$tmp_database\`" 2>/dev/null
done
