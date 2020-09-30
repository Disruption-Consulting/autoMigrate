#!/bin/bash

#zip /tmp/autoMigrate.zip  runMigration.sh pck_migration_src.sql pck_migration_tgt.sql pck_migration_rollforward.sql

#################################################################################################################
#
#  SCRIPT      : runMigration.sh
#
#  DESCRIPTION : Migrates a NON-CDB Oracle database (SOURCE) to version 19 PDB (TARGET)
#
#  INSTALL     : Install this script and relevant package source files in a temporary directory
#
#
#  SOURCE DATABASE
#                       
#                ./runMigration -m [ANALYZE|EXECUTE|INCR] -b [BKPDIR] -f [BKPFREQ] -r -u [USER]
#
#                -m ANALYZE
#                     reports on database properties that are relevant to migration (e.g. size, version)
#                   EXECUTE
#                     prepares database for migration setting application tablespaces read only
#                   INCR
#                     prepares database for migration through rolling forward incremental backups
#
#                -b BKPDIR
#                     for INCR specifies location of backup directory
#
#                -f BKPFREQ
#                     for INCR specifies backup frequency. Default is hourly.
#
#                -r removes the schema created to manage the migration and any incremental backups
#
#                -u USER
#                     required only if pre-migration database happens to have a user called "MIGRATION19"
#
#                OUTPUT
#                  log file "runMigration.log" including the command to be run on the TARGET database if -m [EXECUTE|INCR]
#                   
#
#  TARGET DATABASE
#                       
#                ./runMigration -c [CREDENTIAL] -t [TNS] -p [PDB} -r
#
#                -c CREDENTIAL
#                     credentials of migration schema created on SOURCE database.
#
#                -t TNS
#                     TNS string defining location of source database
#
#                -p PDB
#                     Name of the PDB to be created for the migration. Typically the SOURCE database name.
#
#                -r removes PDB
#
#                OUTPUT
#                  log file "runMigration.log" of tasks performed to create the target PDB
#                  for each PDB creates a log file "runMigration.PDB.log" of transfer / datapump / final tasks
#
#
#  SECURITY
#                The credentials of all schemas created by the script are added to an external Oracle password wallet
#                created in the installation directory
#
#                Passwords are complex, randomly generated 10 character strings comprising upper/lower and special characters
#
#                Log files are loaded into the TARGET PDB and deleted from the OS file system when migration is completed
#
#################################################################################################################

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
            c) CONNECT="CONNECT /@${OPTARG}" ;;
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
    chkerr "$?" "${LINENO}" "${WPW}"
    
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

deleteCredential() {
    log "deleteCredential - ${1}"
    
    local TNS="${1}"
    
    local WPW=$(runsql -v -s "SELECT log_message FROM ${USER}.migration_log WHERE name='WPW';")
    chkerr "$?" "${LINENO}" "${WPW}"
    
    mkstore -wrl "${WALLET}" -deleteCredential "${TNS}"<<EOF
${WPW}
EOF

    sed -i "/^${TNS}/d" ${TNSNAMES}
}


removeSource() {
    log "removeSource"
    
    deleteCredential "${USER}"
    
    cat <<-EOF>${SQLFILE}
        CONNECT / AS SYSDBA
        WHENEVER SQLERROR EXIT FAILURE
        SET SERVEROUTPUT ON
        SET ECHO ON
        EXEC ${USER}.pck_migration_src.set_ts_readwrite
        DROP USER ${USER} CASCADE;
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
            FOR C IN (SELECT directory_name FROM dba_directories WHERE REGEXP_LIKE(directory_name,'${USER}_FILES_[1-9]+_DIR')) LOOP
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
    rman cmdfile="${RMANFILE}" || { echo "RMAN DELETE INCREMENTAL MIGRATION BACKUPS FAILED"; exit 1; }
}


createSourceSchema(){
    log "createSourceSchema"
    
    local PW=$(password)
    local V11=$(version "11")
    local V12=$(version "12")
    local PRIV
    
    [[ ${THISDB} < ${V11} ]] && PRIV=EXP_FULL_DATABASE || PRIV=DATAPUMP_EXP_FULL_DATABASE

    cat <<-EOF>${SQLFILE}
        CONNECT / AS SYSDBA
        SET SERVEROUTPUT ON
        CREATE USER ${USER} IDENTIFIED BY ${PW} DEFAULT TABLESPACE SYSTEM QUOTA 10M ON SYSTEM;
        GRANT SELECT ANY DICTIONARY,
              CREATE SESSION,
              ALTER TABLESPACE,
              CREATE ANY JOB,
              MANAGE SCHEDULER,
              ${PRIV} TO ${USER};
        GRANT EXECUTE ON SYS.DBMS_BACKUP_RESTORE TO ${USER};
        GRANT EXECUTE ON SYS.DBMS_SYSTEM TO ${USER};
        GRANT EXECUTE ON SYS.DBMS_CRYPTO TO ${USER};
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
            FOR C IN (SELECT directory_name, ROWNUM rn FROM 
                        ( SELECT DISTINCT SUBSTR(f.file_name,1,INSTR(f.file_name,'/',-1)-1) directory_name
                            FROM dba_tablespaces t, dba_data_files f
                           WHERE t.tablespace_name=f.tablespace_name
                             AND t.contents='PERMANENT'
                             AND t.tablespace_name NOT IN ('SYSTEM','SYSAUX')
                        )
            ) LOOP
                exec('CREATE OR REPLACE DIRECTORY ${USER}_FILES_'||C.rn||'_DIR AS '''||C.directory_name||'''');
                exec('GRANT READ, WRITE ON DIRECTORY ${USER}_FILES_'||C.rn||'_DIR TO ${USER}');
            END LOOP;
        END;
        /
        CREATE OR REPLACE DIRECTORY ${USER}_SCRIPT_DIR AS '${CD}';
        GRANT READ, WRITE ON DIRECTORY ${USER}_SCRIPT_DIR TO ${USER};
        COL IP NEW_VALUE IP NOPRINT
        SELECT UTL_INADDR.get_host_address IP FROM DUAL;
        ALTER SESSION SET CURRENT_SCHEMA=${USER};
        CREATE OR REPLACE VIEW V_APP_TABLESPACES AS
          SELECT t.tablespace_name, t.status, t.file_id, d.directory_path, d.directory_name, SUBSTR(t.file_name,pos+1) file_name, t.enabled, t.bytes
          FROM
            (
             SELECT t.tablespace_name, t.status, f.file_id, f.file_name,INSTR(f.file_name,'/',-1) pos, f.bytes, v.enabled
               FROM dba_tablespaces t, dba_data_files f, v\$datafile v
              WHERE t.tablespace_name=f.tablespace_name
                AND v.file#=f.file_id
                AND t.contents='PERMANENT'
                AND t.tablespace_name NOT IN ('SYSTEM','SYSAUX')
            ) t, all_directories d
            WHERE SUBSTR(t.file_name,1,pos-1)=d.directory_path
            AND d.directory_name LIKE '${USER}_FILES%';
            
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
        INSERT INTO migration_log(id, name, log_message) VALUES (migration_log_seq.nextval,'IP','&IP');
        COMMIT;
EOF

    if [[ ${THISDB} < ${V12} ]]; then
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
              FROM u;
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
    chkerr "$?" "${LINENO}" "${SERVICE}"
    
    createCredential "${USER}" "${USER}" "${PW}" "${SERVICE}" 
}


runSourceMigration() {
    log "runSourceMigration"

    cat <<-EOF>${SQLFILE}
    CONNECT /@${USER}
    SET SERVEROUTPUT ON
    SET LINESIZE 300
    BEGIN
        pck_migration_src.init(
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
    
    local V10103=$(version "10.1.0.3")
    
    [[ "${MODE}" =~ (^ANALYZE|EXECUTE|INCR$) ]] || { echo "-m <MODE> MUST BE ONE OF [ANALYZE|EXECUTE|INCR]. DEFAULT IS ANALYZE."; exit 1; }
    [[ "${MODE}" = "INCR"  &&  -z "${BKPDIR}" ]] && { echo "-b <BKPDIR> MUST BE SPECIFIED FOR -m INCR"; exit 1; }
    [[ "${MODE}" != "INCR"  &&  (-n "${BKPDIR}" || -n "${BKPFREQ}") ]] && { echo "-b <BKPDIR> AND -f <BKPFREQ> ONLY RELEVANT FOR -m INCR"; exit 1; }
    [[ "${THISDB}" < "${V10103}" ]] && { echo "LOWEST VERSION WE CAN MIGRATE IS 10.1.0.3"; exit 1; }
    
    cat <<-EOF>${SQLFILE}
    CONNECT / AS SYSDBA
    SET SERVEROUTPUT ON
    SET ECHO OFF
    DECLARE
        n PLS_INTEGER;
        l_compatibility VARCHAR2(10);
        l_cdb VARCHAR2(3);
        l_oracle_pdb_sid VARCHAR2(20);
    BEGIN
        n:=0;
        FOR C IN (SELECT DISTINCT file_name,nb,GT2TB FROM 
                    (SELECT file_name,COUNT(*) OVER (PARTITION BY file_name) nb, CASE WHEN bytes>2*POWER(1024,4) THEN 1 ELSE 0 END GT2TB
                       FROM(
                          SELECT SUBSTR(f.file_name,INSTR(f.file_name,'/',-1)+1) file_name, bytes
                            FROM dba_tablespaces t, dba_data_files f
                           WHERE t.tablespace_name=f.tablespace_name
                             AND t.contents='PERMANENT'
                             AND t.tablespace_name NOT IN ('SYSTEM','SYSAUX')
                        )
                 ) ) 
        LOOP
            IF (C.nb>1) THEN
                n:=n+1;
                dbms_output.put_line(C.file_name||' IN MULTIPLE DIRECTORIES. MUST BE RENAMED TO BE UNIQUE WITHIN DATABASE.');
            END IF;
            IF (C.GT2TB>0) THEN
                n:=n+1;
                dbms_output.put_line(C.file_name||' EXCEEDS MAXIMUM SIZE ALLLOWED 2TB.');
            END IF;
        END LOOP;
        
        SELECT value INTO l_compatibility FROM v\$parameter WHERE name='compatible';
        IF (l_compatibility LIKE '9%') THEN
            n:=n+1;
            dbms_output.put_line('MINIMUM COMPATIBILITY IS 10.0.0 - USE ALTER SYSTEM TO CHANGE, RESTART DATABASE AND RETRY.');
        END IF;
        
        IF ('${MODE}'='INCR') THEN
            FOR C IN (SELECT NULL FROM v\$database WHERE log_mode<>'ARCHIVELOG') LOOP
                n:=n+1;
                dbms_output.put_line('MUST BE ARCHIVELOG MODE TO MIGRATE USING INCREMENTAL BACKUPS.');
            END LOOP;
        END IF;                
        
        l_cdb:='NO';
        IF ('${VERSION}' LIKE '12%') THEN
            EXECUTE IMMEDIATE 'SELECT cdb FROM v\$database' INTO l_cdb;
        END IF;
        IF (l_cdb='YES') THEN
            sys.dbms_system.get_env('ORACLE_PDB_SID',l_oracle_pdb_sid);
            IF (l_oracle_pdb_sid IS NULL) THEN
                n:=n+1;
                dbms_output.put_line('SET ORACLE ENVIRONMENT VARIABLE "ORACLE_PDB_SID" TO MIGRATE PDB WITH THIS UTILITY.');
            END IF;
        END IF;        
        
        IF (n>0) THEN
            RAISE_APPLICATION_ERROR(-20000,n||' QUALIFICATION ERROR(S) OCCURED');
        END IF;
    END;
    /
EOF
    runsql || { echo "DATABASE DOES NOT QUALIFY FOR MIGRATION WITH THIS UTILITY"; exit 1; }    
    
    
    [[ "${REMOVE}" = "TRUE" ]] && { removeSource; exit 0; }
    
    local EXISTS=$(runsql -v -s "SELECT TO_CHAR(COUNT(*)) FROM dual WHERE EXISTS (SELECT 1 FROM dba_users WHERE username='${USER}');")
    chkerr "$?" "${LINENO}" "${EXISTS}"
    
    [[ "${EXISTS}" = "0" ]] && { createSourceSchema; runSourceMigration; } || runSourceMigration
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
    GRANT SELECT ON SYS.V_\$PDBS TO ${USER};
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
    
    local FILEPATH=$(runsql -v -c "${ORACLE_SID}" -s "SELECT DISTINCT SUBSTR(f.file_name,1,INSTR(f.file_name,'/',-1)) FROM cdb_data_files f, v\$pdbs p WHERE f.con_id=p.con_id AND p.name='${PDB}';");
    chkerr "$?" "${LINENO}" "${FILEPATH}"
    
    cat <<-EOF>${SQLFILE}
        CONNECT /@${ORACLE_SID} AS SYSDBA
        WHENEVER SQLERROR CONTINUE
        ALTER PLUGGABLE DATABASE ${PDB} CLOSE IMMEDIATE;
        WHENEVER SQLERROR EXIT FAILURE
        DROP PLUGGABLE DATABASE ${PDB} INCLUDING DATAFILES;
EOF
    runsql || { echo "removeTarget FAILED"; exit 1; }
    
    deleteCredential "${PDB}"
    
    [[ -z ${FILEPATH} ]] || rm -i -v ${FILEPATH}*
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
        CONNECT /@${ORACLE_SID} AS SYSDBA
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
        GRANT DROP USER TO PDBADMIN;
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
        SELECT MAX(SUBSTR(file_name,1,INSTR(file_name,'/',-1)-1)) AS filepath FROM cdb_data_files WHERE con_id=&con_id;
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
        CONNECT /@${ORACLE_SID}
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


createTargetRunScripts() {
    log "createTargetRunScripts"
    
    local RUNSCRIPT="${1}"
    
    cat <<-EOF>${RUNSCRIPT}.sql
        whenever sqlerror exit failure
        set echo on
        connect /@${PDB}
            exec pck_migration_tgt.transfer
            col all_ts_readonly new_value all_ts_readonly noprint
            SELECT TO_CHAR(COUNT(*)-SUM(DECODE(enabled,'READ ONLY',1,0))) all_ts_readonly FROM migration_ts;
        connect /@${ORACLE_SID}
            exec pck_migration_rollforward.apply
        connect /@${PDB}
            begin
                if ('&all_ts_readonly'='0') then
                    pck_migration_tgt.impdp(pOverride=>${OVERRIDE},pDbmsStats=>${DBMSSTATS});
                end if;
            end;
            /
        exit
EOF

    cat /dev/null>${RUNSCRIPT}.impdp.sh
    
    cat <<-EOF>${RUNSCRIPT}.sh
#!/bin/bash
exec 1>${RUNSCRIPT}.log 2>&1
export ORACLE_HOME=${ORACLE_HOME}
export ORACLE_SID=${ORACLE_SID}
export PATH=\${ORACLE_HOME}/bin:${PATH}
export TNS_ADMIN=${CD}

sqlplus /nolog @${RUNSCRIPT}.sql
[[ \$? = 0 ]] && { echo "Completed transfer successfully. Now starting datapump"; } || { echo "FAILED TO RUN ${RUNSCRIPT}.sql"; exit 1; }

. ${RUNSCRIPT}.impdp.sh

exit 0
EOF
    chmod u+x ${RUNSCRIPT}.sh    
}


runTargetMigration() {
    log "runTargetMigration"
    
    local RUNSCRIPT="${CD}/${FN}.${PDB}"
    
    [[ -f "${RUNSCRIPT}.sh" ]] || createTargetRunScripts "${RUNSCRIPT}"

    cat <<-EOF>${SQLFILE}
        CONNECT /@${ORACLE_SID} AS SYSDBA
        ALTER SESSION SET CONTAINER=${PDB};
        DECLARE
            l_repeat_interval user_scheduler_jobs.repeat_interval%type;
        BEGIN
            SELECT MAX(repeat_interval) INTO l_repeat_interval FROM user_scheduler_jobs@migr_dblink;
            DBMS_SCHEDULER.CREATE_JOB(
                job_name=>'MIGRATION',
                job_type=>'EXECUTABLE',
                start_date=>SYSTIMESTAMP,
                enabled=>TRUE,
                job_action=>'${RUNSCRIPT}.sh',
                repeat_interval=>l_repeat_interval);
        END;
        /
EOF
    runsql || { echo "runTargetMigration FAILED"; exit 1; }
}


processTarget() {
    log "processTarget"
    
    local EXISTS=$(runsql -v -s "SELECT TO_CHAR(COUNT(*)) FROM dual WHERE EXISTS (SELECT 1 FROM cdb_pdbs WHERE pdb_name='${PDB}');")
    chkerr "$?" "${LINENO}" "${EXISTS}"
    
    [[ "${REMOVE}" = "FALSE"  && (-z "${CRED}" || -z "${TNS}" || -z "${PDB}") ]] && { echo "-c <CRED> -t <TNS> -p <PDB> ALL MANDATORY."; exit 1; }
    [[ "${REMOVE}" = "FALSE"  && "${EXISTS}" = "1" ]] && { log "RESTARTING MIGRATION"; runTargetMigration; }
    
    
    [[ "${REMOVE}" = "TRUE"  &&  (-n "${CRED}" || -n "${TNS}") ]] && { echo "-p <PDB> -r   MUST BE THE ONLY PARAMETERS SPECIFIED."; exit 1; }
    [[ "${REMOVE}" = "TRUE"  &&  "${EXISTS}" = "0" ]] && { echo "PDB DOES NOT EXIST."; exit 1; }
    [[ "${REMOVE}" = "TRUE" ]] && { removeTarget; }
    
    cat <<-EOF>${SQLFILE}
        CONNECT /@${ORACLE_SID}
    SET SERVEROUTPUT ON
    SET ECHO OFF 
    DECLARE
        l_mismatch VARCHAR2(200):=NULL;
        n 
    BEGIN
        /*
         *  CHECK THAT SOURCE TABLESPACES ARE READ ONLY IF THIS IS A DIRECT MiGRATION 
         */
        SELECT NVL(COUNT(*)-SUM(DECODE(status,'READ ONLY',1,0)),0) INTO n
          FROM V_APP_TABLESPACES@migr_dblink 
         WHERE NOT EXISTS (SELECT NULL FROM user_scheduler_jobs@migr_dblink);
        IF (n>0) THEN
            RAISE_APPLICATION_ERROR(-20000,'ALL SOURCE APPLICATION TABLESPACES MUST BE READ ONLY BEFORE STARTING MIGRATION.');
        END IF;    
        
        /*
         *  CHECK SOURCE AND TARGET CHARACTERSETS ARE THE SAME.
         */        
        FOR C IN (
            SELECT COUNT(src) src, COUNT(tgt) tgt, property_name, property_value
            FROM
            (
            SELECT 1 tgt, TO_NUMBER(NULL) src, property_name, property_value 
            FROM database_properties WHERE property_name IN ('NLS_CHARACTERSET','NLS_NCHAR_CHARACTERSET')
            UNION ALL
            SELECT TO_NUMBER(NULL) tgt, 1 src, property_name, property_value 
            FROM database_properties@MIGR_DBLINK WHERE property_name IN ('NLS_CHARACTERSET','NLS_NCHAR_CHARACTERSET')
            )
            GROUP BY property_name, property_value
            ) 
        LOOP
            IF (C.tgt=1 AND C.src=1) THEN
                CONTINUE;
            END IF;
            IF (C.src=1) THEN
                l_mismatch:=l_mismatch||' SOURCE '||C.property_name||':'||C.property_value;
            ELSE
                l_mismatch:=l_mismatch||' TARGET '||C.property_name||':'||C.property_value;
            END IF;
        END LOOP;
        IF (l_mismatch IS NOT NULL) THEN
            RAISE_APPLICATION_ERROR(-20000,'CHARACTER SET MISMATCH. MUST FIRST MIGRATE TO CDB WITH SAME CHARACTERSET AND THEN RELOCATE TO AL32UTF8 CDB - '||l_mismatch;
        END IF;
    END;
    /
EOF
    runsql || { echo "MIGRATION STOPPED. RESOLVE ISSUE AND RETRY."; exit 1; } 
    
    [[ "${REMOVE}" = "FALSE"  && "${EXISTS}" = "0" ]] && { createTargetSchema; runTargetMigration; }
}



##########################
#   SCRIPT STARTS HERE   #
##########################

VERSION=$(runsql -v -s "SELECT MAX(REGEXP_SUBSTR(banner,'\d+.\d+.\d+.\d+')) FROM v\$version;")
chkerr "$?" "${LINENO}" "${VERSION}"

THISDB=$(version "${VERSION}")

[[ ${VERSION} = 19* ]] && DB=TARGET || DB=SOURCE

export TNS_ADMIN="${CD}"

WALLET="${TNS_ADMIN}/wallet"
TNSNAMES="${TNS_ADMIN}/tnsnames.ora"
SQLNET="${TNS_ADMIN}/sqlnet.ora"

[[ -f "${TNSNAMES}" ]] || cat /dev/null>"${TNSNAMES}"
[[ -f "${SQLNET}" ]] || cat /dev/null>"${SQLNET}"


case "${DB}" in
    SOURCE)
        MODE=ANALYZE
        USER=MIGRATION19
        REMOVE=FALSE
        while getopts ":m:u:b:f:rh" o; do
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
        DBMSSTATS=TRUE
        OVERRIDE=FALSE
        REMOVE=FALSE
        while getopts ":c:t:p:rh12" o; do
            case "${o}" in
                c)  CRED=${OPTARG} ;;
                t)  TNS=${OPTARG} ;;
                p)  PDB=$(upper ${OPTARG}) ;;
                r)  REMOVE=TRUE ;;
                1)  DBMSSTATS=FALSE ;;
                2)  OVERRIDE=TRUE ;;
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

exit 0