CREATE OR REPLACE PACKAGE pck_migration_src AS
    --
    PROCEDURE init_migration (
        p_run_mode in VARCHAR2 DEFAULT 'ANALYZE',
        p_incr_ts_dir in VARCHAR2 DEFAULT NULL, 
        p_incr_ts_freq in VARCHAR2 DEFAULT NULL);
    --
    PROCEDURE p_incr_ts;
    --
    PROCEDURE incr_job(pAction in VARCHAR2, p_incr_ts_freq in VARCHAR2 DEFAULT NULL);
    --
    PROCEDURE wrap_me;
END;
/

CREATE OR REPLACE PACKAGE BODY pck_migration_src AS

/*
    NAME
      pck_migration_src

    DESCRIPTION
      This package is called from "src_migr.sql" to prepare the database for migration either directly or by a process of continuous recovery.

      Full details available at https://github.com/xsf3190/automigrate.git
*/
    CDB varchar2(3);
    TTS_CHECK_FAILED EXCEPTION;
    PACKAGE varchar2(30):=$$PLSQL_UNIT;
    
    -------------------------------
    PROCEDURE wrap_me IS
      
      l_source  DBMS_SQL.VARCHAR2A;
      l_wrap    DBMS_SQL.VARCHAR2A;
    BEGIN
        FOR C IN (SELECT line, DECODE(line,1,'CREATE OR REPLACE ')||text as text 
                    FROM user_source WHERE name=PACKAGE AND type='PACKAGE BODY' ORDER BY line)
        LOOP
            l_source(C.line) := C.text;
        END LOOP;

        l_wrap := SYS.DBMS_DDL.WRAP(ddl=>l_source,lb=>1,ub=>l_source.count);

      FOR i IN 1 .. l_wrap.count LOOP
        DBMS_OUTPUT.put_line(l_wrap(i));
      END LOOP;
    END;

    -------------------------------
    PROCEDURE log(pLine IN VARCHAR2, pChar IN VARCHAR2 DEFAULT NULL) IS
        l_now VARCHAR2(25):=TO_CHAR(SYSDATE,'MM.DD.YYYY HH24:MI:SS')||' - ';
    BEGIN
        IF (pChar IS NULL) THEN
            dbms_output.put_line('Rem '||l_now||pLine);
        ELSE
            dbms_output.put_line('Rem '||l_now||RPAD(pChar,LENGTH(pLine),pChar));
            dbms_output.put_line('Rem '||l_now||pLine);
            dbms_output.put_line('Rem '||l_now||RPAD(pChar,LENGTH(pLine),pChar));
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
    PROCEDURE exec_drop(pObjectOwner IN VARCHAR2, pObjectType IN VARCHAR2, pObjectName IN VARCHAR2) IS
        n PLS_INTEGER;
    BEGIN
        SELECT COUNT(*) INTO n FROM dual WHERE EXISTS (SELECT NULL FROM dba_objects WHERE owner=pObjectOwner AND object_type=pObjectType AND object_name=pObjectName);
        IF (n>0) THEN
            IF (pObjectOwner='PUBLIC' AND pObjectType='SYNONYM') THEN
                exec('DROP PUBLIC SYNONYM '||pObjectName);
            ELSE
                exec('DROP '||pObjectType||' '||pObjectName);
            END IF;
        END IF;
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
    PROCEDURE log_details(pRunMode IN VARCHAR2, pVersion IN VARCHAR2, pCompatibility IN VARCHAR2) IS
        l_db_name v$database.name%type;
        l_bct_status v$block_change_tracking.status%type;
        l_characterset varchar2(20);
        l_log_mode v$database.log_mode%type;
        l_version v$instance.version%type;
        l_host_name v$instance.host_name%type;
        l_migration_method VARCHAR2(21);
        l_migration_explained VARCHAR2(200);
        l_platform v$database.platform_name%type;
        l_return varchar2(20);
        l_this_version NUMBER:=version(pVersion);
        l_total_bytes number:=0;
        l_oracle_sid varchar2(30);
        l_oracle_pdb_sid varchar2(30);
        l_oracle_home varchar2(100);
        l_tns_admin varchar2(100);
        l_rman_incr_xtts VARCHAR2(100);
        l_service_name v$services.name%type;
        l_ts_list_rw LONG:=NULL;
        l_ts_list_ro LONG:=NULL;
        l_running_incr_ts BOOLEAN;
        l_running_execute BOOLEAN;
        l_last_transferred DATE :=NULL;
        l_last_applied DATE:=NULL;
        l_migration_status VARCHAR2(1000);
        n PLS_INTEGER:=0;
        n1 PLS_INTEGER:=0;
    BEGIN
        sys.dbms_system.get_env('ORACLE_PDB_SID',l_oracle_pdb_sid);
        sys.dbms_system.get_env('ORACLE_SID',l_oracle_sid);
        sys.dbms_system.get_env('ORACLE_HOME',l_oracle_home);
        sys.dbms_system.get_env('TNS_ADMIN',l_tns_admin);

        IF (l_tns_admin IS NULL) THEN
            l_tns_admin:=l_oracle_home||'/network/admin (DEFAULT)';
        END IF;

        SELECT d.name, i.host_name, d.log_mode, d.platform_name, d.cdb, p1.property_value
          INTO l_db_name, l_host_name, l_log_mode, l_platform, CDB, l_characterset
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
            l_migration_explained:='VERSION >= 11.2.0.3  - OPTIMAL MIGRATION IS FULL TRANSPORTABLE DATABASE';
        ELSIF (l_this_version >= version('10.1.0.3') AND version(pCompatibility)>=version('10')) THEN
            l_migration_method:='XTTS_TS';
            l_migration_explained:='VERSION >= 10.1.0.3 AND < 11.2.0.3  - OPTIMAL MIGRATION IS TRANSPORTABLE TABLESPACE';
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
            l_rman_incr_xtts:='YES';
        ELSE
            l_rman_incr_xtts:='NO - REQUIRES LOG MODE:ARCHIVELOG, BLOCK CHANGE TRACKING:ENABLED';
        END IF;
        
        /*
         *  ABORT IF NO DEFAULT LISTENING SERVICE
         */
        IF (CDB='YES') THEN
            l_service_name:=SYS_CONTEXT('USERENV','CON_NAME');
        ELSE
            l_service_name:='**UNKNOWN**';
            FOR C IN (SELECT s.name FROM v$services s, v$database d WHERE s.name=d.name) LOOP
                l_service_name:=C.name;
            END LOOP;
        END IF;

        log('             DATABASE MIGRATION','-');
        log('             RUN MODE : '||pRunMode);
        log('           ORACLE_SID : '||l_oracle_sid);
        log('       ORACLE_PDB_SID : '||NVL(l_oracle_pdb_sid,'N/A'));
        log('          ORACLE_HOME : '||l_oracle_home);
        log('            TNS_ADMIN : '||l_tns_admin);
        log('             DATABASE : '||l_db_name);
        log('             LOG MODE : '||l_log_mode);
        log('              VERSION : '||pVersion);
        log('        COMPATIBILITY : '||pCompatibility);
        log('        CHARACTER SET : '||l_characterset);
        log('      HOST FOR DBLINK : '||l_host_name);
        log('   SERVICE FOR DBLINK : '||COALESCE(l_oracle_pdb_sid,l_service_name));
        log('      USER FOR DBLINK : '||SYS_CONTEXT('USERENV','CURRENT_SCHEMA'));
        log('        PLATFORM NAME : '||l_platform);
        log('        DATABASE SIZE : '||LTRIM(TO_CHAR(ROUND(l_total_bytes/1024/1024/1024,2),'999,999,990.00')|| ' GB'));
        log('BLOCK CHANGE TRACKING : '||l_bct_status);
        log('      TABLESPACES R/W : '||NVL(RTRIM(l_ts_list_rw,','),'-NONE-'));
        log('      TABLESPACES R/O : '||NVL(RTRIM(l_ts_list_ro,','),'-NONE-'));
        log('    QUALIFIES INCR TS : '||l_rman_incr_xtts);
        log('     MIGRATION METHOD : '||l_migration_method);
        log('   METHOD EXPLANATION : '||l_migration_explained);

        log('    ORACLE WHITEPAPER :  https://www.oracle.com/technetwork/database/upgrade/overview/upgrading-oracle-database-wp-122-3403093.pdf','-');
    END;

    -------------------------------
    PROCEDURE check_tts_set IS
    /*
     *  CHECK TABLESPACES TO BE TRANSPORTED ARE SELF-CONTAINED
     */
        l_ts_list LONG;
        n PLS_INTEGER:=0;
    BEGIN        
        /* Build comma-delimited string of tablespaces to check */
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
    END;

    -------------------------------
    /*
     *  SET TABLESPACES BACK TO THEIR ORIGINAL STATUS. TYPICALLY DO THS AFTER AN XTT MIGRATION.
     */
    PROCEDURE set_ts_readwrite IS
        l_ddl VARCHAR2(100);
    BEGIN
        FOR C IN (SELECT DISTINCT m.tablespace_name, DECODE(m.pre_migr_status,'ONLINE','READ WRITE',m.pre_migr_status) pre_migr_status
                    FROM migration_ts m, dba_tablespaces t
                   WHERE m.tablespace_name=t.tablespace_name
                     AND m.pre_migr_status<>t.status) 
        LOOP
            exec('ALTER TABLESPACE '||C.tablespace_name||' '||C.pre_migr_status);
        END LOOP;
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
     *  CREATE OR RUN INCREMENATAL BACKUP JOB
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
                dbms_scheduler.run_job(job_name=>l_job_name);
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
    BEGIN
        SELECT directory_path||'/' INTO l_dir_path FROM dba_directories WHERE directory_name='MIGRATION_FILES_1_DIR';
        --
        SELECT SYSDATE INTO l_started FROM dual;
        --
        FOR C IN (SELECT file_id, file_name FROM v_app_tablespaces d 
                   WHERE NOT EXISTS (SELECT null FROM v$datafile_copy dc WHERE dc.file#=d.file_id AND dc.tag=l_tag AND dc.status='A')) 
        LOOP
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
            pck_migration_src.incr_job(pAction=>'DROP');
        END IF;
    END;

    -------------------------------
    PROCEDURE validate(p_run_mode in VARCHAR2, p_incr_ts_dir in VARCHAR2, p_version in NUMBER, p_compatibility IN VARCHAR2 ) IS
        CDB VARCHAR2(3);
        l_file_exists NUMBER;
        l_error VARCHAR2(100);
        l_oracle_pdb_sid VARCHAR2(30);
        n PLS_INTEGER;
        TB2 CONSTANT integer :=2*POWER(1024,4);
    BEGIN
        /*
         * ABORT IF WE ARE CDB DATABASE AND ORACLE_PDB_SID HAS NOT BEEN SET
         */
        IF (p_version>version('12')) THEN
            EXECUTE IMMEDIATE 'SELECT cdb FROM v$database' INTO CDB;
        ELSE
            CDB:='NO';
        END IF;
        IF (CDB='YES') THEN
            sys.dbms_system.get_env('ORACLE_PDB_SID',l_oracle_pdb_sid);
            --log('ORACLE_PDB_SID:'||l_oracle_pdb_sid||':');
            IF (l_oracle_pdb_sid IS NULL) THEN
                RAISE_APPLICATION_ERROR(-20000,'THIS IS A PROPER CDB DATABASE. USE UNPLUG/PLUG TO MIGRATE.');
            END IF;
        END IF;

        /*
         *  CROSS-PLATFORM TRANSPORTABLE TABLESPACE ONLY AVAILABLE FROM 10.1.0.3
         */
        IF (p_version < version('10.1.0.3') OR version(p_compatibility)<version('10')) THEN
            RAISE_APPLICATION_ERROR(-20000,'X-PLATFORM TRANSPORTABLE TABLESPACE NOT SUPPORTED FOR THIS DATABASE WITH COMPATIBILITY '||p_compatibility);
        END IF;

        /*
         *  ABORT IF TTS VIEWS NOT EXIST
         */
        SELECT COUNT(*) INTO n FROM dba_views WHERE owner='SYS' AND view_name='TRANSPORT_SET_VIOLATIONS';
        IF (n=0) THEN
            log('TRANSPORT TABLESPACE VIEWS NOT INSTALLED','-');
            log('sqlplus / as sysdba');
            log('@?/rdbms/admin/catplug.sql');
            log('@?/rdbms/admin/dbmsplts.sql');
            log('@?/rdbms/admin/prvtplts.plb');
            RAISE_APPLICATION_ERROR(-20000,'TRANSPORT TABLESPACE VIEWS NOT INSTALLED .. FOLLOW ABOVE INSTRUCTIONS.');
        END IF;
        
        /*
         *  ABORT IF TABLESPACES ARE NOT KOSHER FOR MIGRATION
         */  
        FOR C IN (SELECT file_name,bytes, ROW_NUMBER() OVER (PARTITION BY file_name ORDER BY file_name) rn FROM v_app_tablespaces)
        LOOP
            IF (C.bytes>TB2) THEN
                RAISE_APPLICATION_ERROR(-20000,'SIZE OF FILE '||C.file_name||' EXCEEDS 2TB MAXIMUM ALLOWED FOR DBMS_FLE_TRANSFER.');
            END IF;
            IF (C.rn>1) THEN
                RAISE_APPLICATION_ERROR(-20000,C.file_name||' IS DEFINED IN MORE THAN ONE SOURCE DIRECTORY. ALL FILES MIGRATED TO SINGLE TARGET DIRECTORY. RENAME IT.');
            END IF;
        END LOOP;
                        
        /*
         *  ABORT IF SUBMITTED MODE CONFLICTS WITH RUNNING MODE  ??????
         */         
                        
        /*
         *  ABORT IF INCR_TS MIGRATION AND DIRECTORY NOT SPECIFIED OR NOT VALID
         */
        IF (p_run_mode='INCR-TS') THEN
            IF (p_incr_ts_dir IS NULL) THEN
                RAISE_APPLICATION_ERROR(-20000,'INCR-DIR-TS IS MISSING PARAMETER. WHERE DO YOU WANT FILE IMAGE AND INCREMENTAL BACKUPS TO BE STORED ON THIS SERVER?');
            ELSE
                EXECUTE IMMEDIATE 'CREATE OR REPLACE DIRECTORY DELETEITLATER AS '''||p_incr_ts_dir||'''';
                l_file_exists := DBMS_LOB.FILEEXISTS(BFILENAME('DELETEITLATER','.'));
                EXECUTE IMMEDIATE 'DROP DIRECTORY DELETEITLATER';
                IF ( l_file_exists<>1 ) THEN
                    RAISE_APPLICATION_ERROR(-20000,p_incr_ts_dir||' - DIRECTORY DOES NOT EXIST. HAVE ANOTHER GO.');
                END IF;
            END IF;
        END IF;                           
    END;
                    
    -------------------------------
    PROCEDURE closing_remarks(p_run_mode in VARCHAR2) IS
        l_command VARCHAR2(300);
        l_oracle_pdb_sid VARCHAR2(30);
        l_whoami VARCHAR2(30):=SYS_CONTEXT('USERENV','CURRENT_SCHEMA');
    BEGIN
        sys.dbms_system.get_env('ORACLE_PDB_SID',l_oracle_pdb_sid);
        
        FOR C IN (SELECT d.name db_name, i.host_name, s.name service_name, p.password
                    FROM v$database d, v$instance i, v$services s, migration_init p
                   WHERE d.name=s.name(+)) LOOP
            IF (p_run_mode IN ('EXECUTE','INCR-TS')) THEN
                log('ALL PREPARATION TASKS ON SOURCE DATABASE COMPLETED SUCCESSFULLY','-');
                log('');
                log('LOG ON TO TARGET DATABASE AND RUN FOLLOWING COMMAND - ');
                l_command:='sqlplus  / as sysdba @tgt_migr HOST='||C.host_name
                                                       ||' SERVICE='||COALESCE(l_oracle_pdb_sid,C.service_name,'UNKNOWN')
                                                       ||' PDBNAME='||C.db_name;
                l_command:=l_command||' USER='||l_whoami;
                l_command:=l_command||' PW='||C.password;
                log(l_command,'-');
            END IF;
            IF (p_run_mode='INCR-TS-FINAL') THEN
                log('ALL APPLICATION TABLESPACES SET READ ONLY. NEXT INCREMENTAL BACKUP WILL BE THE FINAL ONE.');
                log('TARGET SERVER JOB WILL AUTOMATICALLY COMPLETE THE MIGRATION WHEN IT NEXT RUNS.');
            END IF;
        END LOOP;
    END;

    --------------------------------------------------
    PROCEDURE init_migration (p_run_mode in VARCHAR2, p_incr_ts_dir in VARCHAR2, p_incr_ts_freq in VARCHAR2) IS
        l_check_tts_violations NUMBER;
        l_compatibility VARCHAR2(10);
        l_migration_method VARCHAR2(21);
        l_migration_explained VARCHAR2(200);
        l_this_version NUMBER;
        l_version VARCHAR2(20);
    BEGIN
        SELECT MAX(REGEXP_SUBSTR(banner,'\d+.\d+.\d+.\d+')) INTO l_version FROM v$version;
        l_this_version:=version(l_version);
        SELECT value INTO l_compatibility FROM v$parameter WHERE name='compatible';

        validate(p_run_mode, p_incr_ts_dir, l_this_version, l_compatibility);
        
        CASE p_run_mode
            WHEN 'RESET' THEN
                set_ts_readwrite;
                log_details(p_run_mode, l_version, l_compatibility);
            WHEN 'ANALYZE' THEN
                check_tts_set;
                log_details(p_run_mode, l_version, l_compatibility);
            WHEN 'EXECUTE' THEN
                check_tts_set;
                set_ts_readonly;
                create_directory;
            WHEN 'INCR-TS' THEN
                check_tts_set;
                create_directory(p_incr_ts_dir);
                incr_job('CREATE',p_incr_ts_freq);
                incr_job('RUN');
            WHEN 'INCR-TS-FINAL' THEN
                check_tts_set;
                set_ts_readonly;
                incr_job('RUN');
        END CASE;
        
        IF (p_run_mode IN ('EXECUTE','INCR-TS','INCR-TS-FINAL')) THEN
            closing_remarks(p_run_mode);
        END IF;
                    
        EXCEPTION WHEN TTS_CHECK_FAILED THEN
            RAISE_APPLICATION_ERROR(-20000,'TTS_CHECK_FAILED');

    END;
END;
/