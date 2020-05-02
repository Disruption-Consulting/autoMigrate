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
    mode=[ANALYZE|EXECUTE|RESET-TS|INCR-TS|INCR-TS-FINAL] \
    incr-ts-dir=directory-path \
    incr-ts-freq="freq=hourly; byminute=0; bysecond=0;"
```


                         
PARAMETERS:
-----------                   
*`mode=[ANALYZE|EXECUTE|INCR-TS|INCR-TS-FINAL|RESET-TS|REMOVE]`*
- *`ANALYZE`* - outputs details pertinent to the migration - e.g. size, database name, service name etc. Recommended to always
start with this.
  
mode=EXECUTE
  Prepares the migration based on an optimal transportable tablespace method determined by database version. 
  Recommended for small databases (<500GB) where downtime of approx. half a day is acceptable (depending on network capacity
  and reliability).

mode=RESET-TS
  Use this following a successful migration in order to set tablespaces back to their former status.

mode=REMOVE
  Remove all objects created by this script from the database - i.e. schema SNFTRANSFER and various directories depending
  on whether the INCR-TS mode had been run. Additionally, all backups are deleted if the application had previously been 
  running incremental backups
  
mode=INCR-TS
  For use when the database requires maximum availability throughout the migration. 
  Application data changes are continuously backed up in a background job and restored to a maintained copy 
  on the target database.
                     
mode=INCR-TS-FINAL
  Sets all tablespaces to read only ensuring that when the next incremental backup is applied, the source and target 
  databases will be consistent. This automatically triggers the metadata integration process on the source database.
  
                     
(2)                         
incr-ts-dir=directory-path
  Directory where backups of application datafiles are created prior to being transported to the target database server.
  Needs at least as much capacity as the existing database. 
  
  
(3)
incr-ts-freq="freq=hourly; byminute=0; bysecond=0;"
  Frequency with which the background dbms_scheduler job will execute in order to create incremental backups.
  Surround value in single or double quotes since the parser routine is looking for keyword=value pairs.
  Default is as shown - i.e. every hour on the hour. Please see https://oracle-base.com/articles/10g/scheduler-10g for other 
  options - e.g. 'freq=daily; byhour=6; byminute=0; bysecond=0;' is every day at 6AM.
  
  
OPERATING NOTES
---------------
Both mode=EXECUTE and mode=INCR-TS creates

  USER: SNFTRANSFER  
  PACKAGE: PCK_MIGRATION_SRC
  
In the case of mode=INCR-TS
---------------------------
The following objects are created to automate migration by incremental backup:

  TABLE: INCR_TS
    - maintains the next SCN to be used for each application tablespace datafile
    
  JOB: MIGRATION_INCR
    - runs according to the defined schedule (default is on the hour every hour). Executes PCK_MIGRATION_SRC.INCR_TS
    
  DIRECTORY: AIX_FILES_1_DIR
    - references the OS directory defined with the INCR-TS-DIR parameter
    - needs to have capacity to hold copies of at least all application database datafiles

  
In the case of mode=EXECUTE
---------------------------
  DIRECTORIES : AIX_FILES_n_DIR
    - A directory is created for each distinct directory path holding Application tablespace datafiles.
    - Required for file transber by DBMS_FILE_TRANSFER
