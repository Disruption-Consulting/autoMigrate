#INSTALLATION
The installation comprises only one script file, "src_migr.sql". 

Logon (or sudo) to "oracle" software owner, although any account that belongs to "dba" group and has sysdba
privilege can run this script.

Place the script on a suitable filesystem - it only generates a few bytes of informational output.


#RUN COMMAND                         
              
```
sqlplus / as sysdba @src_migr.sql \
    mode=[ANALYZE|EXECUTE|RESET-TS|INCR-TS|INCR-TS-FINAL]
```
                         
#PARAMETERS   
Parameters in *`italics`* are optional.

`MODE=[ANALYZE|EXECUTE|INCR-TS|INCR-TS-FINAL|RESET-TS|REMOVE]`
- `ANALYZE` - show details about the database - e.g. name and size of database. Start with this (DEFAULT)
  
- `EXECUTE` - prepares database for immediate migration - i.e. sets all application tablespaces to read only

- `INCR-TS` - starts migration by taking incremental backups in a background job. Tablespaces remain online
                     
- `INCR-TS-FINAL` - sets all tablespaces to read only before taking a final incremental backup
  
- `RESET-TS` - sets tablespaces back to their pre-migration status

- `REMOVE` - remove all objects and backups created fo the migration
                           
*`INCR-TS-DIR`*
>OS directory to store incremental backups - mandatory if `MODE=INCR-TS`
  
*`INCR-TS-FREQ`*
>frequency for taking incremental backups - default is on the hour every hour - only relevant for `MODE=INCR-TS` Same syntax as used for dbms_scheduler repeat_interval, e.g. *`INCR-TS-FREQ='freq=daily; byhour=6; byminute=0; bysecond=0;'`* is every day at 6AM.

*`USER`*
>Name of transfer user. Default is SNFTRANSFER.

  
#OPERATING NOTES

All migrations with this utility use the Transportable Tablespace feature, which requires that source tablespaces are set to read only before they are copied to the target database and plugged in using DATAPUMP. 

A period of application downtime is therefore unavoidable from the moment the tablespaces are set read only until the completion of the DATAPUMP process. For example, with an effective network transfer rate of 100GB/hour and a 500GB database it will take about 6 hours to complete the migration, including 1 hour to copy application metadata. In such a case, if the business deems 6 hours' downtime acceptable, then this migration is a simple 2 step process. For example, if we are migrating a 500GB SALES database from AIX to a PDB on LINUX where we have already created a CDB called V19CDB:

1. Run the source database migration script having set its environment. 

```
export ORACLE_SID=SALES
ORAENV_ASK=NO
. oraenv
ORAENV_ASK=YES;

sqlplus / as sysdba @src_migr.sql MODE=EXECUTE
```

2. Start the target database migration 

```
export ORACLE_SID=V19CDB
ORAENV_ASK=NO
. oraenv
ORAENV_ASK=YES;

sqlplus / as sysdba @tgt_migr.sql USER=SNFTRANSFER HOST=10.1.23.127 SERVICE=SALES PDBNAME=SALES
#
#  wait 5 minutes to create a new PDB called SALES in the V19CDB database
#  wait 5 hours for 500GB of data files to be transferred from the AIX server to the target LINUX server
#  wait 1 hour for DATAPUMP to plug in the tablespaces and copy application metadata
#
```

However, if application availability is critical to the business and downtime must be limited to say, 1 hour maximum, then the same database can be migrated as a 3 step process. For example:

1. Start the source database migration job on Monday:
```
export ORACLE_SID=SALES
ORAENV_ASK=NO
. oraenv
ORAENV_ASK=YES;

sqlplus / as sysdba @src_migr.sql MODE=INCR-TS INCR-TS-DIR=/u02/backups
```

2. Start the target database migration job also on Monday:
```
export ORACLE_SID=V19CDB
ORAENV_ASK=NO
. oraenv
ORAENV_ASK=YES;

sqlplus / as sysdba @tgt_migr.sql USER=SNFTRANSFER HOST=10.1.23.127 SERVICE=WMLDEV PDBNAME=SALES
```

3. On the following Saturday finalize the migration

DBMS_FILE_TRANSFER is used on the target database to get files from the source database. This ensures that if source and target platforms have different endianness (e.g. big on AIX and little on Linux) then each transferred file is automatically converted as required.
