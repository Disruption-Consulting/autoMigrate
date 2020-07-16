create or replace PACKAGE PDBADMIN.pck_migration_tgt AS
    --
    PROCEDURE start_migration(pOverride IN VARCHAR2);
    --
    PROCEDURE log(pMessage IN VARCHAR2, pChar IN VARCHAR2 DEFAULT NULL);
    --
    PROCEDURE post_migration(pResetUser IN BOOLEAN);
    --
    PROCEDURE uploadLog(pFilename IN VARCHAR2);
    --
    PROCEDURE wrap_me;
END;
/

create or replace PACKAGE BODY PDBADMIN.pck_migration_tgt AS

    PDBNAME        VARCHAR2(50):=SYS_CONTEXT('USERENV','CON_NAME');
    PARFILE        VARCHAR2(50):=PDBNAME||'.impdp.parfile';
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
    -- FUNCTION file_exists
    --   Returns TRUE or FALSE depending on whether input file exists
    --
    -------------------------------
    FUNCTION file_exists(pFilename IN VARCHAR2, pLocation IN VARCHAR2 DEFAULT 'TGT_FILES_DIR') RETURN BOOLEAN IS
        l_fexists boolean;
        l_file_length number;
        l_block_size binary_integer;    
    BEGIN
        utl_file.fgetattr(location=>pLocation,filename=>pFilename,fexists=>l_fexists,file_length=>l_file_length,block_size=>l_block_size);
        RETURN (l_fexists);
    END;
    
    --
    -- FUNCTION file_bytes
    --   Returns number of bytes for the input file
    --   
    -------------------------------
    FUNCTION file_bytes(pFilename IN VARCHAR2, pLocation IN VARCHAR2 DEFAULT 'TGT_FILES_DIR') RETURN NUMBER IS
        l_fexists boolean;
        l_file_length number;
        l_block_size binary_integer;    
    BEGIN
        utl_file.fgetattr(location=>pLocation,filename=>pFilename,fexists=>l_fexists,file_length=>l_file_length,block_size=>l_block_size);
        RETURN (l_file_length);
    END;
    
    -- 
    -- PROCEDURE log
    --   Logs the message passed as a VARCHAR2
    --
    -------------------------------
    PROCEDURE log(pMessage IN VARCHAR2, pChar IN VARCHAR2 DEFAULT NULL) IS
    BEGIN
        IF (pChar IS NOT NULL) THEN
            INSERT INTO migration_log(log_message) VALUES (RPAD(pChar,LENGTH(pMessage),pChar));
        END IF;
        
        INSERT INTO migration_log(log_message) VALUES (pMessage);
        
        IF (pChar IS NOT NULL) THEN
            INSERT INTO migration_log(log_message) VALUES (RPAD(pChar,LENGTH(pMessage),pChar));
        END IF;        
        
        COMMIT;
    END;
    
    -- 
    -- PROCEDURE uploadLog
    --   Inserts OS file as log message row in table migration_log
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
    -- PROCEDURE preCreateTS
    --   Conventional DATAPUMP export/import requires all user-defined Tablespaces to be pre-created 
    --
    -------------------------------
    PROCEDURE preCreateTS IS
        l_ddl VARCHAR2(500);
        
    BEGIN                                                
        FOR C IN (SELECT m.tablespace_name, SUM(m.bytes) bytes 
                  FROM migration_ts m 
                  WHERE migration_status='TRANSFER COMPLETED'
                  AND NOT EXISTS (SELECT null FROM dba_tablespaces t WHERE t.tablespace_name=m.tablespace_name)
                  GROUP BY m.tablespace_name ORDER BY 1) LOOP
            l_ddl:='CREATE TABLESPACE '||C.tablespace_name||' DATAFILE '''||DATAFILE_PATH||'/'||LOWER(C.tablespace_name||'.dbf'' SIZE '||C.bytes||
                   ' AUTOEXTEND ON NEXT 100M MAXSIZE '||C.bytes*1.5||' EXTENT MANAGEMENT LOCAL AUTOALLOCATE DEFAULT NOCOMPRESS SEGMENT SPACE MANAGEMENT AUTO');
            executeDDL(l_ddl);
        END LOOP;
    END;

    --
    -- PROCEDURE preCreateUser
    --   CREATE / ALTER Users that are pre-created for a Transportable Tablespace migration (TMPDIR_TS)
    --
    -------------------------------
    PROCEDURE preCreateUser(pCommand IN VARCHAR2) IS
        l_ddl VARCHAR2(500);
    BEGIN
        CASE pCommand
            WHEN 'CREATE' THEN
                FOR C IN (SELECT username FROM dba_users@MIGR_DBLINK MINUS SELECT username FROM dba_users)
                LOOP
                    FOR C1 IN (SELECT authentication_type FROM dba_users@MIGR_DBLINK WHERE username=C.username)
                    LOOP
                        l_ddl:='CREATE USER '||C.username;
                        IF (C1.authentication_type='PASSWORD') THEN
                            l_ddl:=l_ddl||' IDENTIFIED BY '||C.username;
                        ELSIF (C1.authentication_type='EXTERNAL') THEN
                            l_ddl:=l_ddl||' IDENTIFIED EXTERNALLY';
                        END IF;
                        executeDDL(l_ddl);
                    END LOOP;
                END LOOP;
            
            WHEN 'ALTER'  THEN
                FOR C IN (
                    SELECT u.username, u.account_status, u.profile, dt.name default_tablespace, pw.spare4,
                            (SELECT property_value FROM database_properties WHERE property_name='DEFAULT_TEMP_TABLESPACE') temporary_tablespace 
                    FROM v$tablespace@MIGR_DBLINK dt, SYS.user$@MIGR_DBLINK pw, dba_users@MIGR_DBLINK u, dba_users pdb
                    WHERE dt.ts#=pw.datats#
                    AND pdb.username=pw.name
                    AND pdb.username=u.username
                    AND pdb.created>(SELECT created FROM dba_users WHERE username='PDBADMIN') )
                LOOP
                    l_ddl:='ALTER USER '||C.username||' DEFAULT TABLESPACE '||C.default_tablespace||' TEMPORARY TABLESPACE '||C.temporary_tablespace;
                    IF (C.spare4 IS NOT NULL) THEN
                        l_ddl:=l_ddl||' IDENTIFIED BY VALUES '''||C.spare4||'''';
                    END IF;
                    IF (C.account_status LIKE '%LOCKED%') THEN
                        l_ddl:=l_ddl||' ACCOUNT LOCK';
                    END IF;
                    IF (C.account_status LIKE '%EXPIRED%') THEN
                        l_ddl:=l_ddl||' PASSWORD EXPIRE';
                    END IF;
                    IF (C.profile<>'DEFAULT') THEN
                        l_ddl:=l_ddl||' PROFILE '||C.profile;
                    END IF;
                    executeDDL(l_ddl);
                END LOOP;            
        END CASE;
    END;    
    
    --
    --  PROCEDURE create_impdp_parfile
    --    Creates parfile(s) for impdp according to the type of migration
    --  
    -------------------------------
    FUNCTION create_impdp_parfile(pMigration IN VARCHAR2, pCompatibility IN VARCHAR2 DEFAULT NULL) RETURN VARCHAR2 IS
        f utl_file.file_type;
        l_parfiles VARCHAR2(1000):=NULL;
        
        PROCEDURE openParfile(pDescription IN VARCHAR2, pSuffix IN VARCHAR2 DEFAULT NULL) IS
            l_filename VARCHAR2(100):=PARFILE||pSuffix;
        BEGIN
            f:=utl_file.fopen(location=>'TMPDIR', filename=>l_filename, open_mode=>'w', max_linesize=>32767);
            l_parfiles:=l_parfiles||l_filename||',';
            utl_file.put_line(f,RPAD('#',LENGTH(pDescription)+15,'#'));
            utl_file.put_line(f,'#');
            utl_file.put_line(f,'#    DESCRIPTION');
            utl_file.put_line(f,'#      '||pDescription);
            utl_file.put_line(f,'#');
            utl_file.put_line(f,RPAD('#',LENGTH(pDescription)+15,'#'));
        END;
        
    BEGIN
        CASE
            WHEN (pMigration='CONV_DB') THEN
                openParfile('Parfile performs a Full Conventional Database migration');

                utl_file.put_line(f,'NETWORK_LINK=MIGR_DBLINK');
                utl_file.put_line(f,'LOGFILE=TMPDIR:'||PDBNAME||'.impdp.log');
                utl_file.put_line(f,'LOGTIME=ALL');
                utl_file.put_line(f,'EXCLUDE=TABLE_STATISTICS,INDEX_STATISTICS');
                utl_file.put_line(f,q'{EXCLUDE=SCHEMA:"IN ('}'||TRANSFER_USER||q'{')"}');
                utl_file.put_line(f,'METRICS=Y');
                utl_file.put_line(f,'FULL=Y');
                utl_file.fclose(f);
                
            WHEN (pMigration='XTTS_DB') THEN
                openParfile('Parfile performs a Full Transportable Database import/export');

                utl_file.put_line(f,'NETWORK_LINK=MIGR_DBLINK');
                utl_file.put_line(f,'LOGFILE=TMPDIR:'||PDBNAME||'.impdp.log');
                utl_file.put_line(f,'LOGTIME=ALL');
                utl_file.put_line(f,'EXCLUDE=TABLE_STATISTICS,INDEX_STATISTICS');
                utl_file.put_line(f,'EXCLUDE=TABLESPACE:"IN (''UNDOTBS1'', ''TEMP'')"');
                utl_file.put_line(f,'EXCLUDE=DIRECTORY:"LIKE''MIGRATION_FILES_%''"');
                utl_file.put_line(f,q'{EXCLUDE=SCHEMA:"IN ('}'||TRANSFER_USER||q'{')"}');
                utl_file.put_line(f,'METRICS=Y');
                utl_file.put_line(f,'FULL=Y');
                utl_file.put_line(f,'TRANSPORTABLE=ALWAYS');
                IF (pCompatibility='12') THEN
                    utl_file.put_line(f,'VERSION='||pCompatibility);
                END IF;
                
                FOR C IN (SELECT NVL(m.file_name_renamed,m.file_name) as file_name 
                            FROM migration_ts m, v_app_tablespaces@MIGR_DBLINK s
                           WHERE m.migration_status='TRANSFER COMPLETED' 
                             AND s.tablespace_name=m.tablespace_name  /* Allow source tablespaces to be dropped since starting migration */
                             AND s.file_name=m.file_name
                           ORDER BY 1) 
                LOOP
                    utl_file.put_line(f,'TRANSPORT_DATAFILES='''||DATAFILE_PATH||'/'||C.file_name||'''');
                END LOOP;
                
                utl_file.fclose(f);
                          
            WHEN (pMigration='XTTS_TS') THEN
                /*
                 *   MOS Doc ID 733824.1 How to recreate a database using TTS
                 */
                --
                -- 1. Users/Roles/Profiles/Role grants export / import
                --
                preCreateUser('CREATE');
                openParfile('Parfile performs a full metadata only import/export','1');             
                
                utl_file.put_line(f,'NETWORK_LINK=MIGR_DBLINK');
                utl_file.put_line(f,'LOGFILE=TMPDIR:'||PDBNAME||'.impdp.log');
                utl_file.put_line(f,'LOGTIME=ALL');    
                utl_file.put_line(f,'INCLUDE=USER,ROLE,ROLE_GRANT,PROFILE');
                utl_file.put_line(f,'METRICS=Y');
                utl_file.put_line(f,'FULL=Y');
                
                utl_file.fclose(f);
                
                --
                -- 2. TTS export / import
                --
                openParfile('Parfile performs a Transportable Tablespace import/export','2');             
                
                utl_file.put_line(f,'NETWORK_LINK=MIGR_DBLINK');
                utl_file.put_line(f,'LOGFILE=TMPDIR:'||PDBNAME||'.impdp.log.2');
                utl_file.put_line(f,'LOGTIME=ALL');    
                utl_file.put_line(f,'EXCLUDE=TABLE_STATISTICS,INDEX_STATISTICS');
                utl_file.put_line(f,'METRICS=Y');
                utl_file.put_line(f,'TRANSPORT_FULL_CHECK=Y');
                
                FOR C IN (SELECT DISTINCT tablespace_name FROM migration_ts WHERE migration_status='TRANSFER COMPLETED' ORDER BY 1) LOOP
                    utl_file.put_line(f,'TRANSPORT_TABLESPACES='''||C.tablespace_name||'''');
                END LOOP;   
                
                FOR C IN (SELECT NVL(file_name_renamed,file_name) as file_name FROM migration_ts WHERE migration_status='TRANSFER COMPLETED' ORDER BY 1) LOOP
                    utl_file.put_line(f,'TRANSPORT_DATAFILES='''||DATAFILE_PATH||'/'||C.file_name||'''');
                END LOOP;
                
                utl_file.fclose(f);

                --
                -- 3. Full metadata only export / import
                --
                openParfile('Parfile performs a full metadata only import/export','3');             
                
                utl_file.put_line(f,'NETWORK_LINK=MIGR_DBLINK');
                utl_file.put_line(f,'LOGFILE=TMPDIR:'||PDBNAME||'.impdp.log.3');
                utl_file.put_line(f,'LOGTIME=ALL');    
                utl_file.put_line(f,'EXCLUDE=USER,ROLE,ROLE_GRANT,PROFILE,TABLE_STATISTICS,INDEX_STATISTICS');
                utl_file.put_line(f,'EXCLUDE=DIRECTORY:"LIKE''MIGRATION_FILES_%''"');
                utl_file.put_line(f,q'{EXCLUDE=SCHEMA:"IN ('}'||TRANSFER_USER||q'{')"}');
                utl_file.put_line(f,'METRICS=Y');
                utl_file.put_line(f,'FULL=Y');
                utl_file.put_line(f,'CONTENT=METADATA_ONLY');
                utl_file.put_line(f,'TABLE_EXISTS_ACTION=SKIP');
                
                utl_file.fclose(f);
        END CASE;
        
        RETURN(RTRIM(l_parfiles,','));
        
        EXCEPTION 
            WHEN OTHERS THEN 
                utl_file.fclose(f); 
                RAISE;
    END;
    
    --
    -- PROCEDURE checkCharsets
    --   Check that source and target database character sets match, otherwise only allow conventional database migration if specifically requested by user
    --  
    -------------------------------
    PROCEDURE checkCharsets(pOverride IN VARCHAR2 DEFAULT NULL) IS
        l_mismatch VARCHAR2(200):=NULL;
        l_error VARCHAR2(500);
        l_convDB BOOLEAN;
    BEGIN
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
        
        l_convDB:=(pOverride='CONV_DB');
        
        IF (l_mismatch IS NOT NULL) THEN
            IF NOT (l_convDB) THEN
                l_error:='CHARACTER SET MISMATCH - "MIGRATE=CONV_DB" TO PERFORM FULL CONVENTIONAL DATABASE MIGRATION'||l_mismatch;
                log(l_error);
                RAISE_APPLICATION_ERROR(-20000,l_error);
            END IF;
        ELSE
            IF (l_convDB) THEN
                l_error:='CHARACTER SETS MATCH - "MIGRATE=CONV_DB" CANNOT OVERRIDE TTS MIGRATION'||l_mismatch;
                log(l_error);
                RAISE_APPLICATION_ERROR(-20000,l_error);
            END IF;
        END IF;
    END;
    
    --
    -- PROCEDURE create_parfile
    --   Run impdp over network link
    --    
    -------------------------------
    FUNCTION create_parfile(pOverride IN VARCHAR2 DEFAULT NULL) RETURN VARCHAR2 IS
        l_src_version_s VARCHAR2(20);
        l_src_compat_s VARCHAR2(20);
        l_tgt_version_s VARCHAR2(20);
        l_src_version NUMBER;
        l_src_compat NUMBER;
        l_tgt_version NUMBER;        
        l_migration_method VARCHAR2(7);
        l_compatible VARCHAR2(10);
        l_parfiles VARCHAR2(1000);
    BEGIN
        IF (pOverride='CONV-DB') THEN
            l_migration_method:='CONV_DB';
            l_compatible:='LATEST';
            preCreateTS;
        ELSE
           /*
            *  DETERMINE OPTIMAL MIGRATION METHOD
            *
            *    SOURCE DB >= 11.2.0.3      => TRANSPORTABLE DATABASE
            *    SOURCE DB <  11.2.0.3 
            *      AND COMPATIBILITY > 10.0 => TRANSPORTABLE TABLESPACE
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
        END IF;
        
        /*
         *  ONLY PROVIDE THIS OVERRIDE FOR ME TO TEST MIGRATION FROM V10 WHICH I DON'T HAVE
         */ 
        IF (pOverride='XTTS-TS') THEN
            l_migration_method:='XTTS_TS';
        END IF;

        /*
         *  CREATE PARFILE(S)
         */
        l_parfiles:=create_impdp_parfile(l_migration_method, l_compatible);
        
        RETURN (l_parfiles);
    END;
    
    --
    -- PROCEDURE file_transfer
    --   Transfer files from remote server. 
    --   File conversion is automatic when endianess is different between the two platforms, e.g. AIX(big) and LINUX(little).
    --   All files to be transferred are defined in tables "migration_ts" and "migration_bp".
    --
    -------------------------------
    PROCEDURE file_transfer IS
        l_error VARCHAR2(200):=NULL;
        l_message VARCHAR2(200);
        l_maxlen_filename PLS_INTEGER:=0;
        l_isomf BOOLEAN;
        l_isasm BOOLEAN;
        l_file_name_renamed migration_ts.file_name_renamed%type;
        l_full_filename dba_data_files.file_name%type;
        l_start_time DATE;
        t PLS_INTEGER;
        l_transferred_bytes migration_ts.transferred_bytes%type;
        l_destination_file_name migration_ts.file_name_renamed%type;
        l_sum_src NUMBER:=0;
        l_sum_tgt NUMBER:=0;
        TYPE tt_transfer IS RECORD (
            table_name VARCHAR2(30),
            pk NUMBER,
            file_name migration_ts.file_name%type,
            bytes migration_ts.bytes%type,
            directory_name migration_ts.directory_name%type);
        TYPE t_transfer IS TABLE OF tt_transfer;
        l_transfer t_transfer;
        l_currval NUMBER;
    BEGIN
        SELECT table_name, pk, file_name, bytes, directory_name
          BULK COLLECT INTO l_transfer
          FROM
              (
               SELECT 'migration_ts' table_name, file_id pk, file_name, bytes, directory_name FROM migration_ts WHERE migration_status='TRANSFER NOT STARTED'
                UNION ALL
               SELECT 'migration_bp' table_name, recid pk, bp_file_name, bytes, directory_name FROM migration_bp WHERE migration_status='TRANSFER NOT STARTED'
               )
        ORDER BY DECODE(table_name,'migration_ts',0,1),bytes;
        --
        FOR i IN 1..l_transfer.COUNT LOOP
            IF (LENGTH(l_transfer(i).file_name)>l_maxlen_filename) THEN
                l_maxlen_filename:=LENGTH(l_transfer(i).file_name);
            END IF;
        END LOOP;
        l_maxlen_filename:=l_maxlen_filename+7;  -- in case OMF renamed file
        l_maxlen_filename:=l_maxlen_filename+1+LENGTH(DATAFILE_PATH);
        --
        log(RPAD('FILE NAME',l_maxlen_filename) ||'|'||
            RPAD(' STATUS',11) ||'|'||
            LPAD('SOURCE (MB)',14) ||'|'||
            LPAD('TARGET (MB)',14),'-');
        --
        FOR i IN 1..l_transfer.COUNT LOOP
            /*
             *  RENAME OMF (ORACLE MANAGED FILE) ON TRANSFER
             */
            sys.dbms_backup_restore.isfilenameomf(l_transfer(i).file_name,l_isomf,l_isasm);
            IF (l_isomf) THEN
                l_file_name_renamed:='nonomf_'||l_transfer(i).file_name;
                l_destination_file_name:=l_file_name_renamed;
            ELSE
                l_file_name_renamed:=NULL;
                l_destination_file_name:=l_transfer(i).file_name;
            END IF;
            /*
             *  DO NOT TRANSFER PARTIALLY SENT FILES (e.g. IN CASE OF SOURCE DATABASE SHUTDOWN). DELETE AND TRY AGAIN.
             */
            l_full_filename:=DATAFILE_PATH||'/'||l_destination_file_name;

            l_start_time:=SYSDATE;
            t:=dbms_utility.get_time;
            log(RPAD(l_full_filename,l_maxlen_filename) ||'|'||
                        RPAD(' STARTED',11) ||'|'||
                        RPAD(TO_CHAR(l_transfer(i).bytes/1024/1024,'99,999,990.0') ,14) ||'|'||
                        RPAD(' ',14));
            l_currval:=migration_log_seq.CURRVAL;

            CASE l_transfer(i).table_name
                WHEN 'migration_ts' THEN 
                    UPDATE migration_ts 
                       SET migration_status='TRANSFER STARTED', start_time=l_start_time, file_name_renamed=l_destination_file_name
                     WHERE file_id=l_transfer(i).pk;
                WHEN 'migration_bp' THEN 
                    UPDATE migration_bp 
                       SET migration_status='TRANSFER STARTED', start_time=l_start_time 
                     WHERE recid=l_transfer(i).pk;
            END CASE;                
            
            COMMIT;
            
            dbms_file_transfer.get_file(
                source_directory_object      => l_transfer(i).directory_name, 
                source_file_name             => l_transfer(i).file_name, 
                source_database              =>'MIGR_DBLINK', 
                destination_directory_object =>'TGT_FILES_DIR', 
                destination_file_name        => l_destination_file_name);

            l_transferred_bytes:=file_bytes(l_destination_file_name);

            CASE l_transfer(i).table_name
                WHEN 'migration_ts' THEN
                    UPDATE migration_ts 
                       SET migration_status='TRANSFER COMPLETED',
                           start_time=l_start_time, 
                           transferred_bytes=l_transferred_bytes,
                           elapsed_seconds=(dbms_utility.get_time-t)/100,
                           file_name_renamed=l_file_name_renamed
                     WHERE file_id=l_transfer(i).pk;
                     
                    UPDATE migration_ts@MIGR_DBLINK SET transferred=SYSDATE WHERE file#=l_transfer(i).pk;

                WHEN 'migration_bp' THEN
                    UPDATE migration_bp 
                       SET migration_status='TRANSFER COMPLETED',
                           start_time=l_start_time, 
                           transferred_bytes=l_transferred_bytes,
                           elapsed_seconds=(dbms_utility.get_time-t)/100
                     WHERE recid=l_transfer(i).pk;               
            END CASE;

            l_sum_src:=l_sum_src+l_transfer(i).bytes;
            l_sum_tgt:=l_sum_tgt+l_transferred_bytes;
            
            UPDATE migration_log 
               SET log_message=RPAD(l_full_filename,l_maxlen_filename) ||'|'||
                        RPAD(' COMPLETED',11) ||'|'||
                        RPAD(TO_CHAR(l_transfer(i).bytes/1024/1024,'99,999,990.0') ,14) ||'|'||
                        RPAD(TO_CHAR(l_transferred_bytes/1024/1024,'99,999,990.0') ,14)
             WHERE id=l_currval;
             
            COMMIT;
            
            /* 
            log(RPAD(' ',l_maxlen_filename) ||'|'||
                RPAD(' COMPLETED',11) ||'|'||
                RPAD(' ',14) ||'|'||
                RPAD(TO_CHAR(l_transferred_bytes/1024/1024,'99,999,990.0') ,14));
            */
        END LOOP;
        
        log(LPAD('TOTAL TRANSFERRED ',l_maxlen_filename) ||'|'||
            RPAD(' COMPLETED',11)                   ||'|'||
            RPAD(TO_CHAR(l_sum_src/1024/1024,'99,999,990.0'),14) ||'|'||
            RPAD(TO_CHAR(l_sum_tgt/1024/1024,'99,999,990.0'),14),'-');
    END;
    
    -------------------------------
    PROCEDURE post_migration(pResetUser IN BOOLEAN) IS
    --
    -- PROCEDURE post_migration
    --   1. Set tablespaces to pre-migration status
    --   2. Analyze the database.
    --   3. Drop transfer user and DIRECTORIES used in the migration
    --   4. Reconcile migrated segments and objects
    --   5. Check use of any migrated db links
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
        /*
         *   RESET USERS IF THIS HAS BEEN XTTS-TS WHERE USERS ARE PRE-CREATED
         */
        IF (pResetUser) THEN
            preCreateUser('ALTER');
        END IF;
        
        /*
         *  Set tablespaces to read write, except any that were originally READ ONLY
         */
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
         *  SET PLUGGED-IN TABLESPACES TO THEIR PRE-MIGRATION STATUS. NB. FULL DATABASE IMPORT DOES NOT SET TABLESPACES TO THEIR ORIGINAL STATUS, IF THAAT WAS READ ONLY.
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
        l_ddl:='BEGIN pck_migration_src.init_migration@migr_dblink(p_run_mode=>:MODE); END;';
        log('About to ...'||l_ddl);
        EXECUTE IMMEDIATE l_ddl USING 'RESET'; 
        
        /*
         *  GATHER STATS IN BACKGROUND
         */
        log('SUBMITTING STATISTICS JOBS','-');
        log('... n.b. monitor with "SELECT target_desc,message FROM v$session_longops WHERE time_remaining>0;"');
        submit_stats_job('gather_database_stats');
        submit_stats_job('gather_fixed_objects_stats');
        submit_stats_job('gather_dictionary_stats');
        
        /*
         *  DROP OBJECTS USED ONLY FOR MIGRATION WHICH HAVE BEEN IMPORTED FROM SOURCE DATABASE
         */
        log('DROP MIGRATION-SPECIFIC OBJECTS','-');
        FOR C IN (SELECT username FROM dba_users WHERE username=TRANSFER_USER) LOOP
            executeDDL('DROP USER '||C.username||' CASCADE'); 
        END LOOP;
        FOR C IN (SELECT DISTINCT m.directory_name 
                  FROM migration_ts m, dba_directories d 
                  WHERE m.migration_status='TRANSFER COMPLETED' 
                  AND d.directory_name=m.directory_name) LOOP
            executeDDL('DROP DIRECTORY '||C.directory_name);
        END LOOP;
        
        /*
         *  LOG USE OF MIGRATED DB LINKS IN MIGRATED VIEWS, SYNONYMS AND PROCEDURES
         */
        n:=0;
        INSERT INTO migration_temp (owner, object_type, object_name, text)
        SELECT owner, 'VIEW', view_name, TO_LOB(text) FROM dba_views WHERE owner IN (SELECT username FROM dba_users WHERE oracle_maintained='N');
        
        FOR C IN (SELECT l.owner||'.'||l.db_link db_link, t.object_type, t.owner||'.'||t.object_name object
                    FROM migration_temp t, dba_db_links l
                   WHERE INSTR(lower(t.text),LOWER(l.db_link))>0
                   UNION ALL
                  SELECT l.owner||'.'||l.db_link, 'SYNONYM', s.owner||'.'||s.synonym_name FROM dba_synonyms s, dba_db_links l
                   WHERE l.db_link=s.db_link
                   UNION ALL
                   SELECT db_link, type, object 
                    FROM 
                        (
                            SELECT l.owner||'.'||l.db_link db_link, s.type, s.owner||'.'||s.name object, ROW_NUMBER() OVER (PARTITION BY s.owner, s.type, s.name ORDER BY s.line) rn
                            FROM dba_source s, dba_db_links l
                            WHERE s.owner IN (SELECT username FROM dba_users WHERE oracle_maintained='N')
                            AND INSTR(LOWER(s.text),LOWER(l.db_link))>0
                        )
                    WHERE rn=1
                    ORDER BY 1) 
        LOOP
            n:=n+1;
            IF (n=1) THEN
                log(RPAD('DB LINK IS REFERENCED IN',40) ||'|'||
                    RPAD('OBJECT TYPE',12) ||'|'||
                    RPAD('OBJECT_NAME',60),'-');
            END IF;
            log(RPAD(C.db_link,40) ||'|'||
                RPAD(C.object_type,12) ||'|'||
                RPAD(C.object,60) );            
        END LOOP;
        
        /*
         *  LOG DIRECTORY OBJECTS WHOSE PATH DOES NOT EXiST
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
    
    END;
    
    -------------------------------
    PROCEDURE apply_incremental IS
    /*
     *  APPLY TRANSFERRED INCREMENTAL BACKUPS TO LOCAL FILE IMAGE COPIES
     */     
        d  varchar2(512); 
        l_done boolean;
        l_platform_id INTEGER;
        
        TYPE t_incr IS RECORD (
            file_id         migration_bp.file_id%type, 
            ts_file_name    migration_ts.file_name%type,
            bp_file_name    migration_bp.bp_file_name%type, 
            recid           migration_bp.recid%type);
        TYPE tt_incr IS TABLE OF t_incr;
        l_incr tt_incr;
    BEGIN 
        SELECT bp.file_id, ts.file_name ts_file_name, bp.bp_file_name, bp.recid
          BULK COLLECT INTO l_incr
          FROM migration_bp bp, migration_ts ts
         WHERE bp.file_id=ts.file_id
           AND bp.migration_status='TRANSFER COMPLETED'
         ORDER BY bp.recid;  
        
        FOR i IN 1..l_incr.COUNT
        LOOP
            IF (i=1) THEN
                SELECT platform_id INTO l_platform_id FROM v$database@MIGR_DBLINK;
            END IF;
            
            d := sys.dbms_backup_restore.deviceAllocate; 

            /* Start conversation to apply incremental backups to existing datafiles */
            sys.dbms_backup_restore.restoreSetXttFile(pltfrmfr=>l_platform_id, xttincr=>TRUE) ;
            
            /*
             *  Apply an incremental backup from the backup set to the previously downloaded image copy of the datafile.
             */
            log('Rollforward '||DATAFILE_PATH||'/'||l_incr(i).ts_file_name||' .. with '||DATAFILE_PATH||'/'||l_incr(i).bp_file_name);
            sys.dbms_backup_restore.restoreXttFileTo(xtype=>2, xfno=>l_incr(i).file_id, xtsname=>NULL, xfname =>DATAFILE_PATH||'/'||l_incr(i).ts_file_name);

            /*
             *  Sets up the handle for xttRestore to use. 
             */
            sys.dbms_backup_restore.xttRestore(handle=>DATAFILE_PATH||'/'||l_incr(i).bp_file_name, done=>l_done);

            UPDATE migration_bp SET migration_status='APPLIED' WHERE recid=l_incr(i).recid;
            utl_file.fremove(location=>'TGT_FILES_DIR', filename=>l_incr(i).bp_file_name);
            
            UPDATE migration_ts@MIGR_DBLINK SET applied=SYSDATE WHERE file#=l_incr(i).file_id;
            
            COMMIT;    
            
            sys.dbms_backup_restore.restoreCancel(TRUE); 
            sys.dbms_backup_restore.deviceDeallocate;
        END LOOP;
    END;
    
    -------------------------------
    PROCEDURE log_details IS
        l_tgt_version v$instance.version%type;
        l_tgt_compatibility varchar2(10); 
        l_tgt_db_name v$database.name%type;
        l_tgt_platform v$database.platform_name%type;
        l_tgt_characterset database_properties.property_value%type; 
        l_oracle_sid varchar2(20);
        l_oracle_home varchar2(100);
    BEGIN
         /*
          *  GET DETAILS OF THE TARGET TGT DATABASE
          */ 
         SELECT d.name, TRIM(d.platform_name), p1.property_value
           INTO l_tgt_db_name, l_tgt_platform, l_tgt_characterset
           FROM v$database d, database_properties p1
          WHERE p1.property_name='NLS_CHARACTERSET';

         SELECT MAX(version_full) INTO l_tgt_version FROM product_component_version;
         SELECT value INTO l_tgt_compatibility FROM v$parameter WHERE name='compatible';

         sys.dbms_system.get_env('ORACLE_SID',l_oracle_sid);
         sys.dbms_system.get_env('ORACLE_HOME',l_oracle_home);

         log('             DATABASE MIGRATION','*');
         log('       SCRIPT VERSION : '||'10/6/2020');
         log('         CDB DATABASE : '||l_tgt_db_name);
         log('          CDB VERSION : '||l_tgt_version);
         log('    CDB CHARACTER SET : '||l_tgt_characterset);
         log('    CDB HOST PLATFORM : '||l_tgt_platform);
         log('           ORACLE_SID : '||l_oracle_sid);
         log('          ORACLE_HOME : '||l_oracle_home);
         log('             PDB NAME : '||PDBNAME);
         log('             TEMP DIR : '||TEMPFILE_PATH);
         log('        MIGRATION LOG : '||TEMPFILE_PATH || '/migration.log');
         log('        DATA FILE DIR : '||DATAFILE_PATH);
         FOR C IN (SELECT username, host, SUBSTR(host,3,p2-4) src_host, SUBSTR(host,p2,p3-p2-1) src_port, SUBSTR(host,p3) src_service_name
                     FROM (SELECT username, host, INSTR(host,':',-1)+1 p2, INSTR(host,'/',-1)+1 p3 FROM all_db_links WHERE db_link='MIGR_DBLINK')) 
         LOOP
             log('   SOURCE DBLINK USER : '||C.username);
             log('          SOURCE HOST : '||C.src_host);
             log('          SOURCE PORT : '||C.src_port);
             log('       SOURCE SERVICE : '||C.src_service_name);
         END LOOP;
    END;
    
    /*
     *  HERE'S WHERE IT ALL STARTS
     */
    -------------------------------
    PROCEDURE start_migration(pOverride IN VARCHAR2) IS 
        n PLS_INTEGER;
        l_parfiles VARCHAR2(1000);
        f utl_file.file_type;
        l_oracle_sid VARCHAR2(20);
        l_oracle_home VARCHAR2(200);
        l_sqlplus_logfile VARCHAR2(50):=PDBNAME||'.sqlplus.log';
        
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
        /*
         *  LOAD sqlplus LOG FILE INTO MIGRATION_LOG TABLE AND DELETE
         */
        IF (file_exists(pFilename=>l_sqlplus_logfile,pLocation=>'TMPDIR')) THEN
            uploadLog(l_sqlplus_logfile);
            utl_file.fremove(location=>'TMPDIR', filename=>l_sqlplus_logfile);
        END IF;
        
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
         *  CLEAN UP ANY INCOMPLETELY TRANSFERRED FILES FROM A PREVIOUS RUN IF NETWORK FAILURE HAD OCCURED DURING FILE TRANSFER
         */
        FOR C IN (SELECT ROWID rid, file_name_renamed FROM migration_ts WHERE migration_status='TRANSFER STARTED') LOOP
            UPDATE migration_ts SET migration_status='TRANSFER NOT STARTED' WHERE ROWID=C.rid;
            IF (file_exists(C.file_name_renamed)) THEN
                log('Removing incompletely transferred '||C.file_name_renamed);
                utl_file.fremove(location=>'TGT_FILES_DIR', filename=>C.file_name_renamed);    
            END IF;
        END LOOP;
        
        FOR C IN (SELECT ROWID rid, bp_file_name FROM migration_bp WHERE migration_status='TRANSFER STARTED') LOOP
            UPDATE migration_bp SET migration_status='TRANSFER NOT STARTED' WHERE ROWID=C.rid;
            IF (file_exists(C.bp_file_name)) THEN
                log('Removing incompletely transferred '||C.bp_file_name);
                utl_file.fremove(location=>'TGT_FILES_DIR', filename=>C.bp_file_name);    
            END IF;
        END LOOP;
        
        /*
         *  SET TRANSFER_USER GLOBAL VARIABLE. MIGR_DBLINK CREATED IN CALLING SCRIPT "tgt_migr.sql"
         */
        SELECT username INTO TRANSFER_USER FROM all_db_links WHERE owner='PUBLIC' AND db_link='MIGR_DBLINK';
        
        /*
         *  MIGRATION_TS REGISTERS MIGRATION OF APPLICATION TABLESPACE DATAFILES  
         */
        MERGE INTO migration_ts t
        USING
         (        
             SELECT t.tablespace_name, t.status, f.file_id, SUBSTR(f.file_name,INSTR(f.file_name,'/',-1)+1) file_name, d.directory_name, f.bytes
               FROM dba_data_files@MIGR_DBLINK f, dba_tablespaces@MIGR_DBLINK t, dba_directories@MIGR_DBLINK d
              WHERE t.contents='PERMANENT'
                AND t.tablespace_name NOT IN ('SYSTEM','SYSAUX')
                AND t.tablespace_name=f.tablespace_name
                AND d.directory_path=SUBSTR(f.file_name,1,INSTR(f.file_name,'/',-1)-1)
                AND d.directory_name<>'TGT_FILES_DIR'
              UNION ALL
             SELECT t.name as tablespace_name, f.enabled, c.file# as file_id, SUBSTR(c.name,INSTR(c.name,'/',-1)+1) as file_name, dir.directory_name, f.bytes
               FROM v$datafile_copy@MIGR_DBLINK c, v$datafile@MIGR_DBLINK f, v$tablespace@MIGR_DBLINK t, dba_directories@MIGR_DBLINK dir
              WHERE c.tag='INCR-TS'
                AND c.status='A'
                AND f.file#=c.file#
                AND t.ts#=f.ts#
                AND dir.directory_path=SUBSTR(c.name,1,INSTR(c.name,'/',-1)-1)
         ) s
        ON (t.file_id=s.file_id)
        WHEN MATCHED THEN
            UPDATE SET t.tablespace_name=s.tablespace_name, t.enabled=s.status, t.bytes=s.bytes
        WHEN NOT MATCHED THEN 
            INSERT (tablespace_name, enabled, file_id, file_name, directory_name, bytes)
            VALUES (s.tablespace_name, s.status, s.file_id, s.file_name, s.directory_name, s.bytes); 
                    
        /*
         *  MIGRATION_BP REGISTERS INCREMENTAL BACKUPS USED TO ROLL FORWARD COPIES OF APPLICATION TABLESPACE DATAFILES
         */
        MERGE INTO migration_bp t
        USING
        (
            SELECT TO_NUMBER(SUBSTR(bp_file_name,INSTR(bp_file_name,'_',1,1)+1,INSTR(bp_file_name,'_',1,2)-INSTR(bp_file_name,'_',1,1)-1)) file_id,
                   recid, bytes, directory_name, bp_file_name
              FROM (
                     SELECT SUBSTR(p.handle,INSTR(p.handle,'/',-1)+1) bp_file_name, p.bytes, dir.directory_name, p.recid 
                       FROM v$backup_piece@MIGR_DBLINK p, dba_directories@MIGR_DBLINK dir 
                      WHERE p.tag='INCR-TS' 
                        AND p.status='A'
                        AND dir.directory_path=SUBSTR(p.handle,1,INSTR(p.handle,'/',-1)-1)
                    )
        ) s
        ON (t.recid=s.recid)
        WHEN NOT MATCHED THEN 
            INSERT (recid, file_id, bp_file_name, directory_name, bytes)
            VALUES (s.recid, s.file_id, s.bp_file_name, s.directory_name, s.bytes);  

        COMMIT;
                 
        FOR C IN (SELECT NULL FROM database_properties WHERE property_name='NLS_CHARACTERSET' AND property_value<>'AL32UTF8') LOOP
            checkCharsets(pOverride);
        END LOOP;
        
        SELECT directory_path INTO DATAFILE_PATH FROM all_directories WHERE directory_name='TGT_FILES_DIR';
        SELECT directory_path INTO TEMPFILE_PATH FROM all_directories WHERE directory_name='TMPDIR';
        
        log_details;
        
        IF (pOverride<>'CONV-DB') THEN
            file_transfer;
        END IF;
        
        FOR C IN (SELECT COUNT(*)-SUM(DECODE(enabled,'READ ONLY',1,0)) all_readonly FROM migration_ts@MIGR_DBLINK WHERE from_scn IS NOT NULL)
        LOOP
            apply_incremental;
            IF (C.all_readonly>0) THEN
                log('ROLLED FORWARD INCREMENTAL BACKUPS');
                RETURN;
            END IF;
        END LOOP;
        
        log('CREATING DATAPUMP PARFILES AND BUILDING SCRIPT ' || TEMPFILE_PATH || '/migration_impdp.sh');
        log('DATAPUMP LOGS ARE LOADED HERE WHEN JOBS COMPLETE. LIVE LOG FILE AT "'||TEMPFILE_PATH||'/migration.log"');
        
        l_parfiles:=create_parfile(pOverride);
        
        f:=utl_file.fopen(location=>'TMPDIR', filename=>'migration_impdp.sh', open_mode=>'w', max_linesize=>32767);
        FOR C IN (SELECT TEMPFILE_PATH || '/' || REGEXP_SUBSTR(l_parfiles,'[^,]+', 1, level) parfile, level as lvl
                    FROM dual
                    CONNECT BY REGEXP_SUBSTR(l_parfiles, '[^,]+', 1, level) IS NOT NULL) 
        LOOP
            utl_file.put_line(f,'impdp /@' || PDBNAME || ' parfile=' || C.parfile); 
            utl_file.put_line(f,'sqlplus -s /@' || PDBNAME || '<<EOF');
            IF (C.lvl<2) THEN
                utl_file.put_line(f,'exec pck_migration_tgt.uploadLog('''||PDBNAME||'.impdp.log'')');
            ELSE
                utl_file.put_line(f,'exec pck_migration_tgt.uploadLog('''||PDBNAME||'.impdp.log.'||C.lvl||''')');
            END IF;
            utl_file.put_line(f,'EOF');
            utl_file.put_line(f,'if [ $? -eq 1 ]');
            utl_file.put_line(f,'then');
            utl_file.put_line(f,'  echo "FAILURE RUNNING impdp parfile='|| C.parfile ||'"');
            utl_file.put_line(f,'  exit 1');
            utl_file.put_line(f,'fi');
        END LOOP;
        utl_file.fclose(f);
        
        f:=utl_file.fopen(location=>'TMPDIR', filename=>'migration_final.sh', open_mode=>'w', max_linesize=>32767);
        utl_file.put_line(f,'sqlplus -s /nolog<<EOF');
        utl_file.put_line(f,'whenever sqlerror exit failure');
        utl_file.put_line(f,'set echo on');
        utl_file.put_line(f,'connect /@' || PDBNAME); 
        IF (pOverride='XTTS-TS') THEN
            utl_file.put_line(f,'exec pck_migration_tgt.post_migration(pResetUser=>TRUE)');
        ELSE
            utl_file.put_line(f,'exec pck_migration_tgt.post_migration(pResetUser=>FALSE)');
        END IF;
        utl_file.put_line(f,'connect / as sysdba'); 
        utl_file.put_line(f,'spool ' || TEMPFILE_PATH || '/' || PDBNAME||'.sys.log');
        utl_file.put_line(f,'start ' || TEMPFILE_PATH || '/migration.sys.sql'); 
        utl_file.put_line(f,'spool off');
        utl_file.put_line(f,'connect /@' || PDBNAME); 
        utl_file.put_line(f,'exec pck_migration_tgt.uploadLog('''||PDBNAME||'.sys.log'')');
        utl_file.put_line(f,'exec pck_migration_tgt.log(''MIGRATION COMPLETED'',''-'')');
        utl_file.put_line(f,'EOF');
        utl_file.put_line(f,'if [ $? -eq 1 ]');
        utl_file.put_line(f,'then');
        utl_file.put_line(f,'  echo "FAILURE RUNNING migration_final.sh"');
        utl_file.put_line(f,'  exit 1');
        utl_file.put_line(f,'fi');
        utl_file.fclose(f);        

        /*
         *  Create SQLPLUS script that grants privileges on SYS-owned objects to migrated users 
         */
        f:=utl_file.fopen(location=>'TMPDIR', filename=>'migration.sys.sql', open_mode=>'w', max_linesize=>32767);
        
        print_sqlcmd('ALTER SESSION SET CONTAINER='||PDBNAME||';');
        
        FOR C IN (
            SELECT 'GRANT '||privilege||' ON '|| DECODE(type,'DIRECTORY',type,NULL) || ' ' || owner||'.'||table_name||' TO '||grantee||''||
                    DECODE(grantable,'YES',' WITH GRANT OPTION ')||DECODE(hierarchy,'YES',' WITH HIERARCHY OPTION ')||';' command
            FROM dba_tab_privs@MIGR_DBLINK
            WHERE grantee<>TRANSFER_USER
            AND table_name NOT IN (SELECT directory_name FROM migration_ts WHERE migration_status='TRANSFER COMPLETED')
            AND owner in
             (SELECT name
             FROM system.logstdby$skip_support@MIGR_DBLINK
             WHERE action=0)
             and grantee in
             (SELECT username
             FROM dba_users@MIGR_DBLINK
             WHERE username not in
             (SELECT name
             FROM system.logstdby$skip_support@MIGR_DBLINK
             WHERE action=0) )
        ) 
        LOOP
            print_sqlcmd(C.command);
        END LOOP;
        
        /*
         *  RECOMPILE ANY INVALID OBJECTS - COULD BE A FEW IF THESE WERE REFERENCING SYS-OWNED OBJECTS
         */
        print_sqlcmd('utl_recomp.recomp_serial();',TRUE);
        
        FOR C IN (SELECT repeat_interval FROM user_scheduler_jobs@MIGR_DBLINK WHERE job_name='MIGRATION_INCR') LOOP
            print_sqlcmd('dbms_scheduler.stop_job(''PDBADMIN.MIGRATION'');',TRUE);
        END LOOP;
        
        utl_file.fclose(f);
        
        EXCEPTION
            WHEN OTHERS THEN
                IF (utl_file.is_open(f)) THEN utl_file.fclose(f); END IF;
                log('ABORTED MIGRATION JOB - '||SQLCODE||' - '||SUBSTR(sqlerrm,1,4000));
                log(sys.DBMS_UTILITY.format_error_backtrace);
                log(sys.DBMS_UTILITY.format_call_stack);
                RAISE;
    END;
END;
/
