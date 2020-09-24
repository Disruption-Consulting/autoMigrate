#!/bin/bash

SCRIPT=$(basename $0); FN="${SCRIPT%.*}"; LOGFILE=${FN}.log; SQLFILE=${FN}.sql; CD=$(pwd)

exec > >(tee ${LOGFILE}) 2>&1

upper() {
    local UPPER=$(echo "${1}" | tr '[:lower:]' '[:upper:]')
    echo ${UPPER}
}

password() {
    local PW=$(cat /dev/urandom | tr -cd "a-zA-Z0-9@#%^*()_+?><~\`;'" | head -c 10)
    echo \"${PW}\"
}

version() {
    local a b c d V="$@"
    IFS=. read -r a b c d <<< "${V}"
    echo "$((a * 10 ** 3 + b * 10 ** 2 + c * 10 + d))"
}

log() {
    echo -e "${1//?/${2:-=}}\n$1\n${1//?/${2:-=}}";
}


chkerr() {
    [[ "$1" != 0 ]] && { echo -n "ERROR at line ${2}: "; echo "${3}"; exit 1; }
}

runsql() {
    local OPTIND
    local SQL
    local CONNECT="CONNECT / AS SYSDBA"
    local RETVAL=FALSE
    local SILENT
    
    while getopts "c:s:v" o; do
        case "${o}" in
            c) CONNECT="CONNECT ${OPTARG}" ;;
            s) SQL=${OPTARG} ;;
            v) RETVAL=TRUE ;;
        esac
    done
    
    if [ -n "${SQL}" ]; then
        echo -e "${CONNECT}\n${SQL}">${SQLFILE}
    fi
    
    if [ "${RETVAL}" = "FALSE" ]; then
        echo -e "WHENEVER SQLERROR EXIT FAILURE\nSET ECHO ON\n$(cat ${SQLFILE})\nCOMMIT;\nEXIT" > ${SQLFILE}
    else
        echo -e "WHENEVER SQLERROR EXIT FAILURE\nSET PAGESIZE 0 FEEDBACK OFF VERIFY OFF HEADING OFF ECHO OFF\n$(cat ${SQLFILE})\nCOMMIT;\nEXIT" > ${SQLFILE}
        SILENT="-silent"
    fi    
    
    sqlplus ${SILENT} /nolog @${SQLFILE} || { return 1; }
}


createWallet() {
    log "createWallet - ${WALLET}"
    
    local WPW=$(password)
    mkstore -wrl "${WALLET}" -create<<-EOF
${WPW}
${WPW}
EOF
    chkerr "$?" "${LINENO}" "${VERSION}"
    
    runsql -s "INSERT INTO ${USER}.migration_log(id, name, log_message) VALUES (${USER}.migration_log_seq.nextval,'WPW','${WPW}');"
    chkerr "$?" "${LINENO}" "${VERSION}"
    
    local EXISTS=$(grep "^WALLET_LOCATION" "${SQLNET}"|wc -l)
    if [ "${EXISTS}" = "0" ]; then
        cat <<-EOF>${SQLNET}
WALLET_LOCATION =
   (SOURCE =
     (METHOD = FILE)
     (METHOD_DATA =
       (DIRECTORY = ${WALLET})
     )
   )
SQLNET.WALLET_OVERRIDE = TRUE
EOF
    fi
}

createCredential() {
    log "createCredential - ${1} ${2}"
    
    local TNS=${1}
    local USR=${2}
    local PWD=${3}
    
    local WPW=$(runsql -v -s "SELECT log_message FROM ${USER}.migration_log WHERE name='WPW';")
    chkerr "$?" "${LINENO}" "${VERSION}"
    
    mkstore -wrl "${WALLET}" -createCredential "${TNS}" "${USR}" "${PWD}"<<EOF
${WPW}
EOF

    local EXISTS=$(grep "^${TNS}" "${TNSNAMES}"|wc -l)
    if [ "${EXISTS}" = "0" ]; then
        local SERVICE=$(runsql -v -s "SELECT ${USER}.pck_migration_src.getdefaultservicename FROM dual;")
        
        cat <<-EOF>>${TNSNAMES}
${TNS}=(DESCRIPTION=(ADDRESS=(PROTOCOL=TCP)(HOST=localhost)(PORT=1521))(CONNECT_DATA=(SERVER=DEDICATED)(SERVICE_NAME=${SERVICE})))
EOF
    fi
}

removeSource() {
    log "removeSource"
    
    cat <<-EOF>${SQLFILE}
        CONNECT / AS SYSDBA
        SET SERVEROUTPUT ON
        WHENEVER SQLERROR CONTINUE
        EXEC ${USER}.pck_migration_src.set_ts_readwrite
        DROP USER ${USER} CASCADE;
        WHENEVER SQLERROR EXIT FAILURE
        DECLARE
            PROCEDURE exec(pCommand IN VARCHAR2) IS
            BEGIN
                dbms_output.put(pCommand);
                EXECUTE IMMEDIATE pCommand;
                dbms_output.put_line(' ..OK');
                EXCEPTION WHEN OTHERS THEN
                    dbms_output.put_line(' ..FAILED');
                    RAISE;
            END;
        BEGIN
            FOR C IN (SELECT directory_name FROM dba_directories WHERE REGEXP_LIKE(directory_name,'MIGRATION_FILES_[1-9]+_DIR')) LOOP
                exec('DROP DIRECTORY '||C.directory_name);
            END LOOP;
        END;
        /
EOF
    runsql || { echo "SQL FAILED"; exit 1; }
    
    local RMANFILE="${CD}/${FN}.rman"
    cat <<-EOF>${RMANFILE}
        CONNECT TARGET /
        DELETE NOPROMPT COPY TAG='INCR-TS'; 
        DELETE NOPROMPT BACKUP TAG='INCR-TS';
        EXIT
EOF
    rman cmdfile="${RMANFILE}" || { echo "RMAN DELETE BACKUPS FAILED"; exit 1; }
    
    if [ -d "${WALLET}" ]; then
        log "mv ${WALLET} .. in preference to rm"
        mv "${WALLET}" "${WALLET}_TOBEDELETED"
    fi
}


createSourceSchema(){
    log "createSourceSchema"
    
    local PW=$(password)
    local V11=$(version "11")
    local V12=$(version "12")
    local PRIV
    
    [[ ${VTHIS} < ${V11} ]] && PRIV=EXP_FULL_DATABASE || PRIV=DATAPUMP_EXP_FULL_DATABASE

    cat <<-EOF>${SQLFILE}
        CONNECT / AS SYSDBA
        CREATE USER MIGRATION IDENTIFIED BY ${PW} DEFAULT TABLESPACE SYSTEM QUOTA 10M ON SYSTEM;
        GRANT SELECT ANY DICTIONARY,
              CREATE SESSION,
              ALTER TABLESPACE,
              CREATE ANY DIRECTORY,
              DROP ANY DIRECTORY,
              CREATE ANY JOB,
              MANAGE SCHEDULER,
              ${PRIV} TO ${USER};
        GRANT EXECUTE ON SYS.DBMS_BACKUP_RESTORE TO ${USER};
        GRANT EXECUTE ON SYS.DBMS_SYSTEM TO ${USER};
        GRANT EXECUTE ON SYS.DBMS_CRYPTO TO ${USER};
        
        ALTER SESSION SET CURRENT_SCHEMA=${USER};
        CREATE OR REPLACE VIEW V_APP_TABLESPACES AS
          SELECT tablespace_name, status, file_id, SUBSTR(file_name,1,pos-1) directory_name, SUBSTR(file_name,pos+1) file_name, enabled, bytes
          FROM
            (
             SELECT t.tablespace_name, t.status, f.file_id, f.file_name,INSTR(f.file_name,'/',-1) pos, f.bytes, v.enabled
               FROM dba_tablespaces t, dba_data_files f, v\$datafile v
              WHERE t.tablespace_name=f.tablespace_name
                AND v.file#=f.file_id
                AND t.contents='PERMANENT'
                AND t.tablespace_name NOT IN ('SYSTEM','SYSAUX')
            );
            
        CREATE TABLE migration_ts(
                    file# NUMBER,
                    bytes NUMBER,
                    enabled VARCHAR2(10),
                    from_scn NUMBER,
                    tablespace_name VARCHAR2(30),
                    pre_migr_status VARCHAR2(10),
                    created DATE DEFAULT SYSDATE,
                    updated DATE,
                    transferred DATE,
                    applied DATE,
                    CONSTRAINT pk_migration_ts PRIMARY KEY(file#));
                    
        CREATE SEQUENCE migration_log_seq START WITH 1 INCREMENT BY 1;

        CREATE TABLE migration_log(
    			 id NUMBER,
                 name VARCHAR2(10),
    			 log_time DATE DEFAULT SYSDATE,
    			 log_message CLOB,
    			 CONSTRAINT PK_MIGRATION_LOG PRIMARY KEY(id));
                 
        INSERT INTO migration_log(id, name, log_message) VALUES (migration_log_seq.nextval,'PW','${PW}');
        COMMIT;
EOF

    if [[ ${VTHIS} < ${V12} ]]; then
        cat <<-EOF>>${SQLFILE}
            GRANT SELECT ON SYS.KU_NOEXP_TAB  TO ${USER};
            GRANT SELECT ON SYSTEM.LOGSTDBY\$SKIP_SUPPORT TO ${USER};    
            CREATE OR REPLACE VIEW V_MIGRATION_USERS AS
              WITH u AS
              (
                SELECT username,no_expdp,no_sby
                FROM dba_users
                LEFT OUTER JOIN (SELECT DISTINCT name username,'Y' no_expdp FROM sys.ku_noexp_tab WHERE obj_type='SCHEMA')
                 USING(username)
                LEFT OUTER JOIN (SELECT DISTINCT name username,'Y' no_sby FROM system.logstdby\$skip_support WHERE action IN (0,-1))
                 USING(username)
              )
              SELECT username, DECODE(COALESCE(no_expdp,no_sby),NULL,'N','Y') oracle_maintained
              FROM u
              WHERE username<>'${USER}';
EOF
    else
        cat <<-EOF>>${SQLFILE}
            CREATE OR REPLACE VIEW V_MIGRATION_USERS AS SELECT username, oracle_maintained FROM dba_users;
EOF
    fi
    
    cat <<-EOF>>${SQLFILE}
    PROMPT "COMPILING PCK_MIGRATION_SRC"
    set echo off
    @@pck_migration_src.sql
    set echo on
    show errors
    BEGIN
        EXECUTE IMMEDIATE 'ALTER PACKAGE PCK_MIGRATION_SRC COMPILE';
        EXCEPTION WHEN OTHERS THEN RAISE_APPLICATION_ERROR(-20000,'COMPILE FAILED');
    END;
    /
EOF
    
    runsql || { echo "createSourceSchema FAILED"; exit 1; }
    
    [[ ! -d "${WALLET}" ]] && createWallet
    
    createCredential "${USER}" "${USER}" "${PW}"
}


runSourceMigration() {
    log "runSourceMigration"
    
    local IP=$(hostname -I)
    cat <<-EOF>${SQLFILE}
    CONNECT /@${USER}
    SET SERVEROUTPUT ON
    SET LINESIZE 300
    BEGIN
        pck_migration_src.init_migration(
            p_ip_address=>'${IP}',
            p_run_mode=>'${MODE}', 
            p_incr_ts_dir=>'${BKPDIR}', 
            p_incr_ts_freq=>'${BKPFREQ}');
    END;
    /
EOF
    runsql
}

processSource() {
    
    local MSG=
    [[ ! "${MODE}" =~ (^ANALYZE|EXECUTE|INCR$) ]] && MSG="-m <MODE> MUST BE ONE OF [ANALYZE|EXECUTE|INCR]. DEFAULT IS ANALYZE."
    
    [[ "${MODE}" = "INCR"  &&  -z "${BKPDIR}" ]] && MSG="-b <BKPDIR> MUST BE SPECIFIED FOR -m INCR"
    
    [[ "${MODE}" != "INCR"  &&  (-n "${BKPDIR}" || -n "${BKPFREQ}") ]] && MSG="-b <BKPDIR> AND -f <BKPFREQ> ONLY RELEVANT FOR -m INCR"
    
    if [ -n "${MSG}" ]; then
        echo "${MSG}"
        exit 1
    fi
    
    if [ "${REMOVE}" = "TRUE" ]; then
        removeSource
        exit 0
    fi
    
    local EXISTS=$(runsql -v -s "SELECT TO_CHAR(COUNT(*)) FROM dual WHERE EXISTS (SELECT 1 FROM dba_users WHERE username='${USER}');")
    chkerr "$?" "${LINENO}" "${EXISTS}"
    
    [[ "${EXISTS}" = "0" ]] && createSourceSchema || runSourceMigration
}


processTarget() {
    echo "processTarget"
}



##########################
#   SCRIPT STARTS HERE   #
##########################

VERSION=$(runsql -v -s "SELECT MAX(REGEXP_SUBSTR(banner,'\d+.\d+.\d+.\d+')) FROM v\$version;")
chkerr "$?" "${LINENO}" "${VERSION}"

VTHIS=$(version "${VERSION}")

[[ ${VERSION} = 19* ]] && DB=TARGET || DB=SOURCE

export TNS_ADMIN="${CD}"
WALLET="${TNS_ADMIN}/wallet"
TNSNAMES="${TNS_ADMIN}/tnsnames.ora"
SQLNET="${TNS_ADMIN}/sqlnet.ora"

[[ ! -f "${TNSNAMES}" ]] && cat /dev/null>"${TNSNAMES}"
[[ ! -f "${SQLNET}" ]] && cat /dev/null>"${SQLNET}"



if [ "${DB}" = "SOURCE" ]; then
    MODE=ANALYZE
    USER=MIGRATION
    REMOVE=FALSE
    while getopts "m:u:b:f:r" o; do
        case "${o}" in
            m) MODE=$(upper ${OPTARG}) ;;
            u) USER=${OPTARG} ;;
            b) BKPDIR=${OPTARG} ;;
            f) BKPFREQ=${OPTARG} ;;
            r) REMOVE=TRUE ;;
        esac
    done
    processSource
fi

exit