Rem 
Rem    NAME
Rem      src_migr.sql
Rem
Rem    DESCRIPTION
Rem      This script prepares the source database for migration either directly or by a process of continuous recovery.
Rem      This process has to work on all Oracle versions since 10, hence some of the code will appear somewhat peculiar (e.g. no use of LISTAGG)
Rem
Rem    COMMAND
Rem      sqlplus / as sysdba @src_migr.sql \
Rem         mode=[ANALYZE|EXECUTE|RESET-TS|INCR-TS|INCR-TS-FINAL] \
Rem         incr-ts-dir=DIRECTORY_PATH \
Rem         incr-ts-freq="freq=hourly; byminute=0; bysecond=0;"
Rem
Rem      Full details available at https://github.com/xsf3190/automigrate.git
Rem

WHENEVER SQLERROR EXIT

set serveroutput on size unlimited
set linesize 1000
set feedback off
set verify off
set echo off
set pagesize 0
set trimspool on

col 1 new_value 1
col 2 new_value 2
col 3 new_value 3
col 4 new_value 4

SELECT '' "1", '' "2", '' "3", '' "4" FROM dual WHERE 1=2;

set termout off
define 1
define 2
define 3
define 4
set termout on

variable p_dblink_user  VARCHAR2(30)
variable p_run_mode     VARCHAR2(20)
variable p_incr_ts_dir  VARCHAR2(100)
variable p_incr_ts_freq VARCHAR2(100)

spool src_migr_exec.sql

DECLARE
    TYPE DBLINK_USER_PRIVS IS TABLE OF VARCHAR2(50);

    l_privs DBLINK_USER_PRIVS:=DBLINK_USER_PRIVS(
        'SELECT ANY DICTIONARY','SELECT ON SYS.USER$','SELECT ON SYS.TRANSPORT_SET_VIOLATIONS',
        'DATAPUMP_EXP_FULL_DATABASE','EXP_FULL_DATABASE','CREATE SESSION','ALTER TABLESPACE','CREATE ANY DIRECTORY','DROP ANY DIRECTORY','CREATE JOB','MANAGE SCHEDULER',
        'EXECUTE ON SYS.DBMS_BACKUP_RESTORE',
        'EXECUTE ON SYS.DBMS_TTS',
        'EXECUTE ON SYS.DBMS_SYSTEM');
    
    l_ddl LONG;
    
    n PLS_INTEGER;
 
    -------------------------------
    PROCEDURE exec(pCommand IN VARCHAR2) IS
        l_log LONG;
        l_now VARCHAR2(30):='Rem '||TO_CHAR(SYSDATE,'MM.DD.YYYY HH24:MI:SS')||' - ';
        user_exists EXCEPTION;
        PRAGMA EXCEPTION_INIT(user_exists,-1920);
        table_exists EXCEPTION;
        PRAGMA EXCEPTION_INIT(table_exists,-955);  
        eol PLS_INTEGER;
    BEGIN
        eol:=INSTR(pCommand,CHR(10));
        IF (eol>0) THEN
            l_log:='About to ... '||SUBSTR(pCommand,1,eol-1);
        ELSE
            l_log:='About to ... '||pCommand;
        END IF;
        EXECUTE IMMEDIATE pCommand;
        dbms_output.put_line(l_now||l_log||' ...OK');
        EXCEPTION 
            WHEN user_exists OR table_exists THEN
                dbms_output.put_line(l_now||l_log||' ...ALREADY EXISTS');
            WHEN OTHERS THEN 
                dbms_output.put_line(l_now||'*****************');
                dbms_output.put_line(l_now||l_log||' ...FAILED');
                dbms_output.put_line(l_now||'*****************');
                RAISE;    
    END;
    
    -------------------------------
    PROCEDURE remove_apex IS
        n PLS_INTEGER:=0;
        l_oracle_home VARCHAR2(100);
        l_file_exists NUMBER;
        table_notexists EXCEPTION;
        PRAGMA EXCEPTION_INIT(table_notexists,-942);
    BEGIN
        BEGIN
            EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM dual WHERE EXISTS (SELECT NULL FROM apex_workspace_activity_log)' INTO n;
            EXCEPTION
                WHEN table_notexists THEN NULL;
        END;
        IF (n=0) THEN
            sys.dbms_system.get_env('ORACLE_HOME',l_oracle_home);
            exec('CREATE OR REPLACE DIRECTORY DELETEITLATER AS '''||l_oracle_home||'/rdbms/admin/apex''');
            l_file_exists:=DBMS_LOB.FILEEXISTS(BFILENAME('DELETEITLATER','.'));
            exec('DROP DIRECTORY DELETEITLATER');
            IF ( l_file_exists=1 ) THEN
                dbms_output.put_line('@?/apex/apxremov.sql');
            END IF;
        END IF;
    END;
    
    -------------------------------
    PROCEDURE remove_backups IS
        f utl_file.file_type;
        l_cmdfile VARCHAR2(50):='remove_backups.rman';
    BEGIN
        f:=utl_file.fopen(location=>'MIGRATION_FILES_1_DIR', filename=>l_cmdfile, open_mode=>'w', max_linesize=>32767);
        utl_file.put_line(f,'connect target /');
        utl_file.put_line(f,'DELETE NOPROMPT COPY TAG=''INCR-TS'';'); 
        utl_file.put_line(f,'DELETE NOPROMPT BACKUP TAG=''INCR-TS'';');
        utl_file.put_line(f,'exit');
        utl_file.fclose(f);
        FOR C IN (SELECT directory_path FROM dba_directories WHERE directory_name='MIGRATION_FILES_1_DIR') LOOP
            dbms_output.put_line('host rman cmdfile='||C.directory_path||'/'||l_cmdfile||' log='||C.directory_path||'/'||l_cmdfile||'.log');
        END LOOP;
        EXCEPTION 
            WHEN OTHERS THEN 
                utl_file.fclose(f); 
                RAISE;
    END;
 
    -------------------------------
    PROCEDURE setParameter(pParameter IN VARCHAR2) IS
        l_name  varchar2(20);
        l_value varchar2(100);
        l_error varchar2(500);
    BEGIN
        IF (pParameter IS NULL) THEN
            RETURN;
        END IF;

        l_name:=UPPER(SUBSTR(pParameter,1,INSTR(pParameter,'=')-1));
        IF (l_name<>'INCR-TS-DIR') THEN
            l_value:=UPPER(SUBSTR(pParameter,INSTR(pParameter,'=')+1));
        ELSE
            l_value:=SUBSTR(pParameter,INSTR(pParameter,'=')+1);
        END IF;

        CASE l_name
            WHEN 'USER' THEN
                :p_dblink_user:=l_value;
            WHEN 'MODE' THEN 
                IF (l_value IN ('ANALYZE','EXECUTE','REMOVE','RESET','INCR-TS','INCR-TS-FINAL')) THEN 
                    :p_run_mode:=l_value;
                ELSE
                    l_error:='INVALID VALUE FOR PARAMETER:'||l_name||' - MUST BE ONE OF [ANALYZE|EXECUTE|REMOVE|RESET|INCR-TS|INCR-TS-FINAL]';
                END IF;
            WHEN 'INCR-TS-DIR' THEN 
                :p_incr_ts_dir:=l_value;
            WHEN 'INCR-TS-FREQ' THEN 
                :p_incr_ts_freq:=l_value;
            ELSE 
                l_error:='INVALID PARAMETER: '||l_name;
        END CASE;

        IF (l_error IS NOT NULL) THEN
            RAISE_APPLICATION_ERROR(-20000,l_error);
        END IF;    
    END;  

-----
BEGIN
    /*
     *   SET DEFAULTS
     */
    :p_dblink_user:='SNFTRANSFER';
    :p_run_mode:='ANALYZE';
    :p_incr_ts_freq:='freq=hourly; byminute=0; bysecond=0;';
    
    setParameter('&1');
    setParameter('&2');
    setParameter('&3');
    setParameter('&4');
    
    IF (:p_run_mode='REMOVE') THEN
        exec('DROP USER '||:p_dblink_user||' CASCADE');
        remove_backups;
        FOR C IN (SELECT directory_name FROM dba_directories WHERE REGEXP_LIKE(directory_name,'MIGRATION_FILES_[1-9]+_DIR')) LOOP
            exec('DROP DIRECTORY '||C.directory_name);
        END LOOP;
        dbms_output.put_line('EXIT');
        RETURN;
    END IF;
    
    SELECT COUNT(*) INTO n FROM dual WHERE EXISTS (SELECT NULL FROM dba_users WHERE username=:p_dblink_user);
    IF (n=0) THEN
        exec('CREATE USER '||:p_dblink_user||' IDENTIFIED BY Dogface34 DEFAULT TABLESPACE SYSTEM QUOTA 10M ON SYSTEM');
        exec('REVOKE INHERIT PRIVILEGES ON USER '||:p_dblink_user||' FROM PUBLIC');
    END IF;
    FOR i IN 1..l_privs.COUNT LOOP
        exec('GRANT '||l_privs(i)||' TO '||:p_dblink_user);
    END LOOP;
    
    exec('ALTER SESSION SET CURRENT_SCHEMA='||:p_dblink_user);
    
    l_ddl:=q'{CREATE OR REPLACE VIEW V_APP_TABLESPACES AS
              SELECT tablespace_name, status, file_id, SUBSTR(file_name,1,pos-1) directory_name, SUBSTR(file_name,pos+1) file_name, enabled, bytes 
              FROM
                (
                SELECT t.tablespace_name, t.status, f.file_id, f.file_name,INSTR(f.file_name,'/',-1) pos, f.bytes, v.enabled
                  FROM dba_tablespaces t, dba_data_files f, v$datafile v
                 WHERE t.tablespace_name=f.tablespace_name
                   AND v.file#=f.file_id
                   AND t.contents='PERMANENT'
                   AND t.tablespace_name NOT IN ('SYSTEM','SYSAUX')
                   )}';
    exec(l_ddl);
    
    l_ddl:=q'{CREATE TABLE migration_ts(
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
                CONSTRAINT pk_migration_ts PRIMARY KEY(file#) )}';
    exec(l_ddl);

    --dbms_output.put_line('@@pck_migration_src.sql');
    dbms_output.put_line('spool src_migr.log');
    --dbms_output.put_line('exec pck_migration_src.init_migration(p_run_mode=>:p_run_mode, p_incr_ts_dir=>:p_incr_ts_dir, p_incr_ts_freq=>:p_incr_ts_freq)');
    
    IF (:p_run_mode IN ('EXECUTE','INCR-TS-FINAL')) THEN
        remove_apex;
        FOR C IN (SELECT object_name FROM dba_objects WHERE object_type='SYNONYM' AND owner='PUBLIC' AND object_name='DBA_RECYCLEBIN') LOOP
            exec('PURGE DBA_RECYCLEBIN');
        END LOOP;
    END IF;
END;
/

spool off

@@src_migr_exec.sql

CREATE OR REPLACE PACKAGE pck_migration_src AS
    --
    PROCEDURE init_migration (
        p_run_mode in VARCHAR2,
        p_incr_ts_dir in VARCHAR2, 
        p_incr_ts_freq in VARCHAR2);
    --
    PROCEDURE p_incr_ts;
    --
    PROCEDURE incr_job(pAction in VARCHAR2, p_incr_ts_freq in VARCHAR2 DEFAULT NULL);
    --
END;
/

CREATE OR REPLACE PACKAGE BODY pck_migration_src wrapped 
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
4e58 1b33
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
5DC5cDaAHL/oRrRPtc5Js3iARw==
/

show errors

exec pck_migration_src.init_migration(p_run_mode=>:p_run_mode, p_incr_ts_dir=>:p_incr_ts_dir, p_incr_ts_freq=>:p_incr_ts_freq)

EXIT