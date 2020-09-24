CREATE OR REPLACE PACKAGE pck_migration_src AS
    --
    PROCEDURE init_migration (
        p_run_mode in VARCHAR2 DEFAULT 'ANALYZE',
        p_ip_address in VARCHAR2 DEFAULT NULL,
        p_incr_ts_dir in VARCHAR2 DEFAULT NULL,
        p_incr_ts_freq in VARCHAR2 DEFAULT NULL);
    --
    PROCEDURE p_incr_ts;
    --
    PROCEDURE set_ts_readwrite;
    --
    PROCEDURE incr_job(pAction in VARCHAR2, p_incr_ts_freq in VARCHAR2 DEFAULT NULL);
    --
    PROCEDURE uploadLog(pFilename IN VARCHAR2);
    --
    FUNCTION getDefaultServiceName RETURN VARCHAR2;
    --
END;
/

CREATE OR REPLACE PACKAGE BODY pck_migration_src AS
/*
    NAME
      pck_migration_src

    DESCRIPTION
      This package is called from "runMigration.sh" to prepare the database for migration either directly or by a process of continuous recovery.

      Full details available at https://github.com/xsf3190/automigrate.git
*/

    TTS_CHECK_FAILED EXCEPTION;

    -------------------------------
    PROCEDURE log(pLine IN VARCHAR2, pChar IN VARCHAR2 DEFAULT NULL) IS
        l_now VARCHAR2(25):=TO_CHAR(SYSDATE,'MM.DD.YYYY HH24:MI:SS')||' - ';
    BEGIN
        IF (pChar IS NULL) THEN
            dbms_output.put_line(l_now||pLine);
        ELSE
            dbms_output.put_line(l_now||RPAD(pChar,LENGTH(pLine),pChar));
            dbms_output.put_line(l_now||pLine);
            dbms_output.put_line(l_now||RPAD(pChar,LENGTH(pLine),pChar));
        END IF;
    END;

    -------------------------------
    PROCEDURE exec(pCommand IN VARCHAR2) IS
        l_log LONG;
        user_exists EXCEPTION;
        PRAGMA EXCEPTION_INIT(user_exists,-1920);
    BEGIN
        l_log:='About to ... '||pCommand;
        EXECUTE IMMEDIATE pCommand;
        log(l_log||' ...OK');
        EXCEPTION
            WHEN user_exists THEN NULL;
            WHEN OTHERS THEN
                log(l_log||' ...FAILED');
                RAISE;
    END;

    -------------------------------
    PROCEDURE fileToClob(pFilename IN VARCHAR2, pClob IN OUT NOCOPY CLOB) IS
        l_bfile   BFILE;
        d_offset  NUMBER := 1;
        s_offset  NUMBER := 1;
        l_csid    NUMBER := 0;
        l_lang    NUMBER := 0;
        l_warning NUMBER;
    BEGIN
        l_bfile:=bfilename('MIGRATION_SCRIPT_DIR',pFilename);
        dbms_lob.fileopen(l_bfile, dbms_lob.file_readonly);
        dbms_lob.loadclobfromfile(pClob, l_bfile, DBMS_LOB.lobmaxsize, d_offset,s_offset,l_csid, l_lang, l_warning);
        dbms_lob.fileclose(l_bfile);
    END;

    --
    -- PROCEDURE uploadLog
    --   Inserts OS file as log message row in table migration_log.
    --   Delete OS file to avoid exposing passwords at OS level
    --
    -------------------------------
    PROCEDURE uploadLog(pFilename IN VARCHAR2) IS
        l_clob    CLOB;
    BEGIN
        INSERT INTO migration_log (id, log_message) VALUES (migration_log_seq.nextval, empty_clob()) RETURN log_message INTO l_clob;
        fileToClob(pFilename,l_clob);
        COMMIT;
        utl_file.fremove(location=>'MIGRATION_SCRIPT_DIR', filename=>pFilename);
    END;

    -------------------------------
    FUNCTION version(pVersion IN VARCHAR2) RETURN NUMBER IS
        l_version_2 VARCHAR2(20):=pVersion;
        l_version_n NUMBER;
        l_dots INTEGER:=LENGTH(pVersion)-LENGTH( REPLACE( pVersion, '.' ));
    BEGIN
        /*
         *  Convert Oracle version string into a number.  Nb. first, convert for example "12.1" to "12.1.0.0.0" to ensure correct calculation
         */
        FOR i IN l_dots..3 LOOP
            l_version_2:=l_version_2||'.0';
        END LOOP;
        SELECT SUM(v*POWER(10,n))
        INTO l_version_n
        FROM
            (
            SELECT REGEXP_SUBSTR(l_version_2,'[^.]+', 1, level) v, ROW_NUMBER() OVER (ORDER BY LEVEL DESC) n
              FROM dual
            CONNECT BY REGEXP_SUBSTR(l_version_2, '[^.]+', 1, level) IS NOT NULL
            );
        RETURN(l_version_n);
    END;

    -------------------------------
    FUNCTION getDefaultServiceName RETURN VARCHAR2 IS
        l_service_name v$services.name%type;
    BEGIN
        l_service_name:='**TO_BE_PROVIDED**';
        FOR C IN (
                    WITH dflt AS
                    (
                    SELECT p1.value||NVL2(p2.value,'.'||p2.value,null) service_name
                    FROM v$parameter p1, v$parameter p2
                    WHERE p1.name='db_name'
                    AND p2.name='db_domain'
                    )
                    SELECT s.name
                    FROM v$services s, dflt d
                    WHERE s.name=d.service_name
                )
        LOOP
            l_service_name:=C.name;
        END LOOP;
        RETURN (l_service_name);
    END;

    -------------------------------
    PROCEDURE log_details(pRunMode IN VARCHAR2, pVersion IN VARCHAR2, pCompatibility IN VARCHAR2, pIpAddress IN VARCHAR2, p_running_incr BOOLEAN) IS
        l_apex varchar2(100);
        l_bct_status v$block_change_tracking.status%type;
        l_characterset varchar2(20);
        l_clob clob;
        l_db_name v$database.name%type;
        l_hash_runmigration varchar2(40);
        l_hash_pck_migration_src varchar2(40);
        l_host_name v$instance.host_name%type;
        l_log_mode v$database.log_mode%type;
        l_migration_method VARCHAR2(21);
        l_migration_explained VARCHAR2(200);
        l_oracle_sid varchar2(30);
        l_oracle_pdb_sid varchar2(30);
        l_oracle_home varchar2(100);
        l_platform v$database.platform_name%type;
        l_rman_incr_xtts VARCHAR2(100);
        l_running_execute BOOLEAN;
        l_running_incr_ts BOOLEAN;
        l_service_name v$services.name%type;
        l_this_version NUMBER:=version(pVersion);
        l_tns_admin varchar2(100);
        l_total_bytes number:=0;
        l_ts_list_rw LONG:=NULL;
        l_ts_list_ro LONG:=NULL;

        l_job_action LONG;

        table_notexists EXCEPTION;
        PRAGMA EXCEPTION_INIT(table_notexists,-942);
        n PLS_INTEGER:=0;
    BEGIN
        dbms_lob.createtemporary(lob_loc => l_clob, cache => true, dur => dbms_lob.call);
        fileToClob('runMigration.sh',l_clob);
        l_hash_runmigration:=dbms_crypto.hash(l_clob,dbms_crypto.hash_sh1);
        dbms_lob.freetemporary(lob_loc => l_clob);

        dbms_lob.createtemporary(lob_loc => l_clob, cache => true, dur => dbms_lob.call);
        fileToClob('pck_migration_src.sql',l_clob);
        l_hash_pck_migration_src:=dbms_crypto.hash(l_clob,dbms_crypto.hash_sh1);
        dbms_lob.freetemporary(lob_loc => l_clob);

        sys.dbms_system.get_env('ORACLE_PDB_SID',l_oracle_pdb_sid);
        sys.dbms_system.get_env('ORACLE_SID',l_oracle_sid);
        sys.dbms_system.get_env('ORACLE_HOME',l_oracle_home);
        sys.dbms_system.get_env('TNS_ADMIN',l_tns_admin);

        IF (l_tns_admin IS NULL) THEN
            l_tns_admin:=l_oracle_home||'/network/admin (DEFAULT)';
        END IF;

        SELECT d.name, i.host_name, d.log_mode, d.platform_name, p1.property_value
          INTO l_db_name, l_host_name, l_log_mode, l_platform, l_characterset
          FROM v$database d, v$instance i, database_properties p1, v$transportable_platform tp
         WHERE p1.property_name='NLS_CHARACTERSET'
           AND tp.platform_name=d.platform_name;

        l_bct_status:='DISABLED';
        FOR C IN (SELECT status FROM v$block_change_tracking) LOOP
            l_bct_status:=C.status;
        END LOOP;

        /*
         *  FULL TRANSPORTABLE DATABASE MIGRATION REQUIRES THAT SOURCE IS >= 11.2.0.3 ELSE WE DO TRANSPORTABLE TABLESPACE MIGRATION
         *  MINIMUM SOURCE REQUIREMENT FOR XTTS IS VERSION: 10.1.0.3  COMPATIBILITY: 10.0
         */
        IF (l_this_version >= version('11.2.0.3')) THEN
            l_migration_method:='XTTS_DB';
            l_migration_explained:='VERSION >= 11.2.0.3  => OPTIMAL MIGRATION IS FULL TRANSPORTABLE DATABASE';
        ELSIF (l_this_version >= version('10.1.0.3') AND version(pCompatibility)>=version('10')) THEN
            l_migration_method:='XTTS_TS';
            l_migration_explained:='VERSION >= 10.1.0.3 AND < 11.2.0.3  => OPTIMAL MIGRATION IS TRANSPORTABLE TABLESPACE';
        END IF;

        FOR C IN (SELECT DISTINCT status, tablespace_name, SUM(bytes) OVER() total_bytes FROM v_app_tablespaces) LOOP
            IF (C.status='ONLINE') THEN
                l_ts_list_rw:=l_ts_list_rw||C.tablespace_name||',';
            ELSIF (C.status='READ ONLY') THEN
                l_ts_list_ro:=l_ts_list_ro||C.tablespace_name||',';
            END IF;
            l_total_bytes:=C.total_bytes;
        END LOOP;

        IF (l_log_mode='ARCHIVELOG' AND l_bct_status<>'DISABLED') THEN
            l_rman_incr_xtts:='OK';
            IF (p_running_incr) THEN
                l_rman_incr_xtts:=l_rman_incr_xtts||' - PROCESS RUNNING';
            END IF;
        ELSE
            l_rman_incr_xtts:='NOK - DATABASE MUST BE ARCHIVELOG AND BLOCK CHANGE TRACKING ENABLED';
        END IF;

        /*
         *  SIGNAL WARNING IF NO DEFAULT LISTENING SERVICE
         */
        l_service_name:=getDefaultServiceName();

        /*
         *  SIGNAL IF APEX INSTALLED BUT NOT USED
         */
        l_apex:='APEX NOT INSTALLED OR NOT USED';
        FOR C IN (SELECT version FROM dba_registry WHERE comp_id='APEX') LOOP
            EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM dual WHERE EXISTS (SELECT NULL FROM apex_applications WHERE workspace<>''INTERNAL'')' INTO n;
            IF (n>0) THEN
                l_apex:='APEX APPLICATIONS MUST BE EXPORTED/IMPORTED INTO TARGET PDB, WHICH NEEDS MINIMUM APEX INSTALLATION VERSION 18.2';
            END IF;
        END LOOP;

        log('             DATABASE MIGRATION','-');
        log('             RUN MODE : '||pRunMode);
        log('           ORACLE_SID : '||l_oracle_sid);
        log('      runMigration.sh : '||l_hash_runmigration||' (SHA-1)');
        log('pck_migration_src.sql : '||l_hash_pck_migration_src||' (SHA-1)');
        log('       ORACLE_PDB_SID : '||NVL(l_oracle_pdb_sid,'N/A'));
        log('          ORACLE_HOME : '||l_oracle_home);
        log('            TNS_ADMIN : '||l_tns_admin);
        log('             DATABASE : '||l_db_name);
        log('             LOG MODE : '||l_log_mode);
        log('              VERSION : '||pVersion);
        log('        COMPATIBILITY : '||pCompatibility);
        log('        CHARACTER SET : '||l_characterset);
        log('                 APEX : '||l_apex);
        log('             HOSTNAME : '||l_host_name);
        log(' DBLINK FOR MIGRATION : '||'USER='||SYS_CONTEXT('USERENV','CURRENT_SCHEMA')
                                      ||' HOST='||pIpAddress
                                      ||' SERVICE='||COALESCE(l_oracle_pdb_sid,l_service_name));
        log('        PLATFORM NAME : '||l_platform);
        log('        DATABASE SIZE : '||LTRIM(TO_CHAR(ROUND(l_total_bytes/1024/1024/1024,2),'999,999,990.00')|| ' GB'));
        log('BLOCK CHANGE TRACKING : '||l_bct_status);
        log('      TABLESPACES R/W : '||NVL(RTRIM(l_ts_list_rw,','),'-NONE-'));
        log('      TABLESPACES R/O : '||NVL(RTRIM(l_ts_list_ro,','),'-NONE-'));
        log('   INCREMENTAL BACKUP : '||l_rman_incr_xtts);
        log('     MIGRATION METHOD : '||l_migration_method);
        log('   METHOD EXPLANATION : '||l_migration_explained);

        /*
         *  DATABASE LINK ANALYSIS
         */
        SELECT COUNT(*) INTO n FROM dba_db_links WHERE owner<>'SYS';

        IF (n=0) THEN
            log('     DB LINK ANALYSIS : THERE ARE NO DB LINKS IN THIS DATABASE');
        ELSE
            log('     DB LINK ANALYSIS : THERE ARE '||n||' DB LINKS IN THIS DATABASE:');
        END IF;

        l_job_action:=q'{
        BEGIN
          FOR C IN (SELECT global_name, '#DBLINK#' db_link, '#OWNER#' owner, '#HOST#' host FROM global_name@#DBLINK#) LOOP
            DBMS_OUTPUT.put_line(TO_CHAR(SYSDATE,'MM.DD.YYYY HH24:MI:SS')||' -                       : GLOBAL_NAME:'||C.global_name||'; OWNER:'||C.owner||'; DBLINK:'||C.db_link||'; HOST:'||C.host||'; => OK');
          END LOOP;
        END;}';
        FOR C IN (SELECT owner || CASE WHEN owner='PUBLIC' THEN '_' ELSE '.' END ||'DBLINK' job_name, owner, db_link, host
            FROM dba_db_links
           WHERE owner<>'SYS'
           ORDER BY owner, db_link)
        LOOP
            DBMS_SCHEDULER.create_job (
                job_name     => C.job_name,
                job_type     => 'PLSQL_BLOCK',
                job_action   => REPLACE(REPLACE(REPLACE(l_job_action,'#DBLINK#',C.db_link),'#HOST#',C.host),'#OWNER#',C.owner)
            );

           BEGIN
               DBMS_SCHEDULER.run_job (C.job_name, TRUE);
           EXCEPTION
               WHEN OTHERS
               THEN
                   DBMS_OUTPUT.put_line(TO_CHAR(SYSDATE,'MM.DD.YYYY HH24:MI:SS')||' -                       : OWNER:'||C.owner||'; DBLINK:'||C.db_link||'; HOST:'||C.host||'; => NOK - '||SUBSTR(SQLERRM,1,INSTR(SQLERRM,CHR(10))-1));
           END;
           DBMS_SCHEDULER.drop_job (C.job_name);
        END LOOP;
    END;

    -------------------------------
    PROCEDURE check_tts_set IS
    /*
     *  CHECK TABLESPACES TO BE TRANSPORTED ARE SELF-CONTAINED - I.E NO APPLICATION SEGMENTS IN SYSTEM OR SYSAUX
     */
        l_ts_list LONG;
        n PLS_INTEGER:=0;
    BEGIN
        /*    USING DBMS_TTS - BUT I RECKON NOT NECESSARY SINCE WE MIGRATE ALL APPLICATION TABLESPACES
        FOR C IN (SELECT DISTINCT tablespace_name FROM v_app_tablespaces) LOOP
            l_ts_list:=l_ts_list||C.tablespace_name||',';
        END LOOP;

        SYS.dbms_tts.transport_set_check(ts_list=>RTRIM(l_ts_list,','),incl_constraints=>TRUE);
        FOR C IN (SELECT violations FROM SYS.transport_set_violations) LOOP
            n:=n+1;
            IF (n=1) THEN
                log('Following TTS CHECK violations detected');
            END IF;
            log(C.violations);
        END LOOP;

        IF (n>0) THEN
            log('Fix all violations before retrying migration');
            RAISE TTS_CHECK_FAILED;
        END IF;
        */

        FOR C IN (SELECT s.owner, s.segment_type, s.segment_name, s.tablespace_name
                    FROM dba_segments s, V_MIGRATION_USERS u
                   WHERE s.owner=u.username
                     AND u.oracle_maintained='N'
                     AND s.tablespace_name in ('SYSTEM','SYSAUX')
                   ORDER BY s.segment_type, s.owner)
        LOOP
            n:=n+1;
            IF (n=1) THEN
                log('TTS CHECK VIOLATIONS DETECTED - MOVE FOLLOWING INTO APPLICATION TABLESPACES','*');
            END IF;
            log(C.segment_type || ' ' ||C.owner || '.' || C.segment_name || ' IN TABLESPACE ' || C.tablespace_name );
        END LOOP;

        IF (n>0) THEN
            RAISE TTS_CHECK_FAILED;
        END IF;
    END;

    -------------------------------
    PROCEDURE set_ts_readwrite IS
    /*
     *  SET TABLESPACES BACK TO THEIR ORIGINAL STATUS. TYPICALLY DO THS AFTER AN XTT MIGRATION.
     */
        l_ddl VARCHAR2(100);
    BEGIN
        FOR C IN (SELECT DISTINCT m.tablespace_name, DECODE(m.pre_migr_status,'ONLINE','READ WRITE',m.pre_migr_status) pre_migr_status
                    FROM migration_ts m, dba_tablespaces t
                   WHERE m.tablespace_name=t.tablespace_name
                     AND m.pre_migr_status<>t.status)
        LOOP
            exec('ALTER TABLESPACE '||C.tablespace_name||' '||C.pre_migr_status);
        END LOOP;
        /*
         *  IN CASE SOMEONE DOES SUCCESSIVE MIGRATIONS OF SAME DATABASE...
         */
        DELETE migration_ts;
        COMMIT;
    END;

    -------------------------------
    PROCEDURE set_ts_readonly IS
    /*
     *  SET APPLICATION TABLESPACES TO READ ONLY. PRESERVE PRE_MIGRATION STATUS TO BE APPLIED POST MIGRATION.
     */
    BEGIN
        MERGE INTO migration_ts t
           USING v_app_tablespaces s
           ON (s.file_id=t.file#)
           WHEN MATCHED THEN UPDATE
               SET t.pre_migr_status=s.status, t.updated=SYSDATE
           WHEN NOT MATCHED THEN
               INSERT (t.file#, bytes, t.enabled, t.tablespace_name, t.pre_migr_status)
                VALUES (s.file_id, s.bytes, s.enabled, s.tablespace_name, s.status);

        FOR C IN (SELECT DISTINCT tablespace_name FROM v_app_tablespaces WHERE status='ONLINE')
        LOOP
            exec('ALTER TABLESPACE ' || C.tablespace_name || ' READ ONLY');
        END LOOP;
    END;

    -------------------------------
    PROCEDURE create_directory(p_incr_ts_dir in VARCHAR2 DEFAULT NULL) IS
    /*
     *  CREATE BACKUP DIRECTORY FOR INCREMENTAL BACKUP MIGRATION OR FOR EACH DISTINCT DATA FILE DIRECTORY.
     */
    BEGIN
        IF (p_incr_ts_dir IS NOT NULL) THEN
            exec('CREATE OR REPLACE DIRECTORY MIGRATION_FILES_1_DIR AS '''||p_incr_ts_dir||'''');
        ELSE
            FOR C IN (SELECT directory_name, ROWNUM rn FROM (SELECT DISTINCT directory_name FROM v_app_tablespaces)) LOOP
                exec('CREATE OR REPLACE DIRECTORY MIGRATION_FILES_'||C.rn||'_DIR AS '''||C.directory_name||'''');
            END LOOP;
        END IF;
    END;

    -------------------------------
    PROCEDURE incr_job(pAction in VARCHAR2, p_incr_ts_freq in VARCHAR2) IS
    /*
     *  CREATE OR RUN INCREMENTAL BACKUP JOB
     */
        l_job_name VARCHAR2(30):='MIGRATION_INCR';
    BEGIN
        CASE pAction
            WHEN 'CREATE' THEN
                dbms_scheduler.create_job(job_name=>l_job_name,
                                          job_type=>'PLSQL_BLOCK',
                                          start_date=>systimestamp,
                                          job_action=>'BEGIN pck_migration_src.p_incr_ts; END;',
                                          repeat_interval=>p_incr_ts_freq,
                                          enabled=>TRUE);
                dbms_scheduler.set_attribute(name=>l_job_name, attribute=>'RESTARTABLE', value=>TRUE);
            WHEN 'RUN' THEN
                dbms_scheduler.run_job(job_name=>l_job_name, use_current_session=>FALSE);
            WHEN 'DROP' THEN
                dbms_scheduler.drop_job(job_name=>l_job_name, force=>TRUE);
        END CASE;
    END;


    -------------------------------
    /*
     *  THIS PROCEDURE IS CALLED BY INCREMENTAL BACKUP JOB. FILE IMAGE COPIES ALWAYS MADE BEFORE INCREMENTAL BACKUPS.
     */
    PROCEDURE p_incr_ts IS
        d VARCHAR2(50);
        l_tag VARCHAR2(50):='INCR-TS';
        l_full_name VARCHAR2(100);
        l_stamp NUMBER;
        l_recid NUMBER;
        l_dir_path dba_directories.directory_path%type;
        l_set_stamp NUMBER;
        l_set_count NUMBER;
        l_pieceno NUMBER;
        l_done BOOLEAN;
        l_handle VARCHAR2(100);
        l_comment VARCHAR2(100);
        l_media VARCHAR2(100);
        l_concur BOOLEAN;
        l_started DATE;
        l_incr_fname VARCHAR2(200);
        l_last_backup BOOLEAN:=FALSE;
        -----------------------------
        PROCEDURE dblog(pMessage IN VARCHAR2) IS
        BEGIN
            INSERT INTO migration_log (id, log_message) VALUES (migration_log_seq.nextval, pMessage);
            COMMIT;
        END;
    BEGIN
        SELECT directory_path||'/' INTO l_dir_path FROM dba_directories WHERE directory_name='MIGRATION_FILES_1_DIR';
        --
        SELECT SYSDATE INTO l_started FROM dual;
        --
        FOR C IN (SELECT file_id, file_name FROM v_app_tablespaces d
                   WHERE NOT EXISTS (SELECT null FROM v$datafile_copy dc WHERE dc.file#=d.file_id AND dc.tag=l_tag AND dc.status='A'))
        LOOP

            dblog('Starting File Image Copy of datafile '||C.file_id||' - '||C.file_name);
            d := sys.dbms_backup_restore.deviceAllocate;
            sys.dbms_backup_restore.copyDataFile(dfnumber=>C.file_id, fname=>l_dir_path||C.file_name, full_name=>l_full_name, recid=>l_recid, stamp=>l_stamp, tag=>l_tag);
            sys.dbms_backup_restore.deviceDeallocate;
        END LOOP;
        --
        FOR C IN (SELECT file#, from_scn, enabled, COUNT(*) OVER () nb, SUM(CASE WHEN enabled='READONLY' THEN 1 ELSE 0 END) OVER () nb_ro
                  FROM
                    (
                    SELECT incr.file#, incr.from_scn, REPLACE(d.enabled,' ','') enabled
                      FROM migration_ts incr, v$datafile d
                     WHERE incr.file#=d.file#
                       AND d.checkpoint_change#>incr.from_scn
                    )
                  )
        LOOP
            IF (C.nb=C.nb_ro) THEN
                l_last_backup:=TRUE;
            END IF;
            l_incr_fname:=l_dir_path||'INCR_'||C.file#||'_'||C.from_scn||'_'||C.enabled;
            dblog('Starting Incremental Backup of datafile - creating backup piece '||l_incr_fname);
            d := sys.dbms_backup_restore.deviceAllocate;
            sys.dbms_backup_restore.backupSetDatafile( set_stamp=>l_set_stamp, set_count=>l_set_count, tag=>l_tag, incremental=>TRUE, backup_level=>1);
            sys.dbms_backup_restore.backupDataFile( dfnumber=>C.file#, since_change=>C.from_scn);
            sys.dbms_backup_restore.backupPieceCreate(fname=>l_incr_fname, pieceno=>l_pieceno, done=>l_done, handle=>l_handle, comment=>l_comment, media=>l_media, concur=>l_concur);
            sys.dbms_backup_restore.backupCancel;
            sys.dbms_backup_restore.deviceDeallocate;
        END LOOP;

        MERGE INTO migration_ts t
            USING
            (
                SELECT t.name tablespace_name, d.file#, d.bytes, d.enabled,
                        CASE WHEN dc.completion_time<l_started THEN d.checkpoint_change# ELSE dc.checkpoint_change# END checkpoint_change#
                  FROM v$datafile d, v$datafile_copy dc, v$tablespace t
                 WHERE d.file#=dc.file#
                   AND dc.tag=l_tag
                   AND dc.status='A'
                   AND t.ts#=d.ts#
            ) s
            ON (t.file#=s.file#)
            WHEN MATCHED THEN
                UPDATE SET t.from_scn=s.checkpoint_change#, t.bytes=s.bytes, t.enabled=s.enabled, t.tablespace_name=s.tablespace_name, t.updated=SYSDATE
            WHEN NOT MATCHED THEN
                INSERT (tablespace_name, file#, bytes, enabled, from_scn)
                VALUES (s.tablespace_name, s.file#, s.bytes, s.enabled, s.checkpoint_change#);
        COMMIT;

        IF (l_last_backup) THEN
            dblog('ALL TABLESPACES SET READ ONLY - DROPPING MIGRATION_INCR JOB.');
            pck_migration_src.incr_job(pAction=>'DROP');
        END IF;
    END;

    -------------------------------
    PROCEDURE validate(p_run_mode in VARCHAR2, p_incr_ts_dir in VARCHAR2, p_running_incr IN BOOLEAN) IS
        l_file_exists NUMBER;
        l_error VARCHAR2(100);
        n PLS_INTEGER;
        TB2 CONSTANT integer :=2*POWER(1024,4);
    BEGIN
        /*
         *  ABORT IF TABLESPACES ARE NOT KOSHER FOR MIGRATION
         */
        FOR C IN (SELECT file_name,bytes, ROW_NUMBER() OVER (PARTITION BY file_name ORDER BY file_name) rn FROM v_app_tablespaces)
        LOOP
            IF (C.bytes>TB2) THEN
                RAISE_APPLICATION_ERROR(-20000,'SIZE OF FILE '||C.file_name||' EXCEEDS 2TB MAXIMUM ALLOWED FOR DBMS_FLE_TRANSFER.');
            END IF;
            IF (C.rn>1) THEN
                RAISE_APPLICATION_ERROR(-20000,C.file_name||' - FILE NAME USED IN MORE THAN ONE DIRECTORY. ALL MIGRATED FILE NAMES MUST BE UNIQUE.');
            END IF;
        END LOOP;

        /*
         *  ABORT IF INCR_TS MIGRATION AND DIRECTORY EITHER NOT SPECIFIED OR NOT EXISTS
         */
        IF (p_run_mode='INCR') THEN
            IF (p_running_incr) THEN
                RAISE_APPLICATION_ERROR(-20000,'INCREMENTAL BACKUP PROCESS ALREADY RUNNING.');
            END IF;
            IF (p_incr_ts_dir IS NULL) THEN
                RAISE_APPLICATION_ERROR(-20000,'MUST SPECIFY "BKPDIR" PARAMETER - LOCATION FOR FILE IMAGE COPIES AND INCREMENTAL BACKUPS');
            ELSE
                EXECUTE IMMEDIATE 'CREATE OR REPLACE DIRECTORY DELETEITLATER AS '''||p_incr_ts_dir||'''';
                l_file_exists := DBMS_LOB.FILEEXISTS(BFILENAME('DELETEITLATER','.'));
                EXECUTE IMMEDIATE 'DROP DIRECTORY DELETEITLATER';
                IF ( l_file_exists<>1 ) THEN
                    RAISE_APPLICATION_ERROR(-20000,p_incr_ts_dir||' - DIRECTORY DOES NOT EXIST ON '||SYS_CONTEXT('userenv','host'));
                END IF;
            END IF;
        END IF;
    END;

    -------------------------------
    PROCEDURE closing_remarks(p_ip_address in VARCHAR2, p_run_mode in VARCHAR2, p_running_incr IN BOOLEAN) IS
        l_db_name v$database.name%type;
        l_oracle_pdb_sid VARCHAR2(30);
        l_service_name v$services.name%type;
        l_whoami VARCHAR2(30):=SYS_CONTEXT('USERENV','CURRENT_SCHEMA');
        l_command VARCHAR2(300);
        l_password VARCHAR2(12);
        n PLS_INTEGER;
    BEGIN
        IF (p_run_mode='EXECUTE' AND p_running_incr) THEN
            log('FINAL INCREMENTAL BACKUP TAKEN. MIGRATION WILL AUTOMATICALLY COMPLETE ON TARGET DATABASE','-');
            RETURN;
        END IF;

        l_service_name:=getDefaultServiceName();
        n:=INSTR(l_service_name,'.');
        l_db_name:=CASE WHEN n>0 THEN SUBSTR(l_service_name,1,n-1) ELSE l_service_name END;
        sys.dbms_system.get_env('ORACLE_PDB_SID',l_oracle_pdb_sid);

        SELECT log_message INTO l_password FROM migration_log WHERE id=1;
        /*
        l_command:='sqlplus  / as sysdba @tgt_migr'
                        ||' HOST='||p_ip_address
                        ||' SERVICE='||COALESCE(l_oracle_pdb_sid,l_service_name)
                        ||' PDBNAME='||l_db_name
                        ||' PW='||l_password;
        IF (l_whoami<>'MIGRATION') THEN
            l_command:=l_command||' USER='||l_whoami;
        END IF;
        */
        l_command:='./runMigration.sh -u ' || l_whoami||'/'''||l_password || ''' -t ' || TRIM(p_ip_address) || ':1521' || '/' || COALESCE(l_oracle_pdb_sid,l_service_name) || ' -p ' || l_db_name;

        log('ALL PREPARATION TASKS ON SOURCE DATABASE COMPLETED SUCCESSFULLY','-');
        log('');
        log('ON TARGET DATABASE RUN - ');
        log(l_command,'-');
    END;

    --------------------------------------------------
    PROCEDURE init_migration (p_run_mode in VARCHAR2, p_ip_address in VARCHAR2, p_incr_ts_dir in VARCHAR2, p_incr_ts_freq in VARCHAR2) IS
        l_check_tts_violations NUMBER;
        l_compatibility VARCHAR2(50);
        l_migration_method VARCHAR2(21);
        l_migration_explained VARCHAR2(200);
        l_running_incr BOOLEAN;
        l_version VARCHAR2(50);
        n PLS_INTEGER;
    BEGIN
        SELECT MAX(REGEXP_SUBSTR(banner,'\d+.\d+.\d+.\d+')) INTO l_version FROM v$version;
        SELECT RTRIM(value) INTO l_compatibility FROM v$parameter WHERE name='compatible';

        SELECT COUNT(*) INTO n FROM dual WHERE EXISTS (SELECT NULL FROM user_scheduler_jobs WHERE job_name='MIGRATION_INCR');
        l_running_incr:=(n=1);

        validate(p_run_mode, p_incr_ts_dir, l_running_incr);

        CASE p_run_mode
            WHEN 'ANALYZE' THEN
                check_tts_set;
                log_details(p_run_mode, l_version, l_compatibility, p_ip_address, l_running_incr);
            WHEN 'EXECUTE' THEN
                check_tts_set;
                set_ts_readonly;
                IF (l_running_incr) THEN
                    incr_job('RUN');
                ELSE
                    create_directory;
                END IF;
            WHEN 'INCR' THEN
                check_tts_set;
                create_directory(p_incr_ts_dir);
                incr_job('CREATE',p_incr_ts_freq);
                incr_job('RUN');
        END CASE;

        IF (p_run_mode IN ('EXECUTE','INCR')) THEN
            closing_remarks(p_ip_address,p_run_mode,l_running_incr);
        END IF;

        EXCEPTION WHEN TTS_CHECK_FAILED THEN
            RAISE_APPLICATION_ERROR(-20000,'TTS_CHECK_FAILED');

    END;
END;
/