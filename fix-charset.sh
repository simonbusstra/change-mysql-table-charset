#!/bin/bash
IGNOREDATABASESTRING="information_schema mysql performance_schema";

while getopts "p:u:c:" opt; do
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
    \?)
      echo "Invalid option: -$OPTARG" >&2
      ;;
  esac
done

MYSQL="mysql --skip-column-names --batch $MYSQL_USER $MYSQL_PASS"
DATADIR=$($MYSQL -e "show variables like 'datadir'" 2>/dev/null | awk '{ print $2 }')

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

for database in ${DATABASES[@]};
do
    echo "Fixing database" $database
    tmp_database="_fix_charset_$database"

    echo "Create database" $tmp_database
    $MYSQL -e "create database \`$tmp_database\`" 2>/dev/null
    for table in $($MYSQL $database -e "show tables" 2>/dev/null);
    do
        echo -n "Create $tmp_database.$table... ";
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
done

echo -n "Stopping MYSQL... "
sudo service mysql stop
echo "DONE"

for database in ${DATABASES[@]};
do
    echo "Fixing database" $database
    tmp_database="_fix_charset_$database"

    echo "Copying fixed .frm files... "
    for file in $(ls -1 $DATADIR$tmp_database/*.frm);
    do
        filename=$(basename $file)
        echo -n " " $filename
        #cp $DATADIR$tmp_database/$filename $DATADIR$database/$filename
    done
    echo "DONE"
done


echo -n "Starting MYSQL... "
sudo service mysql start
echo "DONE"

for database in ${DATABASES[@]};
do
    tmp_database="_fix_charset_$database"

    echo "Drop database" $tmp_database
    $MYSQL -e "drop database \`$tmp_database\`" 2>/dev/null
done
