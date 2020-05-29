# INSTALLATION
The installation comprises only one script file, "src_migr.sql". 

Logon to "oracle" software owner - although any account belonging to "dba" group can run this script.

Place the script on a suitable filesystem - it only generates a few bytes of informational output.


# RUN COMMAND                         
              
```
sqlplus / as sysdba @src_migr.sql \
    mode=[ANALYZE|EXECUTE|RESET|INCR-TS|INCR-TS-FINAL|REMOVE] \
    incr-ts-dir=/dirname \
    incr-ts-freq=frequency
```
                         
# PARAMETERS   
Parameters in *`italics`* are optional.

`MODE=[ANALYZE|EXECUTE|INCR-TS|INCR-TS-FINAL|RESET|REMOVE]`
- `ANALYZE` - show details about the database - e.g. name and size of database (DEFAULT)
  
- `EXECUTE` - prepares database for direct migration - i.e. sets all application tablespaces to read only

- `INCR-TS` - starts migration by taking incremental backups in a background job. Tablespaces remain online
                     
- `INCR-TS-FINAL` - sets all tablespaces to read only before taking a final incremental backup
  
- `RESET` - sets tablespaces back to their pre-migration status

- `REMOVE` - remove all database objects and any backups created for the migration
                           
*`INCR-TS-DIR`*
>directory to store file image copies and incremental backups - mandatory parameter if `MODE=INCR-TS`
  
*`INCR-TS-FREQ`*
>frequency for taking incremental backups - default is on the hour every hour - only relevant for `MODE=INCR-TS` Same syntax as used for dbms_scheduler repeat_interval, e.g. *`INCR-TS-FREQ='freq=daily; byhour=6; byminute=0; bysecond=0;'`* is every day at 6AM.

*`USER`*
>Name of transfer user. Default is PDBADMIN. Ony change this if "PDBADMIN" happens to exist pre-migration.

  
# OPERATING NOTES

All migrations with this utility use the Transportable Tablespace feature, which requires that application tablespaces on the source system are set to read only before being copied to the target database and plugged in using DATAPUMP. A period of application downtime is therefore unavoidable from the moment the tablespaces are set read only until the completion of the DATAPUMP process. 

Since large data volumes and limited network bandwidth may result in an unacceptably long period of application downtime, the automigrate utility offers 2 different methods for copying the source data. The end result is the same in both cases:

1. Direct Transfer
2. Incremental Backup

## Direct Transfer
As an example, with an effective network transfer rate of 100GB/hour and a 500GB database called SALES running on AIX it would take about 6 hours to complete a direct migration to a Pluggable Database running on LINUX. 

Two interventions would be required -

1. Run the source database migration script on AIX host 10.1.23.127. 

```
sqlplus / as sysdba @src_migr.sql MODE=EXECUTE

# - all application tablespaces are now set to read only
# - creates database user PDBADMIN to act as the conduit for the migration
```

2. Start the target database migration on LINUX

```
sqlplus / as sysdba @tgt_migr.sql HOST=10.1.23.127 SERVICE=SALES PDBNAME=SALES

#  - creates a new PDB called SALES
#  - creates database link to SALES database as identified by HOST and SERVICE parameters
#  - starts a job to copy 500GB of data files
#  - when transfer finishes, generates shell script to run "impdp" and complete the migration

```
## Incremental Backup
Where application availability is critical to the business and downtime must be limited to a small window, then the same SALES database could be migrated over the course of 5 days during which period it would be fully available to the business. Application downtime would be limited to only 1 hour on the Saturday.


1. Start the source database migration job on AIX on Monday:
```
sqlplus / as sysdba @src_migr.sql MODE=INCR-TS INCR-TS-DIR=/u02/backups

# - background job is now taking file image copies and incremental backups every hour on the hour (default)
```

2. Start the target database migration job on LINUX also on Monday:
```
sqlplus / as sysdba @tgt_migr.sql HOST=10.1.23.127 SERVICE=SALES PDBNAME=SALES

# - background job, running at the same frequency, retrieves the file image copies and incremental backups
# - applies incremental backups to the file image copies
# - steps 1 and 2 continue until ...
```

3. On the following Saturday, finalize the migration on AIX:
```
sqlplus / as sysdba @src_migr.sql MODE=INCR-TS-FINAL

# - sets application tablespaces to read only - application downtime starts now.
# - takes a final incremental backup and drops the background job
```

4. Straight after on LINUX

Inspect the Job scheduler to determine when the MIGRATION JOB will run next .. it may well have already completed in which case the MIGRATION LOG will reveal the command to complete the migration. How long it takes to complete the migration depends entirely on the size of the application - the more PL/SQL packages, triggers, views etc, the longer it will take for DATAPUMP to complete.


**Note that if the SALES database had been 2TB in size, then a Direct Transfer would have resulted in 24 hours application downtime; the equivalent migration by appyling incremental backups would only require 1 hour downtime.**
