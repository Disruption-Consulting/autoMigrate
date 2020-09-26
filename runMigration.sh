#!/bin/bash

SCRIPT=$(basename $0); FN="${SCRIPT%.*}"; LOGFILE=${FN}.log; SQLFILE=${FN}.sql; CD=$(pwd)

exec > >(tee ${LOGFILE}) 2>&1

usageSource() {
    echo "Usage: $0 [ -m MODE ] [ - u USER ] [ -b BKPDIR ] [ -f BKPFREQ ]"
    exit 1
}

usageTarget() {
    echo "Usage: $0 [ -c CREDENTIAL ] [ - t TNS ] [ -p PDB ]"
    exit 1
}

upper() {
    local UPPER=$(echo "${1}" | tr '[:lower:]' '[:upper:]')
    echo ${UPPER}
}

password() {
    local PW=$(cat /dev/urandom | tr -cd "a-zA-Z0-9@#%^*()_+?><~\`;" | head -c 10)
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
    log "createCredential - ALIAS:${1} USER: ${2} SERVICE: ${4}"
    
    [[ ! -d "${WALLET}" ]] && createWallet
    
    local TNS="${1}"
    local USR="${2}"
    local PWD="${3}"
    local SVC="${4}"
    
    local WPW=$(runsql -v -s "SELECT log_message FROM ${USER}.migration_log WHERE name='WPW';")
    chkerr "$?" "${LINENO}" "${VERSION}"
    
    mkstore -wrl "${WALLET}" -createCredential "${TNS}" "${USR}" "${PWD}"<<EOF
${WPW}
EOF

    local EXISTS=$(grep "^${TNS}" "${TNSNAMES}"|wc -l)
    if [ "${EXISTS}" = "0" ]; then
        cat <<-EOF>>${TNSNAMES}
${TNS}=(DESCRIPTION=(ADDRESS=(PROTOCOL=TCP)(HOST=localhost)(PORT=1521))(CONNECT_DATA=(SERVER=DEDICATED)(SERVICE_NAME=${SVC})))
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
        CREATE USER ${USER} IDENTIFIED BY ${PW} DEFAULT TABLESPACE SYSTEM QUOTA 10M ON SYSTEM;
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
          SELECT t.tablespace_name, t.status, t.file_id, d.directory_path, d.directory_name, SUBSTR(t.file_name,pos+1) file_name, t.enabled, t.bytes
          FROM
            (
             SELECT t.tablespace_name, t.status, f.file_id, f.file_name,INSTR(f.file_name,'/',-1) pos, f.bytes, v.enabled
               FROM dba_tablespaces t, dba_data_files f, v$datafile v
              WHERE t.tablespace_name=f.tablespace_name
                AND v.file#=f.file_id
                AND t.contents='PERMANENT'
                AND t.tablespace_name NOT IN ('SYSTEM','SYSAUX')
            ) t, all_directories d
            WHERE SUBSTR(t.file_name,1,pos-1)=d.directory_path
            AND d.directory_name LIKE 'MIGRATION_FILES%';
            
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
                SELECT username,no_expdp,no_sby,no_hc
                FROM dba_users
                LEFT OUTER JOIN (SELECT DISTINCT name username,'Y' no_expdp FROM sys.ku_noexp_tab WHERE obj_type='SCHEMA')
                 USING(username)
                LEFT OUTER JOIN (SELECT DISTINCT name username,'Y' no_sby FROM system.logstdby\$skip_support WHERE action IN (0,-1))
                 USING(username)
                LEFT OUTER JOIN (SELECT column_value as username, 'Y' no_hc FROM TABLE(sys.OdciVarchar2List(
                'APEX_PUBLIC_USER', 'FLOWS_FILES', 'FLOWS_020100', 'FLOWS_030100','FLOWS_040100',
                'OWBSYS_AUDIT', 'SPATIAL_CSW_ADMIN_USR', 'SPATIAL_WFS_ADMIN_USR','TSMSYS')))
                 USING(username)
              )
              SELECT username, DECODE(COALESCE(no_expdp,no_sby,no_hc),NULL,'N','Y') oracle_maintained
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
    
    local SERVICE=$(runsql -v -s "SELECT ${USER}.pck_migration_src.getdefaultservicename FROM dual;")
    
    createCredential "${USER}" "${USER}" "${PW}" "${SERVICE}" 
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
    runsql || { echo "runSourceMigration FAILED"; exit 1; }
}


processSource() {
    log "processSource"
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



#################################
#
#    TARGET MIGRATION PROCESS
#
#################################

createCommonUser() {
    log "createCommonUser"
    
    local CPW=$(password)
    
    cat <<-EOF>${SQLFILE}
    CONNECT / AS SYSDBA
    CREATE USER ${USER} IDENTIFIED BY ${CPW} DEFAULT TABLESPACE SYSTEM QUOTA 1M ON SYSTEM;
    GRANT ALTER SESSION,
          ALTER USER,
          CREATE DATABASE LINK,
          CREATE PLUGGABLE DATABASE,
          CREATE PROCEDURE,
          CREATE SESSION,
          CREATE SYNONYM,
          CREATE TABLE,
          SET CONTAINER TO ${USER};
    GRANT SYSDBA TO ${USER} CONTAINER=ALL;
    GRANT EXECUTE ON SYS.DBMS_BACKUP_RESTORE TO ${USER};
    GRANT SELECT ON SYS.CDB_DATA_FILES TO ${USER};
    GRANT SELECT ON SYS.CDB_DIRECTORIES TO ${USER};
    GRANT SELECT ON SYS.CDB_PDBS TO ${USER};
    ALTER SESSION SET CURRENT_SCHEMA=${USER};
    CREATE SEQUENCE migration_log_seq START WITH 1 INCREMENT BY 1;
    CREATE TABLE migration_log(
             id NUMBER,
             name VARCHAR2(10),
             log_time DATE DEFAULT SYSDATE,
             log_message CLOB,
             CONSTRAINT PK_MIGRATION_LOG PRIMARY KEY(id));    
EOF
    runsql || { echo "createCommonUser FAILED"; exit 1; }
    
    createCredential "${ORACLE_SID}" "${USER}" "${CPW}" "${ORACLE_SID}" 
}

removeTarget() {
    log "removeTarget"
}


createTargetSchema() {
    log "createTargetSchema"
    
    local EXISTS=$(runsql -v -s "SELECT TO_CHAR(COUNT(*)) FROM dual WHERE EXISTS (SELECT 1 FROM dba_users WHERE username='${USER}');")
    chkerr "$?" "${LINENO}" "${EXISTS}"
    
    [[ "${EXISTS}" = "0" ]] && createCommonUser
    
    local PW=$(password)
    
    DBLINKUSR=${CRED%%/*}
    DBLINKPWD=${CRED#*/}
    
    cat <<-EOF>${SQLFILE}
        CONNECT /@${USER} AS SYSDBA
        CREATE PLUGGABLE DATABASE ${PDB} ADMIN USER PDBADMIN IDENTIFIED BY ${PW} ROLES=(DATAPUMP_IMP_FULL_DATABASE) FILE_NAME_CONVERT=('pdbseed','${PDB}');
        ALTER USER ${USER} SET CONTAINER_DATA = (CDB\$ROOT, ${PDB}) CONTAINER=CURRENT;
        ALTER SESSION SET CONTAINER=${PDB};
        ALTER PLUGGABLE DATABASE ${PDB} OPEN READ WRITE;
        ALTER PLUGGABLE DATABASE ${PDB} SAVE STATE;
        AUDIT CONNECT;
        ALTER USER PDBADMIN QUOTA UNLIMITED ON SYSTEM;
        GRANT ALTER SESSION TO PDBADMIN;
        GRANT ALTER TABLESPACE TO PDBADMIN;
        GRANT ANALYZE ANY TO PDBADMIN;
        GRANT ANALYZE ANY DICTIONARY TO PDBADMIN;
        GRANT CREATE ANY DIRECTORY TO PDBADMIN;
        GRANT CREATE JOB TO PDBADMIN;
        GRANT CREATE MATERIALIZED VIEW TO PDBADMIN;
        GRANT CREATE PROCEDURE TO PDBADMIN;
        GRANT CREATE PUBLIC DATABASE LINK TO PDBADMIN;
        GRANT CREATE SESSION TO PDBADMIN;
        GRANT CREATE TABLE TO PDBADMIN;
        GRANT CREATE TABLESPACE TO PDBADMIN;
        GRANT DROP ANY DIRECTORY TO PDBADMIN;
        GRANT DROP TABLESPACE TO PDBADMIN;
        GRANT MANAGE SCHEDULER TO PDBADMIN;
        GRANT SELECT ANY DICTIONARY TO PDBADMIN;
        GRANT EXECUTE ON SYS.DBMS_BACKUP_RESTORE TO PDBADMIN;
        GRANT EXECUTE ON SYS.DBMS_FILE_TRANSFER TO PDBADMIN;
        GRANT EXECUTE ON SYS.DBMS_SYSTEM TO PDBADMIN;
        GRANT EXECUTE ON SYS.DBMS_CRYPTO TO PDBADMIN;
        CREATE DIRECTORY MIGRATION_SCRIPT_DIR AS '${CD}';
        GRANT READ, WRITE ON DIRECTORY MIGRATION_SCRIPT_DIR TO PDBADMIN;
        COL con_id NEW_VALUE con_id noprint;
        COL filepath NEW_VALUE filepath noprint;
        SELECT SYS_CONTEXT('USERENV','CON_ID') AS con_id FROM dual;
        SELECT MAX(SUBSTR(file_name,1,INSTR(file_name,'/',-1))) AS filepath FROM cdb_data_files WHERE con_id=&con_id;
        CREATE OR REPLACE DIRECTORY TGT_FILES_DIR AS '&filepath';
        GRANT READ, WRITE ON DIRECTORY TGT_FILES_DIR TO PDBADMIN;
        CREATE TABLE PDBADMIN.migration_ts
                       ("TABLESPACE_NAME"   VARCHAR2(30),
                        "ENABLED"           VARCHAR2(20),
                        "PLATFORM_ID"       NUMBER,
                        "FILE_ID"           NUMBER,
                        "FILE_NAME"         VARCHAR2(100),
                        "DIRECTORY_NAME"    VARCHAR2(30),
                        "FILE_NAME_RENAMED" VARCHAR2(107),
                        "MIGRATION_STATUS"  VARCHAR2(50) DEFAULT 'TRANSFER NOT STARTED',
                        "START_TIME"        DATE,
                        "ELAPSED_SECONDS"   NUMBER,
                        "BYTES"             NUMBER,
                        "TRANSFERRED_BYTES" NUMBER,
                       CONSTRAINT PK_MIGRATION_TS PRIMARY KEY(FILE_ID));
        CREATE TABLE PDBADMIN.migration_bp
                       ("RECID"             NUMBER,
                        "FILE_ID"           NUMBER,
                        "BP_FILE_NAME"      VARCHAR2(100),
                        "DIRECTORY_NAME"    VARCHAR2(30),
                        "MIGRATION_STATUS"  VARCHAR2(50) DEFAULT 'TRANSFER NOT STARTED',
                        "START_TIME"        DATE,
                        "ELAPSED_SECONDS"   NUMBER,
                        "BYTES"             NUMBER,
                        "TRANSFERRED_BYTES" NUMBER,
                        CONSTRAINT pk_migration_bp PRIMARY KEY(recid),
                        CONSTRAINT fk_migration_ts FOREIGN KEY(file_id) REFERENCES PDBADMIN.migration_ts(file_id));
        CREATE SEQUENCE PDBADMIN.migration_log_seq START WITH 1 INCREMENT BY 1;
        CREATE TABLE PDBADMIN.migration_log
                       ("ID"            NUMBER DEFAULT PDBADMIN.migration_log_seq.NEXTVAL,
                        "LOG_TIME"      DATE DEFAULT SYSDATE,
                        "LOG_MESSAGE"   CLOB,
                        CONSTRAINT PK_MIGRATION_LOG PRIMARY KEY(id));
        CREATE PUBLIC DATABASE LINK MIGR_DBLINK CONNECT TO ${DBLINKUSR} IDENTIFIED BY ${DBLINKPWD} USING '${TNS}';
        PROMPT "Compiling pck_migration_tgt.sql";
        set echo off;
        @@pck_migration_tgt.sql;
        set echo on;
        show errors;
        BEGIN
            execute immediate 'alter package pdbadmin.pck_migration_tgt compile'; 
            exception when others then raise_application_error(-20000,'compilation error');
        END;
        /
        GRANT SELECT, UPDATE ON PDBADMIN.MIGRATION_TS TO ${USER} CONTAINER=CURRENT;
        GRANT SELECT, UPDATE ON PDBADMIN.MIGRATION_BP TO ${USER} CONTAINER=CURRENT;
        GRANT SELECT ON PDBADMIN.migration_log_seq TO ${USER} CONTAINER=CURRENT;
        GRANT SELECT, INSERT ON PDBADMIN.MIGRATION_LOG TO ${USER} CONTAINER=CURRENT;
        CONNECT /@${USER}
        WHENEVER SQLERROR CONTINUE
        DROP DATABASE LINK PDB_DBLINK;
        WHENEVER SQLERROR EXIT FAILURE
        CREATE DATABASE LINK PDB_DBLINK CONNECT TO PDBADMIN IDENTIFIED BY ${PW} USING '//localhost/${PDB}';
        PROMPT "Compiling pck_migration_rollforward.sql";
        set echo off;
        @@pck_migration_rollforward.sql;
        set echo on;
        show errors;
        BEGIN
            execute immediate 'alter package pck_migration_rollforward compile'; 
            exception when others then raise_application_error(-20000,'compilation error');
        END;
        /        
EOF
    runsql || { echo "createTargetSchema FAILED"; exit 1; }
    
    createCredential "${PDB}" "PDBADMIN" "${PW}" "${PDB}" 
}


runTargetMigration() {
    log "runTargetMigration"
    
    local RUNSCRIPT="${FN}.${PDB}"
    
    cat <<-EOF>${RUNSCRIPT}.sql
        whenever sqlerror exit failure
        connect /@${PDB}
        exec pck_migration_tgt.transfer
        exit
EOF

    cat /dev/null>${RUNSCRIPT}.impdp.sh
    cat /dev/null>${RUNSCRIPT}.final.sh
    
    cat <<-EOF>${RUNSCRIPT}.sh
#!/bin/bash
exec 1>${RUNSCRIPT}.log 2>&1
export ORACLE_HOME=${ORACLE_HOME}
export ORACLE_SID=${ORACLE_SID}
export PATH=\${ORACLE_HOME}/bin:${PATH}
export TNS_ADMIN=${CD}
sqlplus /nolog @${RUNSCRIPT}.sql
. /opt/oracle/oradata/migration_impdp.sh
. /opt/oracle/oradata/migration_final.sh
exit 0
EOF
}


processTarget() {
    log "processTarget"
    
    local MSG=
    [[ -z "${CRED}" ]] && MSG="-u <CRED> USER CREDENTIALS OF SOURCE MIGRATION SCHEMA MANDATORY."
    [[ -z "${TNS}" ]] && MSG="-t <TNS> TNS DETAILS OF SOURCE MIGRATION DATABASE MANDATORY."
    [[ -z "${PDB}" ]] && MSG="-p <PDB> NAME OF TARGET PDB IS MANDATORY."
    
    if [ -n "${MSG}" ]; then
        echo "${MSG}"
        exit 1
    fi
    
    if [ "${REMOVE}" = "TRUE" ]; then
        removeTarget
        exit 0
    fi
    
    local EXISTS=$(runsql -v -s "SELECT TO_CHAR(COUNT(*)) FROM dual WHERE EXISTS (SELECT 1 FROM cdb_pdbs WHERE pdb_name='${PDB}');")
    chkerr "$?" "${LINENO}" "${EXISTS}"
    
    [[ "${EXISTS}" = "0" ]] && createTargetSchema || runTargetMigration    
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



case "${DB}" in
    SOURCE)
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
                h)  usageSource ;;
                :)  echo "ERROR -${OPTARG} REQUIRES  ARGUMENT"
                    usageSource
                    ;;
                *)  usageSource ;;
            esac
        done
        processSource
        ;;
    TARGET)
        USER=C##MIGRATION
        REMOVE=FALSE
        while getopts ":c:t:p:rh" o; do
            case "${o}" in
                c)  CRED=${OPTARG} ;;
                t)  TNS=${OPTARG} ;;
                p)  PDB=$(upper ${OPTARG}) ;;
                r)  REMOVE=TRUE ;;
                h)  usageTarget ;;
                :)  echo "ERROR -${OPTARG} REQUIRES  ARGUMENT"
                    usageTarget
                    ;;
                *)  usageTarget ;;
            esac
        done    
        processTarget
        ;;
esac

exit