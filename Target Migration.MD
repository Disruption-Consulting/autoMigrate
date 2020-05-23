INSTALLATION
------------
The installation comprises only one script file, "tgt_migr.sql". 

Logon to "oracle" software owner, although any account belonging to the "dba" group can run this script.

Place the script on a suitable filesystem - it only generates a few bytes of informational output.


RUN COMMAND                         
-----------
              
```
sqlplus / as sysdba @tgt_migr.sql \
    USER=SNFTRANSFER \
    HOST=10.1.23.124 \
    SERVICE=SALES \
    PDBNAME=PDB01 
```

Migrates the database running on host 10.1.23.124 with listener service SALES to the current CDB as a new PDB called PDB01.

                         
PARAMETERS:
-----------   
Parameters listed in *`italics`* are optional.

`USER`   
>Name of user created on source database through which we access data and metadata via a db link.

`HOST`
>Name of the server hosting the source database.

`PORT`
>Port on which service is registered with the listener. Default is 1521.

`SERVICE`
>Name of the service running on the source database that is registered with the local listener. We use these first 4 parameters to create the database link.

`PDBNAME`
>Name of the Pluggable database (PDB) to be created in the current CDB. Will normally be the name of the source database.
  
*`TMPDIR`*
>Directory where temporary files created during the migration should be held. Default is `/tmp`

*`OVERRIDE=[CONV-DB|XTTS-TS]`*
- *`CONV-DB`* - forces migration by FULL logical export/import. 
- *`XTTS-TS`* - forces migration by TRANSPORTABLE TABLESPACE rather than TRANSPORTABLE DATABASE

*`ACTION=[FORCE-STOP|DEL-UNPLUG|RESTART]`*
- *`FORCE-STOP`*  - stops the MIGRATION_JOB immediately
- *`DEL-UNPLUG`* - if a re-run deletes any transferred data files that have not been plugged into the PDB
- *`RESTART`* - use if restarting after network failure had interrupted a previous run


OPERATING NOTES
---------------
Running`sqlplus / as sysdba @tgt_migr.sql` starts migrating the source database into a new PDB named according to the PDBNAME parameter.

The script parameters USER, HOST, PORT and SERVICE are used to create a DATABASE LINK that connects to the source database. This DB LINK is central to the migration which comprises 2 main steps:

1) transfer application tablespace data files from the source database (converting endianness if necessary).
2) integrate these into the PDB along with application metadata.

The integration step uses DATAPUMP transportable tablespace, hence **ALL** application tablespaces must be set to READ ONLY on the source database prior to the integration step. For all but the smallest databases, the majority of time taken in a migration will be the time spent transferring data; for example, with an effective network bandwith of 100Gb/hour it will take approxiamately 6 hours to migrate a 500GB database (including 1 hour for metadata integration). 

In the schematic below, running `src_migr MODE=EXECUTE` sets all application tablespaces to READ ONLY, effectively making the application inaccessible until the migration is complete. Running the `tgt_migr` script then transfers the data files before completing the migration. 

|AVAILABLE|SOURCE DATABASE|TARGET DATABASE|
|:---:|--|--|
||`sqlplus / @src_migr MODE=EXECUTE`||
|:stop_sign:||`sqlplus / @tgt_migr`|
|:stop_sign:|| **transfer**|
|:stop_sign:|| **datapump**|
|:white_check_mark:|MIGRATION COMPLETE|MIGRATION COMPLETE|


Where critical applications need to be available almost 24hours/day with only a small window of a few hours available to complete the migration, then clearly large databases cannot be migrated using this approach. For example, a 2TB database would take almost a complete day to migrate using the direct method. Moreover, there is no risk mitigation in case of network failure. 

Therefore, the automigrate utility offers migration as a series of incremental source database backups that are continuously applied to the target until an appointed cut-over time. Until that time, the application remains available. 

Running `src_migr MODE=INCR-TS` launches a background job which takes image copies of all data files comprising application tablespaces and subsequently, at defined intervals, takes backups of incremental changes only. A corresponding job on the target database automatically recognizes this mode of migration and transfers the image copies together with their incremental backups at the same interval as the source migration job (default is every hour). The incremental backups are applied to the image copies until a third and final intervention on the source database - runnning `src_migr MODE=INCR-TS-FINAL` sets application tablespaces to READ ONLY before taking a final incremental backup.

When the corresponding migration job next runs on the target database it recognizes that all source tablespaces have been set to READ ONLY and starts the DATAPUMP integration process automatically after applying the final incremental backup. In this way, the source database is completely transferred and consistent with the new target.


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
After launching the `tgt_migr` script, the sqlplus session remains open after submitting a background job to execute the migration. Every migration step is logged in the table MIGRATION_LOG which can be viewed on the sqlplus session by entering "/", e.g.

```
SQL> /
14.05.2020 13:57:20 RUNNING PCK_MIGRATION VERSION 14/5/2020
14.05.2020 13:57:20 ------------------------------------------------------------------------------------------------
14.05.2020 13:57:20 FILE NAME						  | STATUS    |   SOURCE (MB)|	 TARGET (MB)
14.05.2020 13:57:20 ------------------------------------------------------------------------------------------------
14.05.2020 13:57:20 /opt/oracle/oradata/CDB19/PDB01/users01.dbf 	  | STARTED   | 	 5.0 |
14.05.2020 13:57:20							  | COMPLETED | 	     |		5.0
14.05.2020 13:57:21 /opt/oracle/oradata/CDB19/PDB01/ts_test_ts3.dbf	  | STARTED   | 	10.0 |
14.05.2020 13:57:21							  | COMPLETED | 	     |	       10.0
14.05.2020 13:57:21 /opt/oracle/oradata/CDB19/PDB01/ts_test_ts2.dbf	  | STARTED   | 	20.0 |
14.05.2020 13:57:21							  | COMPLETED | 	     |	       20.0
14.05.2020 13:57:21 /opt/oracle/oradata/CDB19/PDB01/new_ts_01.dbf	  | STARTED   | 	30.0 |
14.05.2020 13:57:21							  | COMPLETED | 	     |	       30.0
14.05.2020 13:57:21 /opt/oracle/oradata/CDB19/PDB01/ts_test_ts1.dbf	  | STARTED   |        100.0 |
14.05.2020 13:57:22							  | COMPLETED | 	     |	      100.0
14.05.2020 13:57:22 /opt/oracle/oradata/CDB19/PDB01/ts_readonly.dbf	  | STARTED   |        100.0 |
14.05.2020 13:57:23							  | COMPLETED | 	     |	      100.0
14.05.2020 13:57:23 ------------------------------------------------------------------------------------------------
14.05.2020 13:57:23					TOTAL TRANSFERRED | COMPLETED |        265.0 |	      265.0
14.05.2020 13:57:23 ------------------------------------------------------------------------------------------------
14.05.2020 13:57:23 ALIGNING JOB REPEAT_INTERVAL
14.05.2020 13:57:24 SETTING MIGRATION_JOB REPEAT_INTERVAL TO freq=hourly; byminute=0; bysecond=0;
```
