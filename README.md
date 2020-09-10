# automigrate
Mature solution that reduces the effort and cost migrating Oracle databases to the current terminal version 19 release.

- enables minimal application downtime without licensing extra-cost options
- tested on source database versions 10.1, 10.2, 11.2, 12.1, 12.2, 18.3 (NON-CDB)
- tested on target database versions 19.3 through 19.8 (CDB)

# OVERVIEW

Migrating or even upgrading Oracle database can incur significant cost and disruption, which is why many organizations avoid it for as long as possible. However, at the time of writing (July 2020) there are several factors that make it increasingly incumbent on Oracle customers to migrate to version 19:

- starting with version 20 Oracle will only support Multitenant architecture (CDB)
- you can now run 3 PDBs per CDB license-free starting version 19
- version 19 has the longest support timeframe
- pre version 19 databases are reaching end-of-life
- adoption of Multitenant architecture significantly lowers the total cost of ownership
- version 19 enables limited but cost-free use of features like in-Memory which can drastically reduce elapsed times of some queries
- some variants of Unix (e.g. Solaris, HPUX) are exiting the market as adoption of Linux and Cloud continues to gather momentum

![MRUpdatedReleaseRoadmap5282020](https://user-images.githubusercontent.com/42802860/90099785-2e6a2400-dd33-11ea-826f-661b58bf3d0b.png)


The "autoMigrate" utility was developed to provide a repeatable framework for securely coordinating the large number of tasks involved in database migration, including:

- transporting application data from source to target as an easily restartable process in the event of network or systems failure
- ensuring endianess compatibility of source and target data
- copying metadata definitions from source to target 
- reconciling transferred data and metadata
- gathering accurate statistics of transferred data objects
- confirming use of any DIRECTORY objects in source that may need to be redefined in target
- confirming use of any DATABASE LINK objects that may need to be configured for use in target
- ensuring grants of SYS-owned source objects to application schemas are replayed in the target database
- ensuring tablespaces are set to their pre-migration status on completion

A key advantage offered by autoMigrate is fully integrated functionality to migrate large volumes of data with minimal application downtime. For example, assuming an effective network bandwith of 100 GB/hour, migrating a 1 TB database of medium complexity might take 10 hours to migrate the data with 1 additional hour to integrate the metadata; migrating a 10 TB database would take more than 4 days to migrate. 


|APPLICATION AVAILABLE|ELAPSED TIME|SOURCE DATABASE|TARGET DATABASE|
|:---:|--|--|--|
|:white_check_mark:||**START MIGRATION**||
|:no_entry:|5 mins|`sqlplus @src_migr mode=EXECUTE`||
|:no_entry:|5 mins||`sqlplus @tgt_migr`|
|:no_entry:|10 hours||**...TRANFER DATA**|
|:no_entry:|30 mins||**...TRANSFER METADATA**|
|:no_entry:|20 mins||**...POST-MIGRATION TASKS**|
|:no_entry:|TOTAL **11 hours**|||
|:white_check_mark:|||**MIGRATION COMPLETE**|

To mitigate such cases, the autoMigrate utility allows the Production application to remain fully available whilst it takes regular incremental data file backups in the background. It then transfers and applies these to the target database rolling it forward to near-synchronicity with the source database. In this way, the same 10 TB database would be mostly transferred before being set to read only for a final incremental backup.

|APPLICATION AVAILABLE|ELAPSED TIME|SOURCE DATABASE|TARGET DATABASE|
|:---:|--|--|--|
|:white_check_mark:||**START MIGRATION**||
|:white_check_mark:|5 mins|`sqlplus @src_migr mode=INCR`||
|:white_check_mark:|5 mins||`sqlplus @tgt_migr`|
|:white_check_mark:|10 hours||**...TRANFER DATA**|
|:no_entry:|5 mins|`sqlplus @src_migr mode=EXECUTE`||
|:no_entry:|5 mins||**...FINAL TRANFER DATA**|
|:no_entry:|30 mins||**...TRANSFER METADATA**|
|:no_entry:|20 mins||**...POST-MIGRATION TASKS**|
|:no_entry:|TOTAL: **1 hour**|||
|:white_check_mark:|||**MIGRATION COMPLETE**|

autoMigrate runs the optimal database migration for the source database version - i.e. for version >= 11.2.0.3 this is Full Transportable Database, for version >= 10.1.0.3 and < 11.2.0.3 this is Transportable Tablespace. The important difference is that Transportable Database migrates both DATA and METADATA in a single invocation of the datapump utility, whereas Transportable Tablespace is a more complex process that requires 3 separate datapump runs. N.b. the 10.1.0.3 limitation applies only to cross-platform migrations; where source and targets are endianness compatible even version 8 can be migrated using TTS.


# AUTOMIGRATE SCRIPTS
The migration scripts are included in "autoMigrate.zip" within this repository.

Scripts "src_migr.sql" and "pck_migration_src.sql" should be extracted to a suitable filesystem on the source server, e.g. "/tmp".

Scripts "tgt_migr.sql" and "pck_migration_tgt.sql" should be extracted to a suitable filesystem on the target server, e.g. "/tmp".


## START MIGRATION  

Logon to source server as "oracle" software owner or any account belonging to the "dba" group.

Source the database to be migrated before running the migration script. 

For all examples in this project we are migrating a database with SID "AIXDB" on AIX server to LINUX:
              
```
export ORACLE_SID=AIXDB
export ORAENV_ASK=NO
. oraenv
```

Run the migration script "src_migr.sql" in "analyze" mode to generate a screen report with relevant details of the database to be migrated. 

```
sqlplus / as sysdba @src_migr.sql mode=ANALYZE
```

Run the migration script in "execute" mode to prepare the database for migration.

```
sqlplus / as sysdba @src_migr.sql mode=EXECUTE
```

After a short period (depends on size of database) the script will generate on screen details of how to complete the migration on the target LINUX server.

## COMPLETE MIGRATION

Logon to target server as "oracle" software owner or any account belonging to the "dba" OS group.

Source the pre-created target CDB. For example, assume that CDB called CDBDEV has been created:

```
export ORACLE_SID=CDBDEV
export ORAENV_ASK=NO
. oraenv
```

Run the "tgt_migr.sql" script as indicated in the output from running "src_migr.sql" on the source server:

```
sqlplus / as sysdba @tgt_migr.sql \
    HOST=10.1.23.124 \     # IP address of AIX source server 
    SERVICE=WMLDEV \       # listening service name on AIX server. Usually same as SID name
    PDBNAME=WMLDEV \       # name of target PDB to be created. Should default this to the SID of AIX source database
    PW=FLIUTjkXX!          # password of MIGRATION schema on source database that was created by running "src_migr.sql"
```

The migration is started in the background and can be monitored either by viewing contents of log file "/tmp/migration.log" (default location) or by running this query in a tool like "sqlplus" or "sqlDeveloper":

```
ALTER SESSION SET CONTAINER=WMLDEV;
SELECT * FROM migration.log ORDER BY id;
```


## SCRIPT COMMAND PARAMETERS   

Parameters in *`italics`* are optional.

### src_migr.sql

`MODE=[ANALYZE|EXECUTE|INCR-TS|INCR-TS-FINAL|RESET|REMOVE]`
- `ANALYZE` - show details about the database - e.g. name and size of database (DEFAULT)
  
- `EXECUTE` - prepares database for direct migration - i.e. sets all application tablespaces to read only

- `INCR` - starts migration by taking incremental backups in a background job. Tablespaces remain online
  
- `RESET` - sets tablespaces back to their pre-migration status

- `REMOVE` - remove all database objects and any backups created for the migration
                           
*`BKPDIR`*
>directory to store file image copies and incremental backups - mandatory parameter if `MODE=INCR`
  
*`BKPFREQ`*
>frequency for taking incremental backups - default is on the hour every hour - only relevant for `MODE=INCR-TS` Same syntax as used for dbms_scheduler repeat_interval, e.g. *`BKPFREQ='freq=daily; byhour=6; byminute=0; bysecond=0;'`* is every day at 6AM.

*`USER`*
>Name of transfer user. Default is MIGRATION. Ony change this if "MIGRATION" happens to exist pre-migration.

### tgt_migr.sql

`USER`   
>Name of source database user referenced in database link. Default is MIGRATION.

`HOST`
>IP Address of the server hosting the source database.

`SERVICE`
>Name of the source database's listening service running in the source environment.

`PORT`
>Port on which service is registered with the listener. Default is 1521.

`PDBNAME`
>Name of the Pluggable database (PDB) to be created in the CDB. 

*`OPTIONS=[TTS,NOSTATS]`*
- *`NOSTATS`* - Does **not** gather statistics after migration. 
- *`TTS`* - forces migration by TRANSPORTABLE TABLESPACE. *** FOR TESTING ONLY ***

*`MODE=[REMOVE]`*
- *`REMOVE`* - drops the PDB identified by PDBNAME parameter. Use this prior to a complete database refresh for example.

# APPENDIX

## REFERENCES

https://www.oracle.com/a/tech/docs/twp-upgrade-oracle-database-19c.pdf

https://www.oracle.com/technetwork/database/features/availability/maa-wp-11g-upgradetts-132620.pdf
