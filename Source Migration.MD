INSTALLATION
------------
The installation comprises only one script file, "src_migr.sql". 

Logon (or sudo) to "oracle" software owner, although any account that belongs to "dba" group and has sysdba
privilege can run this script.

Place the script on a suitable filesystem - it only generates a few bytes of informational output.


RUN COMMAND                         
-----------
              
```
sqlplus / as sysdba @src_migr.sql \
    mode=[ANALYZE|EXECUTE|RESET-TS|INCR-TS|INCR-TS-FINAL]
```
                         
PARAMETERS:
-----------   
Parameters in `italics` are optional.

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
>frequency for taking incremental backups - default is on the hour every hour - only relevant for `MODE=INCR-TS`

*`USER`*
>Name of transfer user. Default is SNFTRANSFER.

see https://oracle-base.com/articles/10g/scheduler-10g for setting *`INCR-TS-FREQ`* E.g.
*`INCR-TS-FREQ='freq=daily; byhour=6; byminute=0; bysecond=0;'`* is every day at 6AM.
  
  
OPERATING NOTES
---------------
Both mode=EXECUTE and INCR-TS create a user (DEFAULT name SNFTRANSFER) which serves as the conduit for the migration. To support the migration, DIRECTORY object(s) are created as well as a table to hold details about SCN number to use for the next incremental backup.

DBMS_FILE_TRANSFER is used on the target database to get files from the source database. This ensures that if source and target platforms have different endianness (e.g. big on AIX and little on Linux) then each transferred file is automatically converted as required.
