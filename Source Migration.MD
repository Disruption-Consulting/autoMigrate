# INSTALLATION
The installation comprises only one script file, "src_migr.sql". 

Logon (or sudo) to "oracle" software owner, although any account that belongs to "dba" group and has sysdba
privilege can run this script.

Place the script on a suitable filesystem - it only generates a few bytes of informational output.


# RUN COMMAND                         
              
```
sqlplus / as sysdba @src_migr.sql \
    mode=[ANALYZE|EXECUTE|RESET-TS|INCR-TS|INCR-TS-FINAL]
```
                         
# PARAMETERS   
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

  
# OPERATING NOTES

All migrations with this utility use the Transportable Tablespace feature, which requires that source tablespaces are set to read only before they are copied to the target database and plugged in using DATAPUMP. A period of application downtime is therefore unavoidable from the moment the tablespaces are set read only until the completion of the DATAPUMP process. 

A major limiting factor occurs when a combination of large data volumes and limited network bandwidth result in unacceptably long migration times. To resolve this problem, the automigrate utility offers 2 modes of operation. Both result in an identical migration; the only difference is how the data is transferred to the target server before it is ready for integration into the target database.

1. Direct Migration
2. Incremental Backup Migration

## Direct Migration
As an example, with an effective network transfer rate of 100GB/hour and a 500GB database called SALES running on AIX it would take about 6 hours to complete a direct migration to a PDB running on LINUX. 

Two interventions would be required - one on AIX and one on LINUX:

1. Run the source database migration script on AIX having set its environment. 

```
export ORACLE_SID=SALES
ORAENV_ASK=NO
. oraenv
ORAENV_ASK=YES;

sqlplus / as sysdba @src_migr.sql MODE=EXECUTE
```

2. Start the target database migration on LINUX

```
export ORACLE_SID=V19CDB
ORAENV_ASK=NO
. oraenv
ORAENV_ASK=YES;

sqlplus / as sysdba @tgt_migr.sql USER=SNFTRANSFER HOST=10.1.23.127 SERVICE=SALES PDBNAME=SALES
#
#  wait 5 seconds to create a new PDB called SALES in the V19CDB database
#  wait 5 hours for 500GB of data files to be transferred from the AIX server to the target LINUX server
#  wait 1 hour for DATAPUMP to plug in the tablespaces, copy application metadata, and gather statistics
#
```
## Incremental Backup Migration
Where application availability is critical to the business and downtime must be limited to say, 1 hour maximum, then the same database could be migrated as a 3 step process over the course of 6 days during which period it would be fully available to the business. Application downtime would be limited to 1 hour on the Saturday.


1. Start the source database migration job on AIX on Monday:
```
export ORACLE_SID=SALES
ORAENV_ASK=NO
. oraenv
ORAENV_ASK=YES;

sqlplus / as sysdba @src_migr.sql MODE=INCR-TS INCR-TS-DIR=/u02/backups
```

2. Start the target database migration job on LINUX also on Monday:
```
export ORACLE_SID=V19CDB
ORAENV_ASK=NO
. oraenv
ORAENV_ASK=YES;

sqlplus / as sysdba @tgt_migr.sql USER=SNFTRANSFER HOST=10.1.23.127 SERVICE=WMLDEV PDBNAME=SALES

# At this point there is a background job on AIX running incremental backups every hour (by default)
# At the same time there is a corresponding background job on LINUX running at the same frequency 
# transferring AIX backups and applying them to its local copy of the tablespace datafiles
# This continues indefinitely until ....
```

3. On the following Saturday finalize the migration on AIX:
```
export ORACLE_SID=SALES
ORAENV_ASK=NO
. oraenv
ORAENV_ASK=YES;

sqlplus / as sysdba @src_migr.sql MODE=INCR-TS-FINAL
```

As far as the business are concerned, their application remains available from Monday through Saturday. During this period incremental backups are automatically taken at a user-defined frequency, transferred and applied automatically to the target database copy. On cut-over day, depending on how frequently backups have been taken, the final backup/apply process typically takes a very short period to complete.

Step 3 completes the migration in about 1 hour - the time it takes to set the AIX tablespaces to read only, take and apply a final incremental backup and run the DATAPUMP integration job.

**Note that if the SALES database had been 2TB, then the Direct Migration would have taken the best part of 24 hours; an equivalent incremental backup Migration would still have taken 1 hour to complete.
