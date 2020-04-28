# automigrate
Automate the migration of NON-CDB Oracle databases versions 10 through 12 into PDB

OVERVIEW
--------
This project attempts to unify the various methods available for migrating Oracle databases into the Multitenant architecture. 
Database migrations are generally complex projects involving dozens of steps executed on both source and target systems. Selecting an optimal migration method depends on a number of factors, including version and size of the database being migrated, its availability during the migration as well as any cross platform requirements.

This project aims to reduce a cross-platform migration to a minimum of interventions, involving a preparation script on the source database and an execution script on the target database. Where business needs demand minimum downtime, a third intervention on the source database is required to finalize the process.

BACKGROUND
----------
Starting with Oracle version 20, the NON-CDB architecture is no longer supported. However, most production Oracle landscapes include at least some version 10, 11 and 12 databases. With increasing emphasis on reducing the enterprise cost of IT infrastructure, there is a growing need to simplify the process of database migration. This project was motivated by the need to migrate some 40 Production Oracle databases, versions 10 through 12 running on AIX to version 19 PDBs running on Linux RHEL. The announcement (November, 2019) by Oracle that 3 PDBs may now run license-free per version 19 CDB is further motivation to deliver a more automated migration process.

DESCRIPTION:
------------

Migrations with this utility involve at some stage placing all of the source database application tablespaces into read only mode. 
This is a pre-requisite of transportable tablespace whereby data movement is fast and physical (database blocks) rather than slow and logical (table rows).

However, with limited network capacity, transporting terabytes of data can take days to complete during which time hosted applications are unavailable.
To resolve this problem, the data can be transported by a process of restoring source tablespace datafiles on the target and continuously applying incremental backups; 
during this "recovery" period the source database remains available. To start this process, run the script with "mode=INCR-TS". 
At cut-over, run the script a second time with "mode=INCR-TS-FINAL" to apply a final incremental backup taken after the source tablespaces are set to read only.

Where availability is not such an issue, running this script with "mode=EXECUTE" results in all application tablespaces being set to read only.
The migration will then proceed directly when started on the target database.

In both cases, migration on the target database uses the Oracle datapump utility over a network link. This script therefore creates
a user named SNFTRANSFER with the SELECT ANY DICTIONARY and DATAPUMP_EXP_FULL_DATABASE privileges. 

For "mode=INCR-TS", the SNFTRANSFER user is granted execute privilege on the dbms_backup_restore package; in addition a table "SNFTRANSFER.INCR_TS" is created to
maintain next SCN by data file, as well as a procedure "SNFTRANSFER.P_INCR_TS" which is called by a job called "MIGRATION_INCR" in order to generate the file image and 
incremental backups.


COMMAND:                         
--------
                         
sqlplus / as sysdba @aix_migr.sql \
    mode=[ANALYZE|EXECUTE|RESET-TS|INCR-TS|INCR-TS-FINAL] \
    incr-ts-dir=directory-path
       
                         
PARAMETERS(2):
--------------           
(1)           
mode=ANALYZE   
  Output details that are pertinent to the migration - e.g. size, tablespaces and their status, tablespace transportability test result. Default if not specified. 
  Recommended to always start with this.
  
mode=EXECUTE
  Prepares the migration based on an optimal transportable tablespace method determined by database version. 
  Recommended for small databases (<500GB) where downtime of approx. half a day is acceptable (depending on network capacity and reliability).

mode=RESET-TS
  Use this following a successful migration in order to set tablespaces back to their former status.
}');

dbms_output.put_line(q'{                   
mode=INCR-TS
  Use this when the database requires maximum availability throughout the migration. 
  Application tablespace data block changes are continuously backed up in a background job and restored to a maintained copy on the target database.
                     
mode=INCR-TS-FINAL
  Sets all tablespaces to read only ensuring that after the next incremental backup is applied, the source and target databases will be consistent.

                     
(2)                         
incr-ts-dir=directory-path
  Directory where backups of application datafiles are created prior to being transported to the target database server.
  Needs at least as much capacity as the existing database.
                         
                         
