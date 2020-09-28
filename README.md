# automigrate
Utility to consistently migrate legacy NON-CDB Oracle databases to PDB at minimal cost and delay.

- uses functionality exclusively included in the basic software license
- reduces application downtime to a minimum
- tested on source database versions 10.1, 10.2, 11.2, 12.1, 12.2, 18.3 (NON-CDB)
- tested on target database versions 19.3 through 19.8 (CDB)

Oracle's Multitenant architecture improves use of resources by consolidating multiple application databases (PDB) within a single Container Database (CDB). A single SGA and set of background processes for the CDB are shared by all of its PDBs. 

# OVERVIEW

Migrating or even upgrading Oracle database can incur significant cost and disruption, which is why many organizations avoid it for as long as possible. However, at the time of writing (2020) there are several factors that make it increasingly incumbent on Oracle customers to migrate now:

- version 19 has the longest support timeframe
- legacy databases are fast reaching end-of-life incurring extra support costs
- NON-CDB is deprecated as of version 20
- each version 19 CDB may comprise 3 PDBs at no additional cost
- adoption of CDB can significantly lower the cost of ownership
- version 19 enables limited cost-free use of features like in-Memory which can drastically improve performance

Many organizations that have moved from NON-CDB to CDB have seen massive benefits - e.g. Swiss insurance company Mobiliar runs 735 PDBs consolidated within 5 CDBs. In addition, test and development databases which are mostly unused can now be consolidated into a single CDB and hosted on cheap infrastructure, considerably reducing software licensing costs. CDB also enables database self-provisioning, drastically reducing project timescales; likewise, creating database copies for tests is now a 5 minute PDB clone operation. Being able to backup and upgrade a single CDB infers saving the cost of duplicating these costly tasks for each of the contained PDBs.  The same Mobiliar company managed to upgrade all of its 735 PDBs from version 12.2 to 19 over a single weekend, an impossible undertaking for 735 NON-CDBs.


![MRUpdatedReleaseRoadmap5282020](https://user-images.githubusercontent.com/42802860/90099785-2e6a2400-dd33-11ea-826f-661b58bf3d0b.png)


The "autoMigrate" utility provides a framework for coordinating the large number of tasks involved in database migration, including:

- transporting application data from source to target as an easily restartable process in the event of network or systems failure
- ensuring endianess compatibility of source and target data
- copying metadata definitions from source to target 
- reconciling transferred data and metadata
- gathering accurate statistics of transferred data objects
- confirming use of any DIRECTORY objects in source that may need to be redefined in target
- confirming use of any DATABASE LINK objects that may need to be configured for use in target
- ensuring grants of SYS-owned source objects to application schemas are replayed in the target database
- ensuring tablespaces are set to their pre-migration status on completion

A key advantage of autoMigrate is fully integrated functionality to migrate large volumes of data with minimal application downtime. For example, assuming an effective network bandwith of 100 GB/hour, migrating a 1 TB database of medium complexity might take 10 hours to migrate the data with 1 additional hour to integrate the metadata using Oracle's Datapump utility.

|APPLICATION AVAILABLE|ELAPSED TIME|SOURCE DATABASE|TARGET DATABASE|
|:---:|--|--|--|
|:white_check_mark:||**START MIGRATION**||
|:no_entry:|5 mins|`sqlplus @src_migr mode=EXECUTE`||
|:no_entry:|||`sqlplus @tgt_migr`|
|:no_entry:|5 mins||**CREATE PDB**|
|:no_entry:|11 hours||**TRANSFER DATA**|
|:no_entry:|50 mins||**RUN DATAPUMP**|
|:no_entry:|TOTAL **12 hours**|||
|:white_check_mark:|||**MIGRATION COMPLETE**|

Migration involves first running the provided "src_migr" script on the NON-CDB source database; `mode=EXECUTE` sets all application tablespaces to read only which takes at most a few minutes depending on how many 'dirtied' blocks need to be written from the buffer cache and how many application tablespaces are involved. The provided "tgt_migr" script is then run on the target database which:
1) creates a PDB to receive the NON-CDB
2) transfers the read only data files from the NON-CDB to the PDB
3) runs DATATPUMP to plug the data files into the PDB and integrate application objects like Users, PLSQL, Views, Sequences etc.

The application is effectively unavailable until the migration completes. Depending on the business criticality of the application, 11 hours downtime, as in this example, may be acceptable. In many other cases, however, a much shorter period of downtime will be necessary. For this reason, autoMigrate allows the application to remain fully available whilst regular incremental data file backups are taken and applied to the target database rolling it forward to near-synchronicity with the source database.


|APPLICATION AVAILABLE|ELAPSED TIME|SOURCE DATABASE|TARGET DATABASE|
|:---:|--|--|--|
|:white_check_mark:||**START MIGRATION**||
|:white_check_mark:||`sqlplus @src_migr mode=INCR`||
|:white_check_mark:||**BACKUP LVL=0**|`sqlplus @tgt_migr`|
|:white_check_mark:||**BACKUP LVL=1**|**CREATE PDB**|
|:white_check_mark:||**BACKUP LVL=1**|**TRANSFER LVL=0**|
|:white_check_mark:||**BACKUP LVL=1**|**TRANSFER LVL=1 & ROLL FORWARD**|
|:white_check_mark:||:repeat:|:repeat:|
|:white_check_mark:|TOTAL: **13 hours**|||
|:no_entry:||`sqlplus @src_migr mode=EXECUTE`||
|:no_entry:|5 mins|**BACKUP LVL=1**||
|:no_entry:|5 mins||**TRANSFER LVL=1 & ROLL FORWARD**|
|:no_entry:|50 mins||**RUN DATAPUMP**|
|:no_entry:|TOTAL: **1 hour**|||
|:white_check_mark:|||**MIGRATION COMPLETE**|

Migration by this method requires starting with `sqlplus @src_migr mode=INCR`, which creates a background job running at user-defined intervals creating at first file image copies (Level=0 incremental backup) of each application tablespace data file. Once this is started, `sqlplus @tgt_migr` on the target automatically recognises that the source is creating backups and creates a background job runnning at the same frquency to transfer these to the destination PDB file system. Once file image backup copies have been taken, the source database job starts taking Level=1 incremental backups of any changes since the last backup which the target database job uses to roll forward its local file image copies. 

In this way, near-synchronous copies of the source application data files are maintained on the target database until the business decides to complete the migration by running `sqlplus @src_migr mode=EXECUTE`; from that point forward the migration proceeds in identical fashion since the only criterion for starting the DATAPUMP integration job is that all data files are read only. In this example, the same volume of data is migrated with 1 hour of application downtime compared to 12 hours. 

autoMigrate runs the optimal database migration for the source database version - i.e. for version >= 11.2.0.3 this is Full Transportable Database, for version >= 10.1.0.3 and < 11.2.0.3 this is Transportable Tablespace. The important difference is that Transportable Database migrates both Data and Metadata in a single invocation of the datapump utility, whereas Transportable Tablespace (TTS)is a more complex process requiring 3 separate datapump runs - Users/Data/Metadata.

N.b. the 10.1.0.3 limitation applies only to cross-platform migrations. Where source and targets have the same endianness, even a version 8 database can be migrated using TTS.
 

# AUTOMIGRATE SCRIPTS
The migration scripts are included in "autoMigrate.zip" within this repository.

The same script "runMigration.sh" runs on both both SOURCE and TARGET database servers. 

When it runs on database server where ORACLE_SID points to version 19 then it processes as a TARGET database; otherwise it processes as a SOURCE database.

## START MIGRATION ON SOURCE

Logon to SOURCE server as "oracle" software owner or any account belonging to the "dba" group.

Source the database to be migrated before running the migration script (i.e. ORACLE_HOME and ORACLE_SID)

Run the migration script in "ANALYZE" mode to prepare the database for migration.

```
./runMigration.sh -m ANALYZE
```

- installs the migration schema (default name is MIGRATION19)
- analyzes the subject database reporting on details relevant to the migration

```
./runMigration.sh -m EXECUTE
```

- sets all application tablespaces to read only
- display the command to run on the TARGET server which will complete the migration


## COMPLETE MIGRATION ON TARGET

Logon to target server as "oracle" software owner or any account belonging to the "dba" OS group.

Source the pre-created target CDB, i.e. setting ORACLE_HOME and ORACLE_SID.

Copy/paste the command displayed after running the script on the SOURCE server, e.g.

```
./runMigration.sh -c MIGRATION19/'"hmN_a1a0~Y"' -t 172.17.0.3:1521/orcl -p PDB1
```

- creates the target PDB 
- creates PDBADMIN schema within PDB 
- creates dblink using above details within the PDB
- transfers data files from SOURCE to TARGET
- runs DATAPUMP to integrate the data files, copy metadata and perform post-migration tasks.
