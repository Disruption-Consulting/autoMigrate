CREATE OR REPLACE PACKAGE pck_migration_rollforward AS
    PROCEDURE apply;
END;
/

CREATE OR REPLACE PACKAGE BODY pck_migration_rollforward AS
    PROCEDURE apply IS
    /*
     *   Procedure: apply
     *
     *   Description : Running in C##MIGRATION Common schema owing to bug running dbms_backup_restore in PDB
     *                 DBLINK to the target PDB must be created (re-created) before running this procedure
     *                 in order to access tables in the PDBADMIN schema
     */
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
        SELECT ts.platform_id, bp.file_id, ts.file_name ts_file_name, bp.bp_file_name, bp.recid
          BULK COLLECT INTO l_incr
          FROM migration_bp@PDB_DBLINK bp, migration_ts@PDB_DBLINK ts
         WHERE bp.file_id=ts.file_id
           AND bp.migration_status='TRANSFER COMPLETED'
         ORDER BY bp.recid;

        FOR i IN 1..l_incr.COUNT
        LOOP
            IF (i=1) THEN
                SELECT directory_path||'/'
                  INTO l_dir_path
                  FROM cdb_directories
                 WHERE directory_name='TGT_FILES_DIR';
            END IF;

            d := sys.dbms_backup_restore.deviceAllocate;

            /* Start conversation to apply incremental backups to existing datafiles */
            sys.dbms_backup_restore.restoreSetXttFile(pltfrmfr=>l_incr(i).platform_id, xttincr=>TRUE) ;

            /*
             *  Apply an incremental backup from the backup set to the previously downloaded image copy of the datafile.
             */
            INSERT INTO migration_log@PDB_DBLINK(log_message) VALUES ('Rollforward '||l_dir_path||l_incr(i).ts_file_name||' .. with '||l_dir_path||l_incr(i).bp_file_name);
            sys.dbms_backup_restore.restoreXttFileTo(xtype=>2, xfno=>l_incr(i).file_id, xtsname=>NULL, xfname =>l_dir_path||l_incr(i).ts_file_name);

            /*
             *  Sets up the handle for xttRestore to use.
             */
            sys.dbms_backup_restore.xttRestore(handle=>l_dir_path||l_incr(i).bp_file_name, done=>l_done);

            UPDATE migration_bp@PDB_DBLINK SET migration_status='APPLIED' WHERE recid=l_incr(i).recid;
            --utl_file.fremove(location=>'TGT_FILES_DIR', filename=>l_incr(i).bp_file_name);

            --UPDATE migration_ts@MIGR_DBLINK SET applied=SYSDATE WHERE file#=l_incr(i).file_id;

            COMMIT;

            sys.dbms_backup_restore.restoreCancel(TRUE);
            sys.dbms_backup_restore.deviceDeallocate;
        END LOOP;
    END;
END;
/