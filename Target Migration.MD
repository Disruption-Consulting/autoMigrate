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


                         
PARAMETERS (7):
---------------           
(1)           
`USER`   
  Default is "SNFTRANSFER" - this is the user created on source database that we use to create a global database link
  through which we access data and metadata on the source database.

(2)
`HOST`
  Name of the server hosting the source database.

(3)
`SERVICE`
  Name of the service running on the source database that is registered with the local listener. We use these first 3 
  items to create the database link.

(4)
`PDBNAME`
  Name of the Pluggable database (PDB) to be created in the current CDB. Will normally be the name of the source database.

(5)
*`START=PDB`*
  Start the process by creating a new PDB (DEFAULT)

*`START=TRANSFER`* 
  Start the process by transferring data files from the source database. Once complete will run the datapump migration.

(6)
*`MIGRATE=CONV-DB`*
  Forces migration by FULL import - i.e. logical data export/import instead of file transfer.
  Originally intended as a solution for changing characterset to AL32UTF8 (the default for CDB). 
  NB: Since 12.2 PDBs of any characterset can be plugged into an AL32UTF8 CDB.
  
*`MIGRATE=XTTS-TS`*
  Forces migration by TRANSPORTABLE TABLESPACE - only for me to test as I don't have Oracle 10 (or 11 for that matter).

(7)
*`ACTION=FORCE-STOP`*
  Forces a running MIGRATION_JOB to be stopped before relaunching. E.g. for use when previous transfer run interrupted by network failure

*`ACTION=DEL-UNPLUG`*
  If deleting PDB on a re-run, will delete any tablespace data files that have been transferred but not plugged in


OPERATING NOTES
---------------
Once the source database has been prepared - `sqlplus / @src_migr.sql`, running this script on the destination server (e.g. RHEL) will migrate the source database into a new PDB named according to the PDBNAME parameter.

The other script parameters (USER, HOST, SERVICE) are used to create a DATABASE LINK within the PDB that connects to the source database. This DB LINK is central to the migration and performs the following major tasks:

1) transfer application tablespace data files from the source database
2) integrate these into the PDB along with application metadata.

The integration step uses the DATAPUMP transportable tablespace feature, hence **ALL** application tablespaces must be set to READ ONLY on the source database prior to the migration. This is done by running the `src_migr.sql` script either with MODE=EXECUTE or MODE=INCR-TS. This effects only how the data is transferred; the final integration step is identical.

With MODE=EXECUTE, source application tablespaces are immediately set to READ ONLY. Running the `tgt_migr` script then transfers the data files before completing the migration. Depending on network capacity and the volume of data to be transferred, this could take, for example approximately 6 hours to completely migrate a 500GB database on an effective bandwidth of 100GB/hour (including time to import metadata and generate database statistics).

|AVAILABLE|SOURCE DATABASE|TARGET DATABASE|
|:---:|--|--|
||`sqlplus / @src_migr MODE=EXECUTE`||
|:stop_sign:||`sqlplus / @tgt_migr`|
|:stop_sign:|| **transfer**|
|:stop_sign:|| **datapump**|
|:white_check_mark:|MIGRATION COMPLETE|MIGRATION COMPLETE|


Where critical applications need to be available almost 24hours/day with only a small window of a few hours available to complete the migration, then clearly large databases cannot be migrated using the method described above. For example, a 2TB database would take almost a complete day to migrate using the direct method. Moreover, there is no risk mitigation in case of network failure. 

Therefore, the automigrate utility offers migration as a series of incremental source database backups that are continuously applied to the target until an appointed cut-over time.

Running `src_migr MODE=INCR-TS` launches a background job which takes image copies of all data files comprising application tablespaces and subsequently at intervals (default is every hour) takes backups of incremental changes only. A corresponding job on the target database automatically recognizes this mode of migration and transfers the image copies together with their incremental backups at the same interval as the source migration job. The incremental backups are applied to the image copies until a third and final intervention on the source database - runnning `src_migr MODE=INCR-TS-FINAL` sets application tablespaces to READ ONLY before taking a final incremental backup.

When the corresponding migration job on the target database next runs, it recognizes that all source tablespaces have been set to READ ONLY and starts the DATAPUMP integration process automatically after applying the final incremental backup. In this way, the source database is completely transferred.


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

In this way, the application remains available throughout the migration until the end when a final backup and transfer trigger the datapump integration step. A job that runs by default every hour is launched on both the source and target databases which takes image backups of all application tablespace data files followed by incremantal block change backups. The corresponding job on the target database transfers these files until it recognizes that a final backup has been taken which it applies before starting the normal datapump integration to complete the migration.

PROGRESS MONITORING
-------------------
After launching the `tgt_migr` script, the sqlplus session remains open. Submitting "/" will show progress of the migration.





