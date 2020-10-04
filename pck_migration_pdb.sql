create or replace PACKAGE PDBADMIN.pck_migration_pdb AS
    --
    PROCEDURE preCreateUserTS(pAction IN VARCHAR2);
    --
    PROCEDURE impdp(pOverride IN BOOLEAN, pDbmsStats IN BOOLEAN);
    --
    PROCEDURE final(pDbmsStats IN BOOLEAN DEFAULT TRUE);
    --
    PROCEDURE uploadLog(pFilename IN VARCHAR2);
    --
    PROCEDURE log(pMessage IN VARCHAR2, pChar IN VARCHAR2 DEFAULT NULL);
    --    
    PROCEDURE wrap_me;
END;
/

create or replace PACKAGE BODY PDBADMIN.pck_migration_pdb AS

    PDBNAME        VARCHAR2(50):=SYS_CONTEXT('USERENV','CON_NAME');
    TRANSFER_USER  VARCHAR2(30);
    DATAFILE_PATH  all_directories.directory_path%type;
    TEMPFILE_PATH  all_directories.directory_path%type;
    
    PACKAGE varchar2(30):=$$PLSQL_UNIT;
    
    --
    -- PROCEDURE wrap_me
    --   Uses PLSQL wrapper to output an obfuscated version of this package which is readily
    --   unobscured using any number of resources on the internet
    --
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
    
    
    -- 
    -- PROCEDURE log
    --   Logs the message passed into table as well as dbms_output buffer to be later captured in calling shell script log file.
    --      
    -------------------------------
    PROCEDURE log(pMessage IN VARCHAR2, pChar IN VARCHAR2 DEFAULT NULL) IS
        PRAGMA AUTONOMOUS_TRANSACTION;
    BEGIN
        IF (pChar IS NOT NULL) THEN
            INSERT INTO migration_log(log_message) VALUES (RPAD(pChar,LENGTH(pMessage),pChar));
            dbms_output.put_line(RPAD(pChar,LENGTH(pMessage),pChar));
        END IF;
        
        INSERT INTO migration_log(log_message) VALUES (pMessage);
        dbms_output.put_line(pMessage);
        
        IF (pChar IS NOT NULL) THEN
            INSERT INTO migration_log(log_message) VALUES (RPAD(pChar,LENGTH(pMessage),pChar));
            dbms_output.put_line(RPAD(pChar,LENGTH(pMessage),pChar));
        END IF;        
        
        COMMIT;
    END;

    -- 
    -- PROCEDURE uploadLog
    --   Inserts OS file as log message row in table migration_log.
    --   Delete OS file to avoid possibility of exposing passwords at OS level
    --
    -------------------------------
    PROCEDURE uploadLog(pFilename IN VARCHAR2) IS
        l_clob    CLOB;
        l_bfile   BFILE;
        d_offset  NUMBER := 1;
        s_offset  NUMBER := 1;
        l_csid    NUMBER := 0;
        l_lang    NUMBER := 0;
        l_warning NUMBER;    
    BEGIN
        INSERT INTO migration_log (log_message) VALUES (empty_clob()) RETURN log_message INTO l_clob;
        l_bfile:=bfilename('TMPDIR',pFilename);
        dbms_lob.fileopen(l_bfile, dbms_lob.file_readonly);
        dbms_lob.loadclobfromfile(l_clob, l_bfile, DBMS_LOB.lobmaxsize, d_offset,s_offset,l_csid, l_lang, l_warning);
        dbms_lob.fileclose(l_bfile);
        COMMIT;
        utl_file.fremove(location=>'TMPDIR', filename=>pFilename);
    END;    
    
    --
    -- PROCEDURE executeDDL
    --   Prints the DDL statement passed and executes it.
    --
    -------------------------------
    PROCEDURE executeDDL(pDDL IN VARCHAR2) IS
        l_log LONG;
    BEGIN
        l_log:='About to execute... '||pDDL;
        EXECUTE IMMEDIATE pDDL;
        log(l_log||' ...OK');
        EXCEPTION
            WHEN OTHERS THEN
                log(l_log||' ...FAILED');
                RAISE;
    END;
    

    --
    -- FUNCTION version
    --   Converts a string Oracle version, e.g. "11.2.0.3", into a number for use in various version comparisons.
    --
    -------------------------------
    FUNCTION version(pVersion IN VARCHAR2) RETURN NUMBER IS
        l_version_2 VARCHAR2(20):=pVersion;
        l_version_n NUMBER;
        l_dots INTEGER:=LENGTH(pVersion)-LENGTH( REPLACE( pVersion, '.' )); --REGEXP_COUNT(pVersion,'\.');
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
    
    
    --
    -- PROCEDURE preCreateUserTS
    --   For XTTS-TS all user Default Tablespaces are pre-created before step 1 imports users
    --
    -------------------------------
    PROCEDURE preCreateUserTS(pAction IN VARCHAR2) IS
        l_ddl VARCHAR2(500);
        l_fname VARCHAR2(32):=SYS_GUID();
    BEGIN                                                
        FOR C IN (SELECT DISTINCT default_tablespace 
                    FROM dba_users@migr_dblink
                   WHERE default_tablespace IN (SELECT tablespace_name FROM V_app_tablespaces@migr_dblink)) LOOP
            IF (pAction='CREATE') THEN
                l_ddl:='CREATE TABLESPACE '||C.default_tablespace||' DATAFILE '''||DATAFILE_PATH||'/'||l_fname||C.default_tablespace||'.dbf'' SIZE 1M';
            ELSE
                l_ddl:='DROP TABLESPACE '||C.default_tablespace||' INCLUDING CONTENTS AND DATAFILES';
            END IF;
            executeDDL(l_ddl);
        END LOOP;
    END;  
    
    --
    --  PROCEDURE create_impdp_parfile
    --    Creates parfile(s) for impdp according to the type of migration (1 parfile for XTTS-DB, 3 parfiles for XTTS-TS)
    --  
    -------------------------------
    PROCEDURE create_impdp_parfile(pMigration IN VARCHAR2, pCompatibility IN VARCHAR2, pParfiles IN OUT SYS.ODCIVARCHAR2LIST) IS
        f utl_file.file_type;
        log VARCHAR2(100);
        
        FUNCTION openParfile(pDescription IN VARCHAR2, pSuffix IN VARCHAR2 DEFAULT NULL) RETURN VARCHAR2 IS
            l_filename VARCHAR2(100):='runMigration.'||PDBNAME||pSuffix||'.parfile';
        BEGIN
            f:=utl_file.fopen(location=>'MIGRATION_SCRIPT_DIR', filename=>l_filename, open_mode=>'w', max_linesize=>32767);
            utl_file.put_line(f,RPAD('#',LENGTH(pDescription)+15,'#'));
            utl_file.put_line(f,'#');
            utl_file.put_line(f,'#    DESCRIPTION');
            utl_file.put_line(f,'#      '||pDescription);
            utl_file.put_line(f,'#');
            utl_file.put_line(f,RPAD('#',LENGTH(pDescription)+15,'#'));
            pParfiles.EXTEND;
            pParfiles(pParfiles.COUNT):=l_filename;
            RETURN l_filename||'.log';
        END;
        
    BEGIN
        CASE
            WHEN (pMigration='XTTS_DB') THEN
                log:=openParfile('Import FULL TRANSPORTABLE DATABASE');

                utl_file.put_line(f,'NETWORK_LINK=MIGR_DBLINK');
                utl_file.put_line(f,'LOGFILE=MIGRATION_SCRIPT_DIR:'||log);
                utl_file.put_line(f,'LOGTIME=ALL');
                utl_file.put_line(f,'EXCLUDE=TABLE_STATISTICS,INDEX_STATISTICS');
                utl_file.put_line(f,'EXCLUDE=TABLESPACE:"IN (''UNDOTBS1'', ''TEMP'')"');
                utl_file.put_line(f,'EXCLUDE=DIRECTORY:"LIKE'''||TRANSFER_USER||'%''"');
                utl_file.put_line(f,'EXCLUDE=SCHEMA:"IN (SELECT username FROM v_migration_users WHERE oracle_maintained=''Y'' UNION ALL SELECT '''||TRANSFER_USER||''' FROM dual)"');
                utl_file.put_line(f,'METRICS=Y');
                utl_file.put_line(f,'FULL=Y');
                utl_file.put_line(f,'TRANSPORTABLE=ALWAYS');
                IF (pCompatibility='12') THEN
                    utl_file.put_line(f,'VERSION='||pCompatibility);
                END IF;
                
                FOR C IN (SELECT NVL(m.file_name_renamed,m.file_name) as file_name 
                            FROM migration_ts@MIGR_DBLINK_CDB m, v_app_tablespaces@MIGR_DBLINK s
                           WHERE m.pdb_name=PDBNAME
                             AND m.migration_status='TRANSFER COMPLETED' 
                             AND s.tablespace_name=m.tablespace_name  /* Allow source tablespaces to be dropped since starting migration */
                             AND s.file_name=m.file_name
                           ORDER BY 1) 
                LOOP
                    utl_file.put_line(f,'TRANSPORT_DATAFILES='''||DATAFILE_PATH||'/'||C.file_name||'''');
                END LOOP;
                
                utl_file.fclose(f);
                          
            WHEN (pMigration='XTTS_TS') THEN
                --
                -- 1. Users/Roles/Profiles/Role grants export / import
                --              
                log:=openParfile('Import USER,ROLE,ROLE_GRANT,PROFILE','.1');             
                
                utl_file.put_line(f,'NETWORK_LINK=MIGR_DBLINK');
                utl_file.put_line(f,'LOGFILE=MIGRATION_SCRIPT_DIR:'||log);
                utl_file.put_line(f,'LOGTIME=ALL');    
                utl_file.put_line(f,'INCLUDE=USER,ROLE,ROLE_GRANT,PROFILE');
                utl_file.put_line(f,'METRICS=Y');
                utl_file.put_line(f,'FULL=Y');
                
                utl_file.fclose(f);
                
                --
                -- 2. TTS export / import
                --
                log:=openParfile('Import TABLESPACES','.2');             
                
                utl_file.put_line(f,'NETWORK_LINK=MIGR_DBLINK');
                utl_file.put_line(f,'LOGFILE=MIGRATION_SCRIPT_DIR:'||log);
                utl_file.put_line(f,'LOGTIME=ALL');    
                utl_file.put_line(f,'EXCLUDE=TABLE_STATISTICS,INDEX_STATISTICS');
                utl_file.put_line(f,'METRICS=Y');
                utl_file.put_line(f,'TRANSPORT_FULL_CHECK=N');
                
                FOR C IN (SELECT DISTINCT tablespace_name FROM migration_ts@MIGR_DBLINK_CDB WHERE pdb_name=PDBNAME AND migration_status='TRANSFER COMPLETED' ORDER BY 1) LOOP
                    utl_file.put_line(f,'TRANSPORT_TABLESPACES='''||C.tablespace_name||'''');
                END LOOP;   
                
                FOR C IN (SELECT NVL(file_name_renamed,file_name) as file_name FROM migration_ts@MIGR_DBLINK_CDB WHERE pdb_name=PDBNAME AND migration_status='TRANSFER COMPLETED' ORDER BY 1) LOOP
                    utl_file.put_line(f,'TRANSPORT_DATAFILES='''||DATAFILE_PATH||'/'||C.file_name||'''');
                END LOOP;
                
                utl_file.fclose(f);

                --
                -- 3. Full metadata only export / import
                --
                log:=openParfile('Import remaining METADATA','.3');             
                
                utl_file.put_line(f,'NETWORK_LINK=MIGR_DBLINK');
                utl_file.put_line(f,'LOGFILE=MIGRATION_SCRIPT_DIR:'||log);
                utl_file.put_line(f,'LOGTIME=ALL');    
                utl_file.put_line(f,'EXCLUDE=USER,ROLE,ROLE_GRANT,PROFILE,TABLESPACE,TABLE_STATISTICS,INDEX_STATISTICS');
                utl_file.put_line(f,'EXCLUDE=DIRECTORY:"LIKE'''||TRANSFER_USER||'%''"');
                utl_file.put_line(f,'EXCLUDE=SCHEMA:"IN (SELECT username FROM v_migration_users WHERE oracle_maintained=''Y'' UNION ALL SELECT '''||TRANSFER_USER||''' FROM dual)"');
                utl_file.put_line(f,'METRICS=Y');
                utl_file.put_line(f,'FULL=Y');
                utl_file.put_line(f,'CONTENT=METADATA_ONLY');
                utl_file.put_line(f,'TABLE_EXISTS_ACTION=SKIP');
                
                utl_file.fclose(f);
        END CASE;
        
        EXCEPTION 
            WHEN OTHERS THEN 
                utl_file.fclose(f); 
                RAISE;
    END;

    
    --
    -- PROCEDURE impdp
    --   Create datapump parfiles to be referenced in external job that performs the migration
    --    
    -------------------------------    
    PROCEDURE impdp(pOverride IN BOOLEAN, pDbmsStats IN BOOLEAN) IS
        l_src_version_s VARCHAR2(20);
        l_src_compat_s VARCHAR2(20);
        l_tgt_version_s VARCHAR2(20);
        l_src_version NUMBER;
        l_src_compat NUMBER;
        l_tgt_version NUMBER;        
        l_migration_method VARCHAR2(7);
        l_compatible VARCHAR2(10);
        l_parfiles SYS.ODCIVARCHAR2LIST:=SYS.ODCIVARCHAR2LIST();
        l_ddl VARCHAR2(250);
        f utl_file.file_type;
        ----------------------
        PROCEDURE print_sqlcmd(pCmd IN VARCHAR2,pBlock IN BOOLEAN DEFAULT FALSE) IS
        BEGIN
            utl_file.put_line(f,'PROMPT '||pCmd);
            IF (pBlock) THEN
                utl_file.put_line(f,'BEGIN');
                utl_file.put_line(f,'  '||pCmd);
                utl_file.put_line(f,'END;');
                utl_file.put_line(f,'/');
            ELSE
                utl_file.put_line(f,pCmd);
            END IF;          
        END;    
    BEGIN
        log('CREATING DATAPUMP PARFILES AND BUILDING CONTENT OF ' || TEMPFILE_PATH || '/runMigration_impdp.sh');
       /*
        *  DETERMINE OPTIMAL MIGRATION METHOD
        *
        *    SOURCE DB >= 11.2.0.3    => TRANSPORTABLE DATABASE
        *    SOURCE DB <  11.2.0.3    => TRANSPORTABLE TABLESPACE (COMPATIBILITY MUST BE > 10.0 FOR CROSS-PLATFORM MIGRATION)
        */        
        SELECT MAX(DECODE(what,'src',version)) src_version, MAX(DECODE(what,'src_compat',version)) src_compat, MAX(DECODE(what,'tgt',version)) tgt_version
        INTO l_src_version_s, l_src_compat_s, l_tgt_version_s
        FROM
        (
        SELECT 'tgt' what, version FROM product_component_version WHERE product LIKE 'Oracle%' AND ROWNUM=1
        UNION ALL
        SELECT 'src' what, version FROM product_component_version@MIGR_DBLINK WHERE product LIKE 'Oracle%'  AND ROWNUM=1
        UNION ALL
        SELECT 'src_compat' what, value FROM database_compatible_level@MIGR_DBLINK 
        );  

        l_src_version:=version(l_src_version_s);
        l_src_compat:=version(l_src_compat_s);
        l_tgt_version:=version(l_tgt_version_s);

        IF (l_src_version >= version('12')) THEN
            l_migration_method:='XTTS_DB';
            l_compatible:='LATEST';
        ELSIF (l_src_version >= version('11.2.0.3')) THEN
            l_migration_method:='XTTS_DB';
            l_compatible:='12';
        ELSIF (l_src_version >= version('10.1.0.3') AND l_src_compat >= version('10.0')) THEN
            l_migration_method:='XTTS_TS';
            l_compatible:='LATEST';
        END IF;

        /* 
         *   ONLY FOR ME TO TEST XTTS-TS
         */
        IF (pOverride) THEN
            l_migration_method:='XTTS_TS';
        END IF;
        
        create_impdp_parfile(l_migration_method, l_compatible, l_parfiles);
        
        f:=utl_file.fopen(location=>'MIGRATION_SCRIPT_DIR', filename=>'runMigration.' ||PDBNAME || '.impdp.sh', open_mode=>'w', max_linesize=>32767);
        if (l_parfiles.COUNT>1) THEN
                utl_file.put_line(f,'echo "Pre-create dummy USER tablespaces for XTTTS-TS"');
                utl_file.put_line(f,'sqlplus /@' || PDBNAME||'<<EOF');
                utl_file.put_line(f,'whenever sqlerror exit failure');
                utl_file.put_line(f,'set serveroutput on');
                l_ddl:='exec pck_migration_pdb.preCreateUserTS(''CREATE'')';
                utl_file.put_line(f,'PROMPT '||l_ddl); 
                utl_file.put_line(f,l_ddl);
                utl_file.put_line(f,'exit');
                utl_file.put_line(f,'EOF');
                utl_file.put_line(f,'[[ $? != 0 ]] && { echo "FAILED pck_migration_pdb.preCreateUserTS(CREATE)"; exit 1; }');
        END IF;
        
        FOR i IN 1..l_parfiles.COUNT LOOP
            IF (i=2) THEN
                utl_file.put_line(f,'echo "Drop dummy USER tablespaces"');
                utl_file.put_line(f,'sqlplus /@' || PDBNAME||'<<EOF');
                utl_file.put_line(f,'whenever sqlerror exit failure');
                utl_file.put_line(f,'set serveroutput on');
                l_ddl:='exec pck_migration_pdb.preCreateUserTS(''DROP'')';
                utl_file.put_line(f,'PROMPT '||l_ddl); 
                utl_file.put_line(f,l_ddl);
                utl_file.put_line(f,'exit');
                utl_file.put_line(f,'EOF');
                utl_file.put_line(f,'[[ $? != 0 ]] && { echo "FAILED pck_migration_pdb.preCreateUserTS(DROP)"; exit 1; }');
            END IF;
            utl_file.put_line(f,'impdp /@' || PDBNAME || ' parfile=' || TEMPFILE_PATH || '/' ||l_parfiles(i)); 
            utl_file.put_line(f,'[[ $? = 1 ]] && { echo "FAILED impdp parfile='||l_parfiles(i)||'"; exit 1; }');
        END LOOP;
        
        utl_file.put_line(f,'sqlplus /@' || PDBNAME || '<<EOF');
        utl_file.put_line(f,'whenever sqlerror exit failure');
        utl_file.put_line(f,'set echo on');
        utl_file.put_line(f,'set serveroutput on size unlimited');
        IF (pDbmsStats) THEN
            l_ddl:='exec pck_migration_pdb.final(pDbmsStats=>TRUE)';
        ELSE
            l_ddl:='exec pck_migration_pdb.final(pDbmsStats=>FALSE)';
        END IF;
        utl_file.put_line(f,'PROMPT '||l_ddl);
        utl_file.put_line(f,l_ddl);
        utl_file.put_line(f,'EOF');
        utl_file.put_line(f,'[[ $? != 0 ]] && { echo "FAILED pck_migration_pdb.final"; exit 1; }');
        
        utl_file.put_line(f,'sqlplus /@${ORACLE_SID} AS SYSDBA<<EOF');
        utl_file.put_line(f,'whenever sqlerror exit failure');
        utl_file.put_line(f,'set echo on');
        utl_file.put_line(f,'alter session set container='||PDBNAME||';');
        FOR C IN (
            SELECT p.privilege, REPLACE(p.table_name,'$','\$') table_name, p.grantee, 
                  (SELECT o.object_type FROM dba_objects@migr_dblink o WHERE o.owner=p.owner AND o.object_name=p.table_name AND o.object_type='DIRECTORY') dir
              FROM dba_tab_privs@migr_dblink p, v_migration_users@migr_dblink u
             WHERE p.owner='SYS'
               AND p.grantee=u.username
               AND u.oracle_maintained='N'
               AND u.username<>TRANSFER_USER
        ) 
        LOOP
            l_ddl:='GRANT '||C.privilege||' ON '||C.dir||' SYS.'||C.table_name||' TO '||C.grantee || ';';
            utl_file.put_line(f,'PROMPT '||l_ddl);
            utl_file.put_line(f,l_ddl);
        END LOOP;        
        l_ddl:='exec utl_recomp.recomp_serial()';
        utl_file.put_line(f,'PROMPT '||l_ddl);
        utl_file.put_line(f,l_ddl);
        FOR C IN (SELECT repeat_interval FROM user_scheduler_jobs@MIGR_DBLINK WHERE job_name='MIGRATION_INCR') LOOP
            l_ddl:='exec dbms_scheduler.stop_job(''PDBADMIN.MIGRATION'',TRUE)';
            utl_file.put_line(f,'PROMPT '||l_ddl);
            utl_file.put_line(f,l_ddl);
        END LOOP;        
        --utl_file.put_line(f,'exec pdbadmin.pck_migration_pdb.log(''MIGRATION COMPLETED'',''-'')');
        utl_file.put_line(f,'EOF');
        utl_file.put_line(f,'[[ $? = 0 ]] && { echo "MIGRATION COMPLETED SUCCESSFULLLY"; } || { echo "FAILED in migration.'||PDBNAME||'.impdp.sh"; exit 1; }');
        
        utl_file.fclose(f);
        
        EXCEPTION
            WHEN OTHERS THEN
                IF (utl_file.is_open(f)) THEN utl_file.fclose(f); END IF;
                log('ABORTED MIGRATION JOB - '||SQLCODE||' - '||SUBSTR(sqlerrm,1,4000));
                log(sys.DBMS_UTILITY.format_error_backtrace);
                log(sys.DBMS_UTILITY.format_call_stack);
                RAISE;
    END;
    
    
    -------------------------------
    PROCEDURE final(pDbmsStats IN BOOLEAN) IS
    --
    -- PROCEDURE final
    --   1. Set tablespaces to pre-migration status
    --   2. Analyze the database - dictionary as well as application
    --   3. Drop any DIRECTORIES used in the migration
    --   4. Reconcile migrated segments and objects
    --   5. Check use of any migrated directory objects
    --        
        l_ddl VARCHAR2(500);
        l_temporary_tablespace dba_users.temporary_tablespace%type;
        l_file_exists NUMBER;

        n PLS_INTEGER:=0;
 
        PROCEDURE submit_stats_job(pWhat IN VARCHAR2) IS
        BEGIN
            DBMS_SCHEDULER.create_job (
                    job_name        => pWhat||'_JOB', 
                    job_type        => 'PLSQL_BLOCK',
                    job_action      => 'BEGIN dbms_stats.'||pWhat||'; END;',
                    start_date      => SYSTIMESTAMP,
                    enabled         => TRUE);
        END;
    BEGIN
        log('STARTING RECONCILIATION','-');
        
        FOR C IN (
            SELECT COUNT(SRC) SRC, COUNT(TGT) TGT, tablespace_name, owner, segment_name, segment_type
            FROM
            (
            SELECT 1 TGT, TO_NUMBER(NULL) SRC, s.tablespace_name, s.owner, s.segment_name, s.segment_type, (s.bytes/1048576) mb
            FROM dba_tablespaces ts, dba_segments s 
            wHERE s.tablespace_name=ts.tablespace_name
            AND ts.contents='PERMANENT' 
            AND ts.tablespace_name NOT IN ('SYSTEM','SYSAUX') 
            AND s.segment_type NOT LIKE 'LOB%'
            UNION ALL
            SELECT TO_NUMBER(NULL), 1, s.tablespace_name, s.owner, s.segment_name, s.segment_type, (s.bytes/1048576) mb
            FROM dba_tablespaces@MIGR_DBLINK ts, dba_segments@MIGR_DBLINK s 
            wHERE s.tablespace_name=ts.tablespace_name
            AND ts.contents='PERMANENT' 
            AND ts.tablespace_name NOT IN ('SYSTEM','SYSAUX') 
            AND s.segment_type NOT LIKE 'LOB%'
            AND s.segment_type<>'TEMPORARY'
            )
            GROUP BY tablespace_name, owner, segment_name, segment_type
            HAVING COUNT(SRC)<>COUNT(TGT)
            ORDER BY 3,4,5,1,2) 
        LOOP
            n:=n+1;
            IF (n=1) THEN
                log(RPAD('SRC',3)               ||'|'||
                    RPAD('TGT',4)              ||'|'||
                    RPAD('TABLESPACE_NAME',30)  ||'|'||
                    RPAD('OWNER',15)            ||'|'||
                    RPAD('SEGMENT_NAME',30)     ||'|'||
                    RPAD('SEGMENT_TYPE',15),'-');
            END IF;
            log(RPAD(TO_CHAR(C.SRC),3)      ||'|'||
                RPAD(TO_CHAR(C.TGT),4)     ||'|'||
                RPAD(C.tablespace_name,30)  ||'|'||
                RPAD(C.owner,15)            ||'|'||
                RPAD(C.segment_name,30)     ||'|'||
                RPAD(C.segment_type,15) );
        END LOOP;
        IF (n=0) THEN
            log('...ZERO DISCREPANCIES AT SEGMENT LEVEL');
        ELSE
            log('...TOTAL DISCREPANCIES AT SEGMENT LEVEL - '||n);
        END IF;
        
        n:=0;
        FOR C IN (
            SELECT COUNT(SRC) SRC, COUNT(TGT) TGT, owner,object_type,object_name 
            FROM
            (
                WITH schemas AS
                (
                    SELECT DISTINCT s.owner
                    FROM dba_tablespaces@MIGR_DBLINK ts, dba_segments@MIGR_DBLINK s 
                    wHERE s.tablespace_name=ts.tablespace_name
                    AND ts.contents='PERMANENT' 
                    AND ts.tablespace_name NOT IN ('SYSTEM','SYSAUX') 
                    AND s.segment_type<>'TEMPORARY'
                )
                SELECT 1 TGT, TO_NUMBER(NULL) SRC, owner,object_type,object_name 
                FROM
                (
                    SELECT owner,object_type,object_name
                    FROM dba_objects 
                    WHERE owner IN (SELECT owner FROM schemas) 
                    MINUS 
                    SELECT owner,'LOB',segment_name FROM dba_lobs WHERE owner IN (SELECT owner FROM schemas) 
                    MINUS 
                    SELECT owner,'INDEX',index_name FROM dba_lobs WHERE owner IN (SELECT owner FROM schemas) 
                )
                UNION ALL
                SELECT TO_NUMBER(NULL) TGT, 1 SRC, owner,object_type,object_name 
                FROM
                (
                    SELECT owner,object_type,object_name
                    FROM dba_objects@MIGR_DBLINK 
                    WHERE owner IN (SELECT owner FROM schemas) 
                    MINUS 
                    SELECT owner,'LOB',segment_name FROM dba_lobs@MIGR_DBLINK WHERE owner IN (SELECT owner FROM schemas) 
                    MINUS 
                    SELECT owner,'INDEX',index_name FROM dba_lobs@MIGR_DBLINK WHERE owner IN (SELECT owner FROM schemas) 
                )
            )
            GROUP BY owner,object_type,object_name 
            HAVING COUNT(SRC)<>COUNT(TGT)
            ORDER BY 3,4,5,1,2
        )
        LOOP
            n:=n+1;
            IF (n=1) THEN
                log(RPAD('SRC',3)               ||'|'||
                    RPAD('TGT',4)              ||'|'||
                    RPAD('OWNER',15)            ||'|'||
                    RPAD('OBJECT_NAME',30)     ||'|'||
                    RPAD('OBJECT_TYPE',15),'-');
            END IF;
            log(RPAD(TO_CHAR(C.SRC),3)      ||'|'||
                RPAD(TO_CHAR(C.TGT),4)     ||'|'||
                RPAD(C.owner,15)            ||'|'||
                RPAD(C.object_name,30)     ||'|'||
                RPAD(C.object_type,15) );
        END LOOP;
        IF (n=0) THEN
            log('...ZERO DISCREPANCIES AT OBJECT LEVEL');
        ELSE
            log('...TOTAL DISCREPANCIES AT OBJECT LEVEL - '||n);
        END IF;
        
        /*
         *  SET PLUGGED-IN TABLESPACES TO THEIR PRE-MIGRATION STATUS. NB. FULL DATABASE IMPORT SETS ALL TABLESPACES TO READ WRITE EVEN IF THEIR ORIGINAL STATUS WAS READ ONLY.
         */
        n:=0;
        FOR C IN (SELECT DISTINCT s.tablespace_name, DECODE(s.pre_migr_status,'ONLINE','READ WRITE',s.pre_migr_status) pre_migr_status, t.status 
                    FROM migration_ts@MIGR_DBLINK s, dba_tablespaces t
                   WHERE s.tablespace_name=t.tablespace_name
                     AND s.pre_migr_status<>t.status)
        LOOP
            n:=n+1;
            IF (n=1) THEN
                log('SET TARGET TABLESPACES TO PRE-MIGRATION STATUS','-');
            END IF;
            l_ddl:='ALTER TABLESPACE '||C.tablespace_name||' '||C.pre_migr_status;
            executeDDL(l_ddl);                
        END LOOP;
        
        /* SAME ON SOURCE DATABASE */
        log('SET SOURCE TABLESPACES TO PRE-MIGRATION STATUS','-');
        l_ddl:='BEGIN pck_migration_src.set_ts_readwrite@migr_dblink; END;';
        log('About to ...'||l_ddl);
        EXECUTE IMMEDIATE l_ddl; 

        
        /*
         *  LOG IMPORTED DIRECTORIES WHOSE PATH DOES NOT EXiST
         */
        n:=0;        
        FOR C IN (
            SELECT d.directory_name, d.directory_path, p.grantee 
              FROM dba_directories d, dba_tab_privs p 
             WHERE p.type='DIRECTORY' 
               AND p.common='NO'
               AND p.table_name=d.directory_name
               AND grantee<>'PDBADMIN'
             GROUP BY d.directory_name, d.directory_path, p.grantee) 
        LOOP
            l_file_exists:=DBMS_LOB.FILEEXISTS(BFILENAME(C.directory_name,'.'));
            IF (l_file_exists=1) THEN
                CONTINUE;
            END IF;
            n:=n+1;
            IF (n=1) THEN
                log(RPAD('DIRECTORY',31) ||'|'||RPAD('DIRECTORY PATH NOT EXISTS',100),'-');     
            END IF;    
            log(RPAD(C.directory_name,31) || '|' || RPAD(C.directory_path,100));
        END LOOP;

        /*
         *  GATHER STATS IN BACKGROUND JOBS
         */
        IF (pDbmsStats) THEN
            log('SUBMITTING STATISTICS JOBS','-');
            log('... n.b. monitor with "SELECT target_desc,message FROM v$session_longops WHERE time_remaining>0;"');

            submit_stats_job('gather_database_stats');
            submit_stats_job('gather_fixed_objects_stats');
            submit_stats_job('gather_dictionary_stats');
        ELSE
            log('STATISTICS NOT GATHERED BY REQUEST','*');
        END IF;
    END;
    
BEGIN
    /*
     *  SET GLOBAL VARIABLES
     */
    SELECT username INTO TRANSFER_USER FROM all_db_links WHERE owner='PUBLIC' AND db_link='MIGR_DBLINK';   
    SELECT DISTINCT SUBSTR(file_name,1,INSTR(file_name,'/',-1)-1) INTO DATAFILE_PATH FROM dba_data_files;
    SELECT directory_path INTO TEMPFILE_PATH FROM all_directories WHERE directory_name='MIGRATION_SCRIPT_DIR';    

END;
/
