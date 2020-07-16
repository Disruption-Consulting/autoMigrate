Rem
Rem    NAME
Rem      tgt_migr.sql
Rem
Rem    DESCRIPTION
Rem      Performs a full database network link migration of a source Oracle database into a target Pluggable database (PDB)
Rem      1. Creates PDB
Rem      2. Runs migration 
Rem 
Rem    COMMAND
Rem      Complete documentation at https://github.com/xsf3190/automigrate.git
Rem

WHENEVER SQLERROR EXIT

set serveroutput on size unlimited
set trimspool on
set linesize 1000
set echo off
set verify off
set feedback off

col 1 new_value 1
col 2 new_value 2
col 3 new_value 3
col 4 new_value 4
col 5 new_value 5
col 6 new_value 6
col 7 new_value 7
col 8 new_value 8


SELECT '' "1", '' "2", '' "3", '' "4", '' "5", '' "6", '' "7", '' "8" FROM dual WHERE 1=2;

define 1
define 2
define 3
define 4
define 5
define 6
define 7
define 8

variable p_SRC_USER         VARCHAR2(30)=MIGRATION
variable p_SRC_PW           VARCHAR2(10)
variable p_SRC_HOST         VARCHAR2(30)
variable p_SRC_PORT         VARCHAR2(5)=1521
variable p_SRC_SERVICE      VARCHAR2(30)
variable p_PDBNAME          VARCHAR2(30)
variable p_OVERRIDE         VARCHAR2(7)=DEFAULT
variable p_REMOVE           VARCHAR2(5)=FALSE
variable p_TMPDIR           VARCHAR2(100)=/tmp

spool tgt_migr_exec.sql

DECLARE
    SQLPLUSLOG VARCHAR2(100);
    
    -------------------------------
    PROCEDURE exec(pCommand IN VARCHAR2) IS
    BEGIN
        dbms_output.put_line(pCommand||';');
    END;
    
    -------------------------------
    PROCEDURE validate_directory(pDirectoryPath IN VARCHAR2) IS
        l_file_exists NUMBER;
    BEGIN
        EXECUTE IMMEDIATE 'CREATE OR REPLACE DIRECTORY DELETEIT AS '''||pDirectoryPath||'''';
        l_file_exists := DBMS_LOB.FILEEXISTS(BFILENAME('DELETEIT','.'));
        EXECUTE IMMEDIATE 'DROP DIRECTORY DELETEIT';
        IF ( l_file_exists<>1 ) THEN
            RAISE_APPLICATION_ERROR(-20000,'DIRECTORY "'||pDirectoryPath||'" DOES NOT EXIST AT OS LEVEL');
        END IF;
    END;
 
    -------------------------------
    PROCEDURE create_pdb IS
        l_dir_pdb     VARCHAR2(200);  
        l_pdbadmin_pw VARCHAR2(10):=DBMS_RANDOM.string('x',5)||DBMS_RANDOM.string('a',4)||'!';
        l_wallet_pw   VARCHAR2(10):=DBMS_RANDOM.string('x',5)||DBMS_RANDOM.string('a',4)||'!';
        l_script      VARCHAR2(100);
        n PLS_INTEGER;
    BEGIN
         /*
          *  SET max_pdbs=3 IF V19 TO AVOID UNLICENSED USE IF TAKING ADVANTAGE OF NO MULTITENANT LICENSE NEEDED WHEN MAX 3 PDBS PER CDB
          */
         SELECT TO_NUMBER(value) INTO n FROM v$parameter WHERE name='max_pdbs';
         IF (n>3) THEN
            FOR C IN (SELECT version FROM (SELECT REGEXP_SUBSTR(banner_full,'\d+.') version FROM v$version) WHERE SUBSTR(version,1,2)='19') LOOP
                exec('ALTER SYSTEM SET max_pdbs=3');
            END LOOP;
         END IF;
         
         /*
          *  GET THE DIRECTORY PATH OF THE PDB CONTAINER - WILL BE THE DESTINATION FOR DATAFILES COPIED FROM SOURCE DATABASE.
          */
         SELECT REPLACE(dir_pdbseed,'pdbseed',:p_PDBNAME)
           INTO l_dir_pdb
           FROM (SELECT SUBSTR(f.name,1,INSTR(f.name,'/',-1)) dir_pdbseed FROM v$datafile f, v$pdbs p WHERE p.name='PDB$SEED' AND p.con_id=f.con_id AND ROWNUM=1);

         /*
          *  CREATE THE PLUGGABLE DATABASE (DEFAULT NAME IS SOURCE DATABASE NAME)
          */
         exec('CREATE PLUGGABLE DATABASE '||:p_PDBNAME||' ADMIN USER PDBADMIN IDENTIFIED BY "'||l_pdbadmin_pw||'" ROLES=(DATAPUMP_IMP_FULL_DATABASE) FILE_NAME_CONVERT=(''pdbseed'','''||:p_PDBNAME||''')');

         /*
          *  SET NEW PDB AS CURRENT CONTAINER
          */
         exec('ALTER SESSION SET CONTAINER='||:p_PDBNAME);

         /*
          *  OPEN THE PDB AND SAVE STATE SO THAT IT WILL BE OPENED ON SUBSEQUENT DATABASE RESTARTS
          */
         exec('ALTER PLUGGABLE DATABASE '||:p_PDBNAME||' OPEN READ WRITE');
         exec('ALTER PLUGGABLE DATABASE '||:p_PDBNAME||' SAVE STATE');

         exec('AUDIT CONNECT');

         /*
          *  PDB ADMIN USER, WHICH WILL EVENTUALLY PERFORM THE IMPORT FROM SOURCE, NEEDS SMALL QUOTA IN SYSEM TABLESPACE FOR COUPLE OF ADMIN TABLES
          */ 
         exec('ALTER USER PDBADMIN QUOTA UNLIMITED ON SYSTEM');  

        /*
         *  GRANT PRIVILEGES TO PDBADMIN USER IN ORDER TO PERFORM FULL DATABASE EXPORT / IMPORT
         */
        exec('GRANT CREATE PUBLIC DATABASE LINK, CREATE ANY DIRECTORY, SELECT ANY DICTIONARY, CREATE TABLE, CREATE PROCEDURE, 
              CREATE MATERIALIZED VIEW, CREATE JOB, MANAGE SCHEDULER, ALTER SESSION, CREATE USER, ALTER USER, DROP USER, DROP ANY DIRECTORY, ANALYZE ANY DICTIONARY, CREATE SESSION, 
              ANALYZE ANY, CREATE TABLESPACE, ALTER TABLESPACE, GRANT ANY PRIVILEGE TO PDBADMIN');
        exec('GRANT EXECUTE ON SYS.DBMS_BACKUP_RESTORE TO PDBADMIN');
        exec('GRANT EXECUTE ON SYS.DBMS_FILE_TRANSFER TO PDBADMIN');
        exec('GRANT EXECUTE ON SYS.DBMS_SYSTEM TO PDBADMIN');

        /*
         *  1. GRANT READ/WRITE ACCESS TO TMPDIR THAT WAS CREATED IN SETPARAMETER PROCEDURE 
         *  2. CREATE DIRECTORY LOCATION OF PDB DATA FILES
         */
        exec('CREATE OR REPLACE DIRECTORY TMPDIR AS '''||:p_TMPDIR||''''); 
        exec('GRANT READ, WRITE ON DIRECTORY TMPDIR TO PDBADMIN');
        exec('CREATE OR REPLACE DIRECTORY TGT_FILES_DIR AS '''||RTRIM(l_dir_pdb,'/')||''''); 
        exec('GRANT READ, WRITE ON DIRECTORY TGT_FILES_DIR TO PDBADMIN');
        
        exec('CREATE TABLE PDBADMIN.migration_ts
               ("TABLESPACE_NAME"   VARCHAR2(30),
                "ENABLED"           VARCHAR2(20),
                "FILE_ID"           NUMBER,
                "FILE_NAME"         VARCHAR2(100),
                "DIRECTORY_NAME"    VARCHAR2(30),
                "FILE_NAME_RENAMED" VARCHAR2(107),
                "MIGRATION_STATUS"  VARCHAR2(50) DEFAULT ''TRANSFER NOT STARTED'',
                "START_TIME"        DATE,
                "ELAPSED_SECONDS"   NUMBER,
                "BYTES"             NUMBER,
                "TRANSFERRED_BYTES" NUMBER,
               CONSTRAINT PK_MIGRATION_TS PRIMARY KEY(FILE_ID))');
               
        exec('CREATE TABLE PDBADMIN.migration_bp
               ("RECID"             NUMBER,
                "FILE_ID"           NUMBER,
                "BP_FILE_NAME"      VARCHAR2(100),
                "DIRECTORY_NAME"    VARCHAR2(30),
                "MIGRATION_STATUS"  VARCHAR2(50) DEFAULT ''TRANSFER NOT STARTED'',
                "START_TIME"        DATE,
                "ELAPSED_SECONDS"   NUMBER,
                "BYTES"             NUMBER,
                "TRANSFERRED_BYTES" NUMBER,
                CONSTRAINT pk_migration_bp PRIMARY KEY(recid),
                CONSTRAINT fk_migration_ts FOREIGN KEY(file_id) REFERENCES PDBADMIN.migration_ts(file_id))');               

        exec('CREATE GLOBAL TEMPORARY TABLE PDBADMIN.migration_temp
               ("OWNER"             VARCHAR2(30),
                "OBJECT_TYPE"       VARCHAR2(30),
                "OBJECT_NAME"       VARCHAR2(30),
                "TEXT"              CLOB)');  
                
        exec('CREATE SEQUENCE PDBADMIN.migration_log_seq START WITH 1 INCREMENT BY 1');

        exec('CREATE TABLE PDBADMIN.migration_log
               ("ID"            NUMBER DEFAULT PDBADMIN.migration_log_seq.NEXTVAL,
                "LOG_TIME"      DATE DEFAULT SYSDATE,
                "LOG_MESSAGE"   CLOB,
                CONSTRAINT PK_MIGRATION_LOG PRIMARY KEY(id))');
                
        /*
         *   NETWORK LINK IMPDP MANDATES USE OF PUBLIC DATABASE LINK
         */
        exec('ALTER SESSION SET GLOBAL_NAMES=FALSE');
        exec('CREATE PUBLIC DATABASE LINK MIGR_DBLINK CONNECT TO '||:p_SRC_USER||' IDENTIFIED BY '||:p_SRC_PW
             ||' USING '''||:p_SRC_HOST||':'||:p_SRC_PORT||'/'||:p_SRC_SERVICE||'''');
             
        exec('PROMPT "Compiling pck_migration_tgt.sql"');
        exec('set termout off');
        exec('@@pck_migration_tgt.sql');
        exec('set termout on');
        exec('show errors');

        /*
         *  CREATE SECURITY SCRIPT TO GENERATE EXTERNAL PASSWORD STORE FOR PDBADMIN
         */
        l_script:=:p_TMPDIR||'/migration_secure.sh';
        
        exec('host echo ''#!/bin/bash''>'||l_script);
        exec('host echo ''exec 1>>'||SQLPLUSLOG||' 2>'||chr(38)||'1''>>'||l_script);
        exec('host chmod u+x '||l_script);
        exec('host echo ''rm -Rf '||:p_TMPDIR||'/wallet''>>'||l_script);
        exec('host echo ''echo "mkstore -create -wrl '||:p_TMPDIR||'/wallet"''>>'||l_script);
        exec('host echo ''mkstore -create -wrl '||:p_TMPDIR||'/wallet<<EOF''>>'||l_script);
        exec('host echo '''||l_wallet_pw||'''>>'||l_script);
        exec('host echo '''||l_wallet_pw||'''>>'||l_script);
        exec('host echo ''EOF''>>'||l_script);
        exec('host echo ''echo "mkstore -wrl '||:p_TMPDIR||'/wallet -createCredential '||:p_PDBNAME||' PDBADMIN ****"''>>'||l_script);
        exec('host echo ''mkstore -wrl '||:p_TMPDIR||'/wallet -createCredential '||:p_PDBNAME||' PDBADMIN '||l_pdbadmin_pw||'<<EOF''>>'||l_script);
        exec('host echo '''||l_wallet_pw||'''>>'||l_script);
        exec('host echo ''EOF''>>'||l_script);
        
        /*
         *  EXTERNAL PASSWORD STORE REQUIRES tnsnames.ora AND sqlnet.ora WHICH WE CREATE IN TMPDIR (HENCE TNS_ADMIN).
         */ 
        exec('host echo ''export TNS_ADMIN='||:p_TMPDIR||'''>>'||l_script);
        exec('host echo '''||:p_PDBNAME
                           ||'=(DESCRIPTION=(ADDRESS=(PROTOCOL=TCP)(HOST=localhost)(PORT=1521))(CONNECT_DATA=(SERVICE_NAME='||:p_PDBNAME||')))''>'
                           ||:p_TMPDIR||'/tnsnames.ora');
        exec('host echo ''SQLNET.WALLET_OVERRIDE=TRUE''>'||:p_TMPDIR||'/sqlnet.ora'); 
        exec('host echo ''WALLET_LOCATION=(SOURCE=(METHOD=FILE)(METHOD_DATA=(DIRECTORY='||:p_TMPDIR||'/wallet)))''>>'||:p_TMPDIR||'/sqlnet.ora'); 

        /*
         *  INSTRUCT TO RUN THE SECURITY SCRIPT
         */
        exec('host '||l_script);
    END;
    
    -------------------------------
    PROCEDURE run_migration IS
    /*
     *  CREATE migration.sh SCRIPT AND RUN AS A BACKGROUND JOB
     */
        l_oracle_home varchar2(100);
        l_oracle_sid varchar2(16);
        l_script VARCHAR2(100):=:p_TMPDIR||'/migration.sh';
    BEGIN    
        sys.dbms_system.get_env('ORACLE_SID',l_oracle_sid);
        sys.dbms_system.get_env('ORACLE_HOME',l_oracle_home);

        exec('host cat /dev/null>'||:p_TMPDIR||'/migration_impdp.sh');
        exec('host cat /dev/null>'||:p_TMPDIR||'/migration_final.sh');

        exec('host echo "#!/bin/bash">'||l_script);
        exec('host chmod u+x '||l_script);
        exec('host echo "exec 1>'||:p_TMPDIR||'/migration.log 2>'||chr(38)||'1">>'||l_script);

        exec('host echo "export ORACLE_HOME=' || l_oracle_home || '">>'||l_script);
        exec('host echo "export ORACLE_SID=' || l_oracle_sid || '">>'||l_script);
        exec('host echo "PATH=$ORACLE_HOME/bin:$PATH">>'||l_script);    
        exec('host echo "export TNS_ADMIN='||:p_TMPDIR||'">>'||l_script);
        exec('host echo "sqlplus /@' || :p_PDBNAME || '<<EOF">>'||l_script);
        exec('host echo "whenever sqlerror exit failure">>'||l_script);
        exec('host echo "set echo on">>'||l_script);
        exec('host echo "exec pck_migration_tgt.start_migration(pOverride=>'''|| :p_OVERRIDE||''')">>'||l_script);
        exec('host echo "EOF">>'||l_script);
        exec('host echo "if [ \$? -eq 1 ]">>'||l_script);
        exec('host echo "then">>'||l_script);
        exec('host echo " echo FAILURE RUNNING pck_migration_tgt.start_migration">>'||l_script);
        exec('host echo " exit 1">>'||l_script);
        exec('host echo "fi">>'||l_script);
        exec('host echo ". ' || :p_TMPDIR || '/migration_impdp.sh">>'||l_script);
        exec('host echo ". ' || :p_TMPDIR || '/migration_final.sh">>'||l_script);
        exec('host echo "exit 0">>'||l_script);

        /*
         *  SUBMIT MIGRATION JOB TO RUN IN BACKGROUND. IF FILES ARE BEING COPIED BY INCREMENTAL BACKUP, THEN SET THE SAME REPEAT_INTERVAL AS ON SOURCE JOB
         */
        IF (SYS_CONTEXT('USERENV','CON_NAME')<>:p_PDBNAME) THEN
            exec('ALTER SESSION SET CONTAINER='||:p_PDBNAME);
        END IF;
        dbms_output.put_line('declare');
        dbms_output.put_line(' l_repeat_interval user_scheduler_jobs.repeat_interval%type;');
        dbms_output.put_line('begin');
        dbms_output.put_line(' select max(repeat_interval) into l_repeat_interval from user_scheduler_jobs@migr_dblink;');
        dbms_output.put_line(' DBMS_SCHEDULER.create_job(job_name=>''MIGRATION'',job_type=>''EXECUTABLE'',start_date=>SYSTIMESTAMP,enabled=>TRUE,job_action=>'''||l_script||''',repeat_interval=>l_repeat_interval);');
        dbms_output.put_line('end;');
        dbms_output.put_line('/');
    END;
    
    -------------------------------
    PROCEDURE setParameter(pParameter IN VARCHAR2) IS
        l_name varchar2(20);
        l_value varchar2(20);
        l_error varchar2(100):=NULL;
    BEGIN
        IF (pParameter IS NULL) THEN
            RETURN;
        END IF;

        l_name:=UPPER(SUBSTR(pParameter,1,INSTR(pParameter,'=')-1));
        l_value:=SUBSTR(pParameter,INSTR(pParameter,'=')+1);
        IF (l_name NOT IN ('TMPDIR','PW')) THEN
            l_value:=UPPER(l_value);
        END IF;

        CASE l_name

            WHEN 'USER'
                THEN :p_SRC_USER:=l_value;
                
             WHEN 'PW'
                THEN :p_SRC_PW:='"'||l_value||'"';    

            WHEN 'HOST'
                THEN :p_SRC_HOST:=l_value;
                
            WHEN 'PORT'
                THEN :p_SRC_PORT:=l_value;
                
            WHEN 'SERVICE'
                THEN :p_SRC_SERVICE:=l_value;

            WHEN 'PDBNAME' 
                THEN :p_PDBNAME:=l_value;

            WHEN 'TMPDIR' THEN 
                validate_directory(:p_TMPDIR);

            WHEN 'OVERRIDE' THEN 
                IF (l_value IN ('CONV-DB','XTTS-TS')) THEN
                    :p_OVERRIDE:=l_value;
                ELSE
                    l_error:='INVALID VALUE FOR PARAMETER:'||l_name||' - MUST BE [CONV-DB|XTTS-TS]';
                END IF;       

            WHEN 'ACTION' THEN 
                IF (l_value='REMOVE') THEN
                    :p_REMOVE:='TRUE';                 
                ELSE
                    l_error:='INVALID VALUE FOR PARAMETER:'||l_name||' - MUST BE [FORCE-STOP|DEL-UNPLUG|RUNJOB|RESTART]';
                END IF;

            ELSE l_error:='INVALID PARAMETER:'||l_name;

        END CASE;

        IF (l_error IS NOT NULL) THEN
            RAISE_APPLICATION_ERROR(-20000,l_error);
        END IF;
    END;  
 
---------------------------------------
--------  START OF PL/SQL BLOCK -------
---------------------------------------
BEGIN 
    /*
     *  GET PARAMETERS. ABORT IF ANY MANDATORY PARAMETER MISSING.
     */
    setParameter('&1');
    setParameter('&2');
    setParameter('&3');
    setParameter('&4');
    setParameter('&5');
    setParameter('&6');
    setParameter('&7');
    setParameter('&8');
    
    IF (:p_REMOVE='TRUE') THEN
        exec('ALTER PLUGGABLE DATABASE '||:p_PDBNAME||' CLOSE IMMEDIATE');
        exec('DROP PLUGGABLE DATABASE '||:p_PDBNAME||' INCLUDING DATAFILES');
        FOR C IN (SELECT DISTINCT SUBSTR(f.file_name,1,INSTR(f.file_name,'/',-1)) dirname 
                    FROM cdb_data_files f, v$pdbs p
                   WHERE f.con_id=p.con_id
                     AND p.name=:p_PDBNAME) LOOP
            exec('HOST rm -f -v '||C.dirname||'*');
            exec('EXIT');
        END LOOP;
        RETURN;
    END IF;
    
    SQLPLUSLOG:=:p_TMPDIR||'/'||:p_PDBNAME||'.sqlplus.log';
    exec('spool ' ||SQLPLUSLOG);
    
    FOR C IN (SELECT NULL FROM dual WHERE NOT EXISTS (SELECT NULL FROM v$pdbs WHERE name=:p_PDBNAME)) LOOP
        create_pdb;
    END LOOP;
    
    run_migration;
    
    exec('spool off');

END;
/

spool off
set feedback on
set echo on
set define off

/*
 *  RUN GENERATED SCRIPT THAT CREATES PLUGGABLE DATABASE (IF NOT EXISTS) AND PDBADMIN SCHEMA
 */
 
@@tgt_migr_exec.sql

set pagesize 0
set long 300
set longchunksize 300

SELECT TO_CHAR(log_time,'dd.mm.yyyy hh24:mi:ss') log_time, log_message FROM pdbadmin.migration_log ORDER BY id;
prompt "ENTER / TO VIEW MIGRATION PROGRESS"
