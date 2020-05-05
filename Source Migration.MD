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
- *`ANALYZE`*
>show details about the database - e.g. name and size of database. Should always start with this (DEFAULT)
  
- *`EXECUTE`*
>prepares database for immediate migration. Creates transfer user and sets tablespaces to read only.

- *`INCR-TS`*
>prepares database for migration by a continuous process of taking incremental backups in a background job
                     
- *`INCR-TS-FINAL`*
>sets all tablespaces to read only before taking a final incremental backup.
  
- *`RESET-TS`*
>use this following a successful migration in order to set tablespaces back to their former status.

- *`REMOVE`*
>remove all objects and backups created by this script from the database
                           
*`incr-ts-dir`* - OS directory to store backups - must have at least as much capacity as the existing database
  
*`incr-ts-freq`* - frequency with which the background job executes in order to create incremental backups


  Surround value in single or double quotes since the parser routine is looking for keyword=value pairs.
  Default is as shown - i.e. every hour on the hour. Please see https://oracle-base.com/articles/10g/scheduler-10g for other 
  options - e.g. 'freq=daily; byhour=6; byminute=0; bysecond=0;' is every day at 6AM.
  
  
OPERATING NOTES
---------------
Both mode=EXECUTE and INCR-TS create a user (DEFAULT name SNFTRANSFER) which serves as the conduit for the migration. To support the migration, DIRECTORY object(s) are created as well as a table to hold details about SCN number to use for the next incremental backup.

DBMS_FILE_TRANSFER is used on the target database to get files from the source database. This ensures that if source and target platforms have different endianness (e.g. big on AIX and little on Linux) then each transferred file is automatically converted as required.
