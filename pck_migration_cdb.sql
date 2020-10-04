CREATE OR REPLACE PACKAGE pck_migration_cdb AS
    --
    FUNCTION transfer(pPdbname IN VARCHAR2) RETURN NUMBER;
    --
END;
/

CREATE OR REPLACE PACKAGE BODY pck_migration_cdb AS
    
    TRANSFER_USER  VARCHAR2(30);
    
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
    -- FUNCTION file_exists
    --   Returns TRUE or FALSE depending on whether input file exists
    --
    -------------------------------
    FUNCTION file_exists(pFilename IN VARCHAR2, pLocation IN VARCHAR2) RETURN BOOLEAN IS
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
    FUNCTION file_bytes(pFilename IN VARCHAR2, pLocation IN VARCHAR2) RETURN NUMBER IS
        l_fexists boolean;
        l_file_length number;
        l_block_size binary_integer;    
    BEGIN
        utl_file.fgetattr(location=>pLocation,filename=>pFilename,fexists=>l_fexists,file_length=>l_file_length,block_size=>l_block_size);
        RETURN (l_file_length);
    END;    
    
    --
    -- PROCEDURE file_copy
    --   Transfer files from remote database server. 
    --   File conversion is automatic when endianess is different between the two platforms, e.g. AIX(big) and LINUX(little).
    --   All files to be transferred are defined in tables "migration_ts" (and "migration_bp", if transfer is via incrmental backup).
    --
    -------------------------------
    PROCEDURE file_copy(pPdbName IN VARCHAR2, pTgtDilesDir IN VARCHAR2, pMigrDblink IN VARCHAR2) IS
        l_datafile_path all_directories.directory_path%type;
        l_error VARCHAR2(200):=NULL;
        l_message VARCHAR2(200);
        l_maxlen_filename PLS_INTEGER:=0;
        l_isomf BOOLEAN;
        l_isasm BOOLEAN;
        l_file_name_renamed migration_ts.file_name_renamed%type;
        l_full_filename cdb_data_files.file_name%type;
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
               SELECT 'migration_ts' table_name, file_id pk, file_name, bytes, directory_name FROM migration_ts WHERE pdb_name=pPdbname AND migration_status='TRANSFER NOT STARTED'
                UNION ALL
               SELECT 'migration_bp' table_name, recid pk, bp_file_name, bytes, directory_name FROM migration_bp WHERE pdb_name=pPdbname AND migration_status='TRANSFER NOT STARTED'
               )
        ORDER BY DECODE(table_name,'migration_ts',0,1),bytes;
        --
        FOR i IN 1..l_transfer.COUNT LOOP
            IF (LENGTH(l_transfer(i).file_name)>l_maxlen_filename) THEN
                l_maxlen_filename:=LENGTH(l_transfer(i).file_name);
            END IF;
        END LOOP;
        l_maxlen_filename:=l_maxlen_filename+7;  -- in case OMF renamed file
        FOR C IN (SELECT directory_path FROM all_directories WHERE directory_name=pTgtDilesDir) LOOP
            l_maxlen_filename:=l_maxlen_filename+1+LENGTH(C.directory_path);
            l_datafile_path:=C.directory_path;
        END LOOP;
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
            l_full_filename:=l_datafile_path||'/'||l_destination_file_name;

            l_start_time:=SYSDATE;
            t:=dbms_utility.get_time;
            log(RPAD(l_full_filename,l_maxlen_filename) ||'|'||
                        RPAD(' STARTED',11) ||'|'||
                        RPAD(TO_CHAR(l_transfer(i).bytes/1024/1024,'99,999,990.0') ,14) ||'|'||
                        RPAD(' ',14));

            CASE l_transfer(i).table_name
                WHEN 'migration_ts' THEN 
                    UPDATE migration_ts 
                       SET migration_status='TRANSFER STARTED', start_time=l_start_time, file_name_renamed=l_destination_file_name
                     WHERE pdb_name=pPdbName AND file_id=l_transfer(i).pk;
                WHEN 'migration_bp' THEN 
                    UPDATE migration_bp 
                       SET migration_status='TRANSFER STARTED', start_time=l_start_time 
                     WHERE pdb_name=pPdbName AND recid=l_transfer(i).pk;
            END CASE;                
            
            COMMIT;
            
            dbms_file_transfer.get_file(
                source_directory_object      => l_transfer(i).directory_name, 
                source_file_name             => l_transfer(i).file_name, 
                source_database              => pMigrDblink, 
                destination_directory_object => pTgtDilesDir, 
                destination_file_name        => l_destination_file_name);

            l_transferred_bytes:=file_bytes(l_destination_file_name,pTgtDilesDir);

            CASE l_transfer(i).table_name
                WHEN 'migration_ts' THEN
                    UPDATE migration_ts 
                       SET migration_status='TRANSFER COMPLETED',
                           start_time=l_start_time, 
                           transferred_bytes=l_transferred_bytes,
                           elapsed_seconds=(dbms_utility.get_time-t)/100,
                           file_name_renamed=l_file_name_renamed
                     WHERE pdb_name=pPdbName AND file_id=l_transfer(i).pk;
                     
                    /*UPDATE migration_ts@MIGR_DBLINK SET transferred=SYSDATE WHERE file#=l_transfer(i).pk;*/

                WHEN 'migration_bp' THEN
                    UPDATE migration_bp 
                       SET migration_status='TRANSFER COMPLETED',
                           start_time=l_start_time, 
                           transferred_bytes=l_transferred_bytes,
                           elapsed_seconds=(dbms_utility.get_time-t)/100
                     WHERE pdb_name=pPdbName AND recid=l_transfer(i).pk;               
            END CASE;

            l_sum_src:=l_sum_src+l_transfer(i).bytes;
            l_sum_tgt:=l_sum_tgt+l_transferred_bytes;
            
            log(RPAD(l_full_filename,l_maxlen_filename) ||'|'||
                        RPAD(' COMPLETED',11) ||'|'||
                        RPAD(TO_CHAR(l_transfer(i).bytes/1024/1024,'99,999,990.0') ,14) ||'|'||
                        RPAD(TO_CHAR(l_transferred_bytes/1024/1024,'99,999,990.0') ,14));
             
            COMMIT;
            
        END LOOP;
        
        log(LPAD('TOTAL TRANSFERRED ',l_maxlen_filename) ||'|'||
            RPAD(' COMPLETED',11)                   ||'|'||
            RPAD(TO_CHAR(l_sum_src/1024/1024,'99,999,990.0'),14) ||'|'||
            RPAD(TO_CHAR(l_sum_tgt/1024/1024,'99,999,990.0'),14),'-');
    END;


    /*
     *  APPLY INCREMENTAL LEVEL 1 BACKUP PIECES TO FILE IMAGE COPIES
     */
    -------------------------------
    PROCEDURE rollforward(pPdbname IN VARCHAR2, pTgtFilesDirName IN VARCHAR2, pMigrDblink IN VARCHAR2) IS
        d  varchar2(512);
        l_done boolean;
        l_platform_id INTEGER;

        TYPE t_incr IS RECORD (
            platform_id     NUMBER,
            file_id         NUMBER,
            ts_file_name    VARCHAR2(513),
            bp_file_name    VARCHAR2(513),
            recid           NUMBER);
        TYPE tt_incr IS TABLE OF t_incr;
        l_incr tt_incr;
        l_dir_path VARCHAR2(500);
    BEGIN
        SELECT ts.platform_id, bp.file_id, ts.file_name, bp.bp_file_name, bp.recid
          BULK COLLECT INTO l_incr
          FROM migration_bp bp, migration_ts ts
         WHERE ts.pdb_name=pPdbname 
           AND bp.pdb_name=ts.pdb_name
           AND bp.file_id=ts.file_id
           AND bp.migration_status='TRANSFER COMPLETED'
         ORDER BY bp.recid;

        FOR i IN 1..l_incr.COUNT
        LOOP
            IF (i=1) THEN
                SELECT directory_path||'/'
                  INTO l_dir_path
                  FROM cdb_directories
                 WHERE directory_name=pTgtFilesDirName;
            END IF;

            d := sys.dbms_backup_restore.deviceAllocate;

            /* Start conversation to apply incremental backups to existing datafiles */
            sys.dbms_backup_restore.restoreSetXttFile(pltfrmfr=>l_incr(i).platform_id, xttincr=>TRUE) ;

            /*
             *  Apply an incremental backup from the backup set to the previously downloaded image copy of the datafile.
             */
            INSERT INTO migration_log(log_message) VALUES ('Rollforward '||l_dir_path||l_incr(i).ts_file_name||' .. with '||l_dir_path||l_incr(i).bp_file_name);
            sys.dbms_backup_restore.restoreXttFileTo(xtype=>2, xfno=>l_incr(i).file_id, xtsname=>NULL, xfname =>l_dir_path||l_incr(i).ts_file_name);

            /*
             *  Sets up the handle for xttRestore to use.
             */
            sys.dbms_backup_restore.xttRestore(handle=>l_dir_path||l_incr(i).bp_file_name, done=>l_done);

            UPDATE migration_bp SET migration_status='APPLIED' WHERE recid=l_incr(i).recid;
            utl_file.fremove(location=>pTgtFilesDirName, filename=>l_incr(i).bp_file_name);

            EXECUTE IMMEDIATE 'UPDATE migration_ts@' || pMigrDblink || ' SET applied=SYSDATE WHERE file#=:file_id' USING l_incr(i).file_id;

            COMMIT;

            sys.dbms_backup_restore.restoreCancel(TRUE);
            sys.dbms_backup_restore.deviceDeallocate;
        END LOOP;
    END;
    
    
    /*
     *  INITIATE DATA FILE TRANSFER
     */
    -------------------------------
    FUNCTION transfer(pPdbname IN VARCHAR2) RETURN NUMBER IS 
        n PLS_INTEGER;
        f utl_file.file_type;
        l_all_readonly PLS_INTEGER;
        l_tgt_files_dir cdb_directories.directory_name%type:='TGT_FILES_DIR_' || pPdbname;
        l_migr_dblink VARCHAR2(128):='MIGR_DBLINK_' || pPdbname;
        l_dml LONG;
        l_merge_ts LONG:=
        q'{MERGE INTO migration_ts t
        USING
         (        
             SELECT platform_id, tablespace_name, status, file_id, file_name, directory_name, bytes
               FROM v_app_tablespaces@#MIGR_DBLINK#
              UNION ALL
             SELECT d.platform_id, t.name as tablespace_name, f.enabled, c.file# as file_id, SUBSTR(c.name,INSTR(c.name,'/',-1)+1) as file_name, dir.directory_name, f.bytes
               FROM v$datafile_copy@#MIGR_DBLINK# c, v$datafile@#MIGR_DBLINK# f, v$tablespace@#MIGR_DBLINK# t, dba_directories@#MIGR_DBLINK# dir, v$database@#MIGR_DBLINK# d
              WHERE c.tag='INCR-TS'
                AND c.status='A'
                AND f.file#=c.file#
                AND t.ts#=f.ts#
                AND dir.directory_path=SUBSTR(c.name,1,INSTR(c.name,'/',-1)-1)
         ) s
        ON (t.pdb_name='#PDB#' AND t.file_id=s.file_id)
        WHEN MATCHED THEN
            UPDATE SET t.tablespace_name=s.tablespace_name, t.enabled=s.status, t.bytes=s.bytes
        WHEN NOT MATCHED THEN 
            INSERT (pdb_name, platform_id, tablespace_name, enabled, file_id, file_name, directory_name, bytes)
            VALUES ('#PDB#', s.platform_id, s.tablespace_name, s.status, s.file_id, s.file_name, s.directory_name, s.bytes)}';
            
        l_merge_bp LONG:=
        q'{MERGE INTO migration_bp t
        USING
        (
            SELECT TO_NUMBER(SUBSTR(bp_file_name,INSTR(bp_file_name,'_',1,1)+1,INSTR(bp_file_name,'_',1,2)-INSTR(bp_file_name,'_',1,1)-1)) file_id,
                   recid, bytes, directory_name, bp_file_name
              FROM (
                     SELECT SUBSTR(p.handle,INSTR(p.handle,'/',-1)+1) bp_file_name, p.bytes, dir.directory_name, p.recid 
                       FROM v$backup_piece@#MIGR_DBLINK# p, dba_directories@#MIGR_DBLINK# dir 
                      WHERE p.tag='INCR-TS' 
                        AND p.status='A'
                        AND dir.directory_path=SUBSTR(p.handle,1,INSTR(p.handle,'/',-1)-1)
                    )
        ) s
        ON (t.pdb_name='#PDB#' AND t.recid=s.recid)
        WHEN NOT MATCHED THEN 
            INSERT (pdb_name, recid, file_id, bp_file_name, directory_name, bytes)
            VALUES ('#PDB#', s.recid, s.file_id, s.bp_file_name, s.directory_name, s.bytes)}';    
            
    BEGIN
        /*
         *  CLEAN UP ANY INCOMPLETELY TRANSFERRED FILES IF NETWORK OR SYSTEMS FAILURE HAD OCCURED DURING A PREVIOUS FILE TRANSFER
         */
        FOR C IN (SELECT ROWID rid, file_name_renamed FROM migration_ts WHERE pdb_name=pPdbName AND migration_status='TRANSFER STARTED') LOOP
            UPDATE migration_ts SET migration_status='TRANSFER NOT STARTED' WHERE ROWID=C.rid;
            IF (file_exists(C.file_name_renamed, l_tgt_files_dir)) THEN
                log('Removing incompletely transferred '||C.file_name_renamed);
                utl_file.fremove(location=>l_tgt_files_dir, filename=>C.file_name_renamed);    
            END IF;
        END LOOP;
        
        FOR C IN (SELECT ROWID rid, bp_file_name FROM migration_bp WHERE pdb_name=pPdbName AND migration_status='TRANSFER STARTED') LOOP
            UPDATE migration_bp SET migration_status='TRANSFER NOT STARTED' WHERE ROWID=C.rid;
            IF (file_exists(C.bp_file_name, l_tgt_files_dir)) THEN
                log('Removing incompletely transferred '||C.bp_file_name);
                utl_file.fremove(location=>l_tgt_files_dir, filename=>C.bp_file_name);    
            END IF;
        END LOOP;
        
        /*
         *  MIGRATION_TS REGISTERS MIGRATION OF APPLICATION TABLESPACE DATAFILES  
         */
        l_dml:=REPLACE(REPLACE(l_merge_ts,'#MIGR_DBLINK#',l_migr_dblink),'#PDB#',pPdbname); 
        EXECUTE IMMEDIATE l_dml;
                    
        /*
         *  MIGRATION_BP REGISTERS INCREMENTAL BACKUPS USED TO ROLL FORWARD IMAGE COPIES OF APPLICATION TABLESPACE DATAFILES
         */
        l_dml:=REPLACE(REPLACE(l_merge_bp,'#MIGR_DBLINK#',l_migr_dblink),'#PDB#',pPdbname); 
        EXECUTE IMMEDIATE l_dml;
        
        COMMIT;
        
        file_copy(pPdbname, l_tgt_files_dir, l_migr_dblink);
        
        EXECUTE IMMEDIATE q'{SELECT COUNT(*)-SUM(DECODE(enabled,'READ ONLY',1,0)) FROM v_app_tablespaces@}' || l_migr_dblink INTO n;
        log('NUMBER OF READ WRITE SOURCE TABLESPACES:'||n);
        rollforward(pPdbname, l_tgt_files_dir, l_migr_dblink);

        RETURN (n);

    END;

END;
/