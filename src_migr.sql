Rem 
Rem    NAME
Rem      src_migr.sql
Rem
Rem    DESCRIPTION
Rem      This script prepares the source database for migration either directly or by a process of continuous recovery.
Rem      Since the script must work on all Oracle versions >= 10, some of the code in unavoidably cumbersome - e.g. cannot use LISTAGG
Rem
Rem    COMMAND
Rem      sqlplus / as sysdba @src_migr.sql \
Rem         mode=[ANALYZE|EXECUTE|RESET|REMOVE|INCR-TS] \
Rem         incr-ts-dir=DIRECTORY_PATH \
Rem         incr-ts-freq="freq=hourly; byminute=0; bysecond=0;"
Rem
Rem      Full documentation at https://github.com/xsf3190/automigrate.git
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

variable p_dblink_user  VARCHAR2(30)=MIGRATION
variable p_run_mode     VARCHAR2(20)=ANALYZE
variable p_incr_ts_dir  VARCHAR2(100)
variable p_incr_ts_freq VARCHAR2(100)=freq=hourly; byminute=0; bysecond=0;

spool src_migr_exec.sql

DECLARE
    TYPE DBLINK_USER_PRIVS IS TABLE OF VARCHAR2(50);

    l_privs DBLINK_USER_PRIVS:=DBLINK_USER_PRIVS(
        'SELECT ANY DICTIONARY','SELECT ON SYS.USER$','SELECT ON SYS.TRANSPORT_SET_VIOLATIONS',
        'DATAPUMP_EXP_FULL_DATABASE','EXP_FULL_DATABASE',
        'CREATE SESSION','ALTER TABLESPACE','CREATE ANY DIRECTORY','DROP ANY DIRECTORY','CREATE JOB','MANAGE SCHEDULER',
        'EXECUTE ON SYS.DBMS_BACKUP_RESTORE',
        'EXECUTE ON SYS.DBMS_TTS',
        'EXECUTE ON SYS.DBMS_SYSTEM');
    
    l_schema_exists BOOLEAN;
    
    l_pw VARCHAR2(10):=DBMS_RANDOM.string('x',5)||DBMS_RANDOM.string('a',4)||'!';
 
    n PLS_INTEGER;
    
    -------------------------------
    PROCEDURE exec(pCommand IN VARCHAR2) IS
    BEGIN
        dbms_output.put_line(pCommand);  
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
            execute immediate 'CREATE OR REPLACE DIRECTORY DELETEITLATER AS '''||l_oracle_home||'/rdbms/admin/apex''';
            l_file_exists:=DBMS_LOB.FILEEXISTS(BFILENAME('DELETEITLATER','.'));
            execute immediate 'DROP DIRECTORY DELETEITLATER';
            IF ( l_file_exists=1 ) THEN
                exec('Rem DROP UNUSED APEX');
                exec('@?/apex/apxremov.sql');
            END IF;
        END IF;
    END;
    
    -------------------------------
    PROCEDURE remove_backups(pDirectoryPath in dba_directories.directory_path%type) IS
        f utl_file.file_type;
        l_cmdfile VARCHAR2(50):='remove_backups.rman';
    BEGIN
        f:=utl_file.fopen(location=>'MIGRATION_FILES_1_DIR', filename=>l_cmdfile, open_mode=>'w', max_linesize=>32767);
        utl_file.put_line(f,'connect target /');
        utl_file.put_line(f,'DELETE NOPROMPT COPY TAG=''INCR-TS'';'); 
        utl_file.put_line(f,'DELETE NOPROMPT BACKUP TAG=''INCR-TS'';');
        utl_file.put_line(f,'exit');
        utl_file.fclose(f);
        dbms_output.put_line('host rman cmdfile='||pDirectoryPath||'/'||l_cmdfile||' log='||pDirectoryPath||'/'||l_cmdfile||'.log');
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
    setParameter('&1');
    setParameter('&2');
    setParameter('&3');
    setParameter('&4');
    
    exec('set feedback on');
    exec('set verify on');
    exec('set echo on');
    
    SELECT COUNT(*) INTO n FROM dual WHERE EXISTS (SELECT NULL FROM dba_users WHERE username=:p_dblink_user);
    l_schema_exists:=(n=1);
    
    IF (:p_run_mode='REMOVE') THEN
        exec('DROP USER '||:p_dblink_user||' CASCADE;');
        FOR C IN (SELECT directory_name, directory_path FROM dba_directories WHERE REGEXP_LIKE(directory_name,'MIGRATION_FILES_[1-9]+_DIR')) LOOP
            IF (C.directory_name='MIGRATION_FILES_1_DIR') THEN
                remove_backups(C.directory_path);
            END IF;
            exec('DROP DIRECTORY '||C.directory_name||';');
        END LOOP;
        dbms_output.put_line('EXIT');
        RETURN;
    END IF;
    
    IF NOT (l_schema_exists) THEN
        exec('CREATE USER '||:p_dblink_user||' IDENTIFIED BY "'||l_pw||'" DEFAULT TABLESPACE SYSTEM QUOTA 10M ON SYSTEM;');
        FOR i IN 1..l_privs.COUNT LOOP
            exec('GRANT '||l_privs(i)||' TO '||:p_dblink_user||';');
        END LOOP;
        exec('ALTER SESSION SET CURRENT_SCHEMA='||:p_dblink_user||';');
        
        exec('CREATE TABLE MIGRATION_INIT AS SELECT '''||l_pw||''' password FROM DUAL;');
        
        exec(q'{CREATE OR REPLACE VIEW V_APP_TABLESPACES AS
                  SELECT tablespace_name, status, file_id, SUBSTR(file_name,1,pos-1) directory_name, SUBSTR(file_name,pos+1) file_name, enabled, bytes 
                  FROM
                    (
                    SELECT t.tablespace_name, t.status, f.file_id, f.file_name,INSTR(f.file_name,'/',-1) pos, f.bytes, v.enabled
                      FROM dba_tablespaces t, dba_data_files f, v$datafile v
                     WHERE t.tablespace_name=f.tablespace_name
                       AND v.file#=f.file_id
                       AND t.contents='PERMANENT'
                       AND t.tablespace_name NOT IN ('SYSTEM','SYSAUX')
                       );}');
        
        exec(q'{CREATE TABLE migration_ts(
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
                    CONSTRAINT pk_migration_ts PRIMARY KEY(file#) );}');
        exec('set echo off');
        exec('@@pck_migration_src');
        exec('set echo on');
        exec('show errors');
    END IF;
    
    exec('exec '||:p_dblink_user||'.pck_migration_src.init_migration(p_run_mode=>:p_run_mode, p_incr_ts_dir=>:p_incr_ts_dir, p_incr_ts_freq=>:p_incr_ts_freq)');
    
    IF (:p_run_mode IN ('EXECUTE','INCR-TS-FINAL')) THEN
        remove_apex;
        FOR C IN (SELECT object_name FROM dba_objects WHERE object_type='SYNONYM' AND owner='PUBLIC' AND object_name='DBA_RECYCLEBIN') LOOP
            exec('PURGE DBA_RECYCLEBIN;');
        END LOOP;
    END IF;
    
    exec('EXIT');
END;
/

spool off

@@src_migr_exec.sql
