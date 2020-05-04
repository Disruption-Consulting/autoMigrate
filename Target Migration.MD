INSTALLATION
------------
The installation comprises only one script file, "tgt_migr.sql". 

Logon (or sudo) to "oracle" software owner, although any account that belongs to the "dba" group and therefore has sysdba
privilege can run this script.

Place the script on a suitable filesystem - it only generates a few bytes of informational output.


RUN COMMAND                         
-----------
              
```
sqlplus / as sysdba @tgt_migr.sql \
    USER=SNFTRANSFER \
    HOST=xxxxxxxxxxx \
    SERVICE=ssssssss \
    PDBNAME=pppppppp 
```


                         
PARAMETERS:
-----------                   
`USER`   
  Name of user created on source database that we use to create a global database link through which we access data and 
  metadata on the source database.

`HOST`
  Name of the server hosting the source database.

`SERVICE`
  Name of the service running on the source database that is registered with the local listener. We use these first 3 
  parameters to create the database link.

`PDBNAME`
  Name of the Pluggable database (PDB) to be created in the current CDB. Will normally be the name of the source database.
  
`TMPDIR`
  OS directory where temporary files created during the migration should be held.

*`START=[PDB|TRANSFER]`*
- *`PDB`* - starts by creating the new target PDB (DEFAULT)
- *`TRANSFER`* - starts the process by transferring data files from the source database. Use, for example, to restart after network failure interrupted a previous run.

*`MIGRATE=[CONV-DB|XTTS-TS]`*
- *`CONV`* - forces migration by FULL logical export/import. Thought it was a good idea in case use wanted to change characterset. NB: Since 12.2 PDBs of any characterset can be plugged into an AL32UTF8 CDB.
- *`XTTS-TS`* - forces migration by TRANSPORTABLE TABLESPACE - only for me to test as I don't have Oracle 10 (or 11 for that matter).

*`ACTION=[FORCE-STOP|DEL-UNPLUG]`*
- *`FORCE-STOP`*  - forces the damn MIGRATION_JOB to be stopped immediately
- *`DEL-UNPLUG`* - If deleting PDB on a re-run, will delete any tablespace data files that have been transferred but not plugged in


OPERATING NOTES
---------------
Running`sqlplus / @tgt_migr.sql` starts migrating the source database into a new PDB named according to the PDBNAME parameter.

The script parameters USER, HOST and SERVICE are used to create a DATABASE LINK that connects to the source database. This DB LINK is central to the migration which commprises 2 main steps:

1) transfer application tablespace data files from the source database (converting endianness if necessary).
2) integrate these into the PDB along with application metadata.

The integration step uses DATAPUMP transportable tablespace, hence **ALL** application tablespaces must be set to READ ONLY on the source database prior to the integration step. For all but the smallest databases, the majority of time taken in a migration will be the time spent transferring data; for example, with an effective network bandwith of 100Gb/hour it will take approxiamately 6 hours to migrate a 500GB database (including 1 hour for metadata integration). 

In the schematic below, running src_migr MODE=EXECUTE immediately sets all tablespaces to READ ONLY, effectively making the application inaccessible until the migration is complete. Running the `tgt_migr` script then transfers the data files before completing the migration. 

|AVAILABLE|SOURCE DATABASE|TARGET DATABASE|
|:---:|--|--|
||`sqlplus / @src_migr MODE=EXECUTE`||
|:stop_sign:||`sqlplus / @tgt_migr`|
|:stop_sign:|| **transfer**|
|:stop_sign:|| **datapump**|
|:white_check_mark:|MIGRATION COMPLETE|MIGRATION COMPLETE|


Where critical applications need to be available almost 24hours/day with only a small window of a few hours available to complete the migration, then clearly large databases cannot be migrated using the method described above. For example, a 2TB database would take almost a complete day to migrate using the direct method. Moreover, there is no risk mitigation in case of network failure. 

Therefore, the automigrate utility offers migration as a series of incremental source database backups that are continuously applied to the target until an appointed cut-over time. Until that time, the application remains available. 

Running `src_migr MODE=INCR-TS` launches a background job which takes image copies of all data files comprising application tablespaces and subsequently, at defined intervals, takes backups of incremental changes only. A corresponding job on the target database automatically recognizes this mode of migration and transfers the image copies together with their incremental backups at the same interval as the source migration job (default is every hour). The incremental backups are applied to the image copies until a third and final intervention on the source database - runnning `src_migr MODE=INCR-TS-FINAL` sets application tablespaces to READ ONLY before taking a final incremental backup.

When the corresponding migration job next runs on the target database it recognizes that all source tablespaces have been set to READ ONLY and starts the DATAPUMP integration process automatically after applying the final incremental backup. In this way, the source database is completely transferred and is consistent with the new target.


|AVAILABLE|SOURCE DATABASE|TARGET DATABASE|
|:---:|--|--|
||`sqlplus / @src_migr MODE=INCR-TS`||
|:white_check_mark:||`sqlplus / @tgt_migr`|
|:white_check_mark:|**backup**|**transfer**|
|:white_check_mark:|**backup**|**transfer**|
|:white_check_mark:|**backup**|**transfer**|
||`sqlplus / @src_migr MODE=INCR-TS-FINAL`||
|:stop_sign:|**final backup**| **final transfer**|
|:stop_sign:|| **datapump**|
|:white_check_mark:|MIGRATION COMPLETE|MIGRATION COMPLETE|


PROGRESS MONITORING
-------------------
After launching the `tgt_migr` script, the sqlplus session remains open; entering "/" shows progress of the migration on the screen. Data transfer progress is displayed first before details of the datapump integration. 





