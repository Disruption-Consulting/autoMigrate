Rem
Rem    NAME
Rem      tgt_migr.sql
Rem
Rem    DESCRIPTION
Rem      Performs a full database migration over the network of a source non-CDB database into a target Pluggable database (PDB)
Rem      1. Creates PDB
Rem      2. Runs migration 
Rem 
Rem    COMMAND
Rem      sqlplus / as sysdba @tgt_migr.sql USER=SNFTRANSFER HOST=hhhh SERVICE=ssss PDBNAME=pppp
Rem
Rem      Full details at https://github.com/xsf3190/automigrate.git
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

variable p_SRC_USER      VARCHAR2(30)
variable p_SRC_HOST      VARCHAR2(30)
variable p_SRC_PORT      VARCHAR2(5)=1521
variable p_SRC_SERVICE   VARCHAR2(30)
variable p_RESTART       VARCHAR2(5)=FALSE
variable p_PDBNAME       VARCHAR2(30)
variable p_OVERRIDE      VARCHAR2(7)=DEFAULT
variable p_FORCE_STOP    VARCHAR2(5)=FALSE
variable p_DEL_UNPLUG    VARCHAR2(5)=FALSE
variable p_RUNJOB        VARCHAR2(5)=FALSE
variable p_TMPDIR        VARCHAR2(100)=/tmp

spool tgt_migr_exec.sql

DECLARE
 
    -------------------------------
    PROCEDURE exec(pCommand IN VARCHAR2) IS
    BEGIN
        dbms_output.put_line(pCommand||';');
    END;
 
    ------------------------------------------------------------------------
    PROCEDURE create_pdb IS
        l_fexists boolean;
        l_file_length number;
        l_block_size binary_integer;
        l_dir_pdbseed VARCHAR2(200);
        l_dir_pdb     VARCHAR2(200);  
        l_job         VARCHAR2(1000);
        l_oracle_sid varchar2(20);
        l_oracle_home varchar2(100);
        l_xtts_dir dba_directories.directory_path%type;
        f utl_file.file_type;
        n PLS_INTEGER;
    BEGIN
         /*
          *  GET THE DIRECTORY PATH OF THE PDB$SEED CONTAINER. NEEDED FOR CREATE PLUGGABLE DATABASE AND AS THE DESTINATION FOR COPIED READ ONLY AIX DATAFILES.
          */
         SELECT dir_pdbseed, REPLACE(dir_pdbseed,'pdbseed',:p_PDBNAME)
           INTO l_dir_pdbseed, l_dir_pdb
           FROM (SELECT SUBSTR(f.name,1,INSTR(f.name,'/',-1)) dir_pdbseed FROM v$datafile f, v$pdbs p WHERE p.name='PDB$SEED' AND p.con_id=f.con_id AND ROWNUM=1);

         /*
          *  CLOSE AND DROP PDB IF ALREADY EXISTS - E.G. FROM A PREVIOUS FAILED MIGRATION
          *  NOTE THAT ANY PREVIOUSLY TRANSFERRED DATA FILES REMAIN IN THE FILE SYSTEM AFTER DROP IF NOT PLUGGED IN. DELETING THEM AVOIDS ERROR WHEN RE-COPYING FROM SOURCE.
          */
         SELECT COUNT(*) INTO n FROM dual WHERE EXISTS (SELECT NULL FROM V$PDBS WHERE name=:p_PDBNAME);
         IF (n>0) THEN
            exec('ALTER PLUGGABLE DATABASE '||:p_PDBNAME||' CLOSE IMMEDIATE');
            exec('DROP PLUGGABLE DATABASE '||:p_PDBNAME||' INCLUDING DATAFILES');
            --IF (p_DEL_UNPLUG) THEN
            --   exec('HOST rm -f -v '||l_dir_pdb||'*',NULL);
            --END IF;
         END IF;

         /*
          *  CREATE THE PLUGGABLE DATABASE WITH SAME NAME AS SOURCE AIX DATABASE NAME.
          */
         exec('CREATE PLUGGABLE DATABASE '||:p_PDBNAME||' ADMIN USER pdbadmin IDENTIFIED BY pwd1 FILE_NAME_CONVERT=('''||l_dir_pdbseed||''','''||l_dir_pdb||''')');

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
          *  PDBADMIN USER, WHICH WILL EVENTUALLY PERFORM THE IMPORT FROM SOURCE, NEEDS SMALL QUOTA IN SYSEM TABLESPACE FOR COUPLE OF ADMIN TABLES
          */
         exec('ALTER USER PDBADMIN QUOTA UNLIMITED ON SYSTEM');

        /*
         *  GRANT PRIVILEGES TO PDBADMIN IN ORDER FOR IT TO PERFORM FULL DATABASE EXPORT / IMPORT
         */
        exec('GRANT DATAPUMP_IMP_FULL_DATABASE, CREATE PUBLIC DATABASE LINK, CREATE ANY DIRECTORY, SELECT ANY DICTIONARY, CREATE TABLE, CREATE PROCEDURE, 
              CREATE MATERIALIZED VIEW, CREATE JOB, MANAGE SCHEDULER, ALTER SESSION, CREATE USER, ALTER USER, DROP USER, DROP ANY DIRECTORY, ANALYZE ANY DICTIONARY, 
              ANALYZE ANY, CREATE TABLESPACE, ALTER TABLESPACE, GRANT ANY PRIVILEGE TO PDBADMIN');
        exec('GRANT EXECUTE ON SYS.DBMS_BACKUP_RESTORE TO pdbadmin');
        exec('GRANT EXECUTE ON SYS.DBMS_FILE_TRANSFER TO pdbadmin');
        exec('GRANT EXECUTE ON SYS.DBMS_SYSTEM TO pdbadmin');

        /*
         *  1. XTTS DIRECTORY ALREADY CREATED IN VALIDATE PROCEDURE
         *  2. CREATE DIRECTORY POINTING TO LOCATION OF PDB DATA FILE
         */
        exec('CREATE OR REPLACE DIRECTORY XTTS AS '''||:p_TMPDIR||'''');
        exec('GRANT READ, WRITE ON DIRECTORY XTTS TO pdbadmin');
        exec('CREATE OR REPLACE DIRECTORY TGT_FILES_DIR AS '''||RTRIM(l_dir_pdb,'/')||''''); 
        exec('GRANT READ, WRITE ON DIRECTORY TGT_FILES_DIR TO pdbadmin');

        /*
         *  CREATE PUBLIC DATABASE LINK FOR NETWORK_LINK DATABASE IMPORT/EXPORT
         *  GLOBAL_NAMES=FALSE ALLOWS US TO USE OUR OWN NAME FOR THE DATABASE LINK (OTHERWISE WOULD BE FORCED TO USE AIX GLOBAL DB NAME).
         */
        exec('ALTER SESSION SET GLOBAL_NAMES=FALSE');
        exec('CREATE PUBLIC DATABASE LINK MIGR_DBLINK CONNECT TO '||:p_SRC_USER||' IDENTIFIED BY Dogface34 USING ''//'||:p_SRC_HOST||':'||:p_SRC_PORT||'/'||:p_SRC_SERVICE||'''');

        exec('ALTER SESSION SET CURRENT_SCHEMA=PDBADMIN');
        exec('CREATE TABLE migration_ts
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
               
        exec('CREATE TABLE migration_bp
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
                CONSTRAINT fk_migration_ts FOREIGN KEY(file_id) REFERENCES migration_ts(file_id))');               

        exec('CREATE GLOBAL TEMPORARY TABLE migration_temp
               ("OWNER"             VARCHAR2(30),
                "OBJECT_TYPE"       VARCHAR2(30),
                "OBJECT_NAME"       VARCHAR2(30),
                "TEXT"              CLOB)');  
                
        exec('CREATE SEQUENCE migration_log_seq START WITH 1 INCREMENT BY 1');

        exec('CREATE TABLE migration_log
               ("ID"            NUMBER DEFAULT migration_log_seq.NEXTVAL,
                "LOG_TIME"      DATE DEFAULT SYSDATE,
                "LOG_MESSAGE"   CLOB,
                CONSTRAINT PK_MIGRATION_LOG PRIMARY KEY(id))');
    END;
 
    --------------------------------------------------
    PROCEDURE setParameter(pParameter IN VARCHAR2) IS
        l_name varchar2(20);
        l_value varchar2(20);
        l_error varchar2(100):=NULL;
        l_file_exists NUMBER;
    BEGIN
        IF (pParameter IS NULL) THEN
            RETURN;
        END IF;

        l_name:=UPPER(SUBSTR(pParameter,1,INSTR(pParameter,'=')-1));
        IF (l_name<>'TMPDIR') THEN
            l_value:=UPPER(SUBSTR(pParameter,INSTR(pParameter,'=')+1));
        ELSE
            l_value:=SUBSTR(pParameter,INSTR(pParameter,'=')+1);
        END IF;

        CASE l_name

            WHEN 'USER'
                THEN :p_SRC_USER:=l_value;

            WHEN 'HOST'
                THEN :p_SRC_HOST:=l_value;
                
            WHEN 'PORT'
                THEN :p_SRC_PORT:=l_value;
                
            WHEN 'SERVICE'
                THEN :p_SRC_SERVICE:=l_value;

            WHEN 'PDBNAME' 
                THEN :p_PDBNAME:=l_value;

            WHEN 'TMPDIR' THEN 
                :p_TMPDIR:=RTRIM(l_value,'/');
                EXECUTE IMMEDIATE 'CREATE OR REPLACE DIRECTORY XTTS AS '''||:p_TMPDIR||'''';
                l_file_exists := DBMS_LOB.FILEEXISTS(BFILENAME('XTTS','.'));
                EXECUTE IMMEDIATE 'DROP DIRECTORY XTTS';
                IF ( l_file_exists<>1 ) THEN
                    RAISE_APPLICATION_ERROR(-20000,'DIRECTORY "'||l_value||'" DOES NOT EXIST. HAVE ANOTHER GO.');
                END IF;

            WHEN 'OVERRIDE' THEN 
                IF (l_value IN ('CONV-DB','XTTS-TS')) THEN
                    :p_OVERRIDE:=l_value;
                ELSE
                    l_error:='INVALID VALUE FOR PARAMETER:'||l_name||' - MUST BE [CONV-DB|XTTS-TS]';
                END IF;       

            WHEN 'ACTION' THEN 
                IF (l_value='FORCE-STOP') THEN
                    :p_FORCE_STOP:='TRUE';
                ELSIF (l_value='DEL-UNPLUG') THEN
                    :p_DEL_UNPLUG:='TRUE';
                ELSIF (l_value='RESTART') THEN
                    :p_RESTART:='TRUE';
                ELSIF (l_value='RUNJOB') THEN
                    :p_RUNJOB:='TRUE';                    
                ELSE
                    l_error:='INVALID VALUE FOR PARAMETER:'||l_name||' - MUST BE [FORCE-STOP|DEL-UNPLUG|RUNJOB|RESTART]';
                END IF;

            ELSE l_error:='INVALID PARAMETER:'||l_name;

        END CASE;

        IF (l_error IS NOT NULL) THEN
            RAISE_APPLICATION_ERROR(-20000,l_error);
        END IF;
    END;  
 
--------  START OF PL/SQL BLOCK -------
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
    
    IF (:p_RESTART='FALSE' AND :p_RUNJOB='FALSE') THEN
        create_pdb;
    END IF;
    exec('ALTER SESSION SET CONTAINER='||:p_PDBNAME);
    exec('ALTER SESSION SET CURRENT_SCHEMA=PDBADMIN');
END;
/
spool off

set feedback on
set echo on
@@tgt_migr_exec.sql

set echo off
create or replace PACKAGE pck_migration AS
    --
    PROCEDURE start_migration(pOverride IN VARCHAR2);
    --
    PROCEDURE log(pMessage IN VARCHAR2, pChar IN VARCHAR2 DEFAULT NULL);
    --
    PROCEDURE post_migration(pResetUser IN BOOLEAN);
    --
    PROCEDURE wrap_me;
END;
/

CREATE OR REPLACE PACKAGE BODY pck_migration wrapped 
a000000
369
abcd
abcd
abcd
abcd
abcd
abcd
abcd
abcd
abcd
abcd
abcd
abcd
abcd
abcd
abcd
b
ac8e 2faf
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
UqR8+TrQtUS5bM1s
/
show errors

/*
 *  CREATE SHELL SCRIPT TO BE EXECUTED "/as sysdba" AT END OF MIGRATION
 */
COLUMN tmpdir NEW_VALUE tmpdir noprint
select :p_TMPDIR tmpdir from dual;
host echo '#!/bin/bash'>&tmpdir/migration_job_sys.sh
host chmod u+x &tmpdir/migration_job_sys.sh


DECLARE
    l_migration_job_name VARCHAR2(30):='MIGRATION_JOB';
    l_action VARCHAR2(1000):='BEGIN pck_migration.start_migration(pOverride=>'''||:p_OVERRIDE||'''); END;';
    n PLS_INTEGER;
BEGIN
    /*
     *  STOP ANY PREVIOUS JOB THAT IS STILL RUNNING - MAY HAVE FAILED ON NETWORK ERROR FOR EXAMPLE WITHOUT RETURNING TO THE APPLICATION. USER MUST KNOW THIS
     *  AND USE FORCE-STOP PARAMETER TO AVOID INADVERTENTLY STOPPING A RUNNING MIGRATION JOB
     */
    SELECT COUNT(*) INTO n FROM dual WHERE EXISTS (SELECT NULL FROM dba_scheduler_jobs WHERE OWNER='PDBADMIN' AND job_name=l_migration_job_name);

    IF (n>0) THEN
        IF (:p_RUNJOB='TRUE') THEN
            dbms_output.put_line('About to DBMS_SCHEDULER.run_job');
            DBMS_SCHEDULER.run_job (job_name=>l_migration_job_name);
        ELSIF (:p_FORCE_STOP='TRUE') THEN
            dbms_output.put_line('About to DBMS_SCHEDULER.drop_job');
            DBMS_SCHEDULER.drop_job (job_name=>l_migration_job_name,force=>TRUE);
        END IF;
    ELSE
        dbms_output.put_line('About to DBMS_SCHEDULER.create_job');
        DBMS_SCHEDULER.create_job (job_name=>l_migration_job_name, job_type=>'PLSQL_BLOCK', start_date=>SYSTIMESTAMP, enabled=>TRUE, job_action=>l_action);
    END IF;
END;
/

set pagesize 0
set long 300
set longchunksize 300

SELECT TO_CHAR(log_time,'dd.mm.yyyy hh24:mi:ss') log_time, log_message FROM migration_log ORDER BY id;
prompt "ENTER / TO VIEW MIGRATION LOG"
