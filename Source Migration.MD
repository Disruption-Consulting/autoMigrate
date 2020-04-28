INSTALLATION
------------
The installation comprises only one script file, "aix_migr.sql". 

Logon (or sudo) to "oracle" software owner, although any account that belongs to "dba" group and has sysdba
privilege can run this script.

Place the script on a suitable filesystem - it only generates a few bytes of informational output.


RUN COMMAND                         
-----------
                         
sqlplus / as sysdba @aix_migr.sql \
    mode=[ANALYZE|EXECUTE|RESET-TS|INCR-TS|INCR-TS-FINAL] \
    incr-ts-dir=directory-path \
    incr-ts-freq="freq=hourly; byminute=0; bysecond=0;"
                         
PARAMETERS (3):
---------------           
(1)           
mode=ANALYZE   
  Output details that are pertinent to the migration - e.g. size, tablespaces and their status, tablespace transportability test result. Default if not specified. 
  Recommended to always start with this.
  
mode=EXECUTE
  Prepares the migration based on an optimal transportable tablespace method determined by database version. 
  Recommended for small databases (<500GB) where downtime of approx. half a day is acceptable (depending on network capacity and reliability).

mode=RESET-TS
  Use this following a successful migration in order to set tablespaces back to their former status.

mode=RESET
  Remove all trace of the operation of this script from the database.
  
mode=INCR-TS
  For use when the database requires maximum availability throughout the migration. 
  Application data changes are continuously backed up in a background job and restored to a maintained copy on the target database.
                     
mode=INCR-TS-FINAL
  Sets all tablespaces to read only ensuring that after the next incremental backup is applied, the source and target databases will be consistent.

                     
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
