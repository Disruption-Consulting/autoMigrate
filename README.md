# automigrate
Utility to consistently migrate NON-CDB Oracle databases to PDB at minimal cost and delay.

- uses features only included in the basic Enterprise Edition software license
- reduces application downtime to a minimum
- source database versions 10.1, 10.2, 11.2, 12.1, 12.2, 18.3 (NON-CDB)
- target database versions 19.3 through 19.8 (CDB)

Oracle's Multitenant architecture improves use of resources by consolidating multiple application databases (PDB) within a single Container Database (CDB). A single SGA and set of background processes for the CDB are shared by up to 252 PDBs, which can have a transformative effect on an organization's I.T. spend whilst greatly improving its business responsiveness.

# OVERVIEW

Migrating or even upgrading Oracle database can incur significant cost and disruption, which is why many organizations avoid it for as long as possible. However, at the time of writing (2020) there are several factors that make it increasingly incumbent on Oracle customers to migrate now:

- version 19 offers Premier and Extended support until April 2024 and April 2027 respectively
- all earlier version databases are fast reaching end-of-life incurring significant extra support costs
- NON-CDB is deprecated as of version 20
- each version 19 CDB may now comprise 3 PDBs at no additional cost
- version 19 enables limited cost-free use of features like in-Memory which can drastically improve query performance

Many organizations that have moved from NON-CDB to CDB have seen massive benefits - e.g. Swiss insurance company Mobiliar runs over 700 PDBs consolidated within 5 CDBs which it is able to upgrade over a weekend. However, many more Oracle customers are facing something of a rush to get their database farms upgraded before it's too late (see diagram below). 


![MRUpdatedReleaseRoadmap5282020](https://user-images.githubusercontent.com/42802860/90099785-2e6a2400-dd33-11ea-826f-661b58bf3d0b.png)

For example, if your organization runs its Oracle version 12.1.0.2 databases with the OLAP, Partitioning and Diagnostics Pack on infrastructure powered by say, 100 CPU cores (Intel) then its annual support costs are:

|<br>GA|19C<br>2019|18C<br>2018|12.1.0.2|11.2.0.4|10.2.0.5|
|:---:|:--:|:--:|:--:|:--:|:--:|
|2020|256K|264K|383K|434K|439K|
|2021|266K|274K|396K|449K|457K|
|2022|277K|285K|384K|464K|475K|
|2023|288K|297K|362K|425K|494K|
|2024|319K|309K|377K|436K|514K|
|2025|360K|321K|392K|454K|534K|
|2026|382K|334K|407K|472K|556K|
|2027|357K|347K|424K|491K|578K|
|2028|351K|361K|441K|510K|601K|
|2029|365K|375K|458K|531K|625K|
|2030|379K|390K|477K|552K|650K|
|TOTAL PERIOD:|3600K|3557K|4499K|5217K|5923K|


Beyond , there is very often a strong business motivation to change infrastructure at the same time, for example, moving from on-premise to cloud, or moving from AIX to LINUX, or outsourcing or simply upgrading the on-premise hardware. This then becomes a "migration" project rather than an "upgrade" in place, since the business data must be physically moved. 

The "autoMigrate" utility provides an adaptable framework for coordinating the large number of tasks involved in such projects. These include:

- data transport that is restartable in the event of network or systems failure
- ensuring endianess compatibility of source and target data
- copying metadata definitions from source to target 
- reconciling transferred data and metadata
- gathering accurate statistics of transferred data objects
- confirming use of any DIRECTORY objects in source that may need to be reconfigured in target
- confirming use of any DATABASE LINK objects that may need to be configured for use in target
- ensuring grants of any SYS-owned source objects to application schemas are replayed in the target database
- ensuring tablespaces are set to their pre-migration status on completion

One of the most challenging aspects of database migration is keeping application downtime to a minimum. For example, assuming an effective network bandwith of 100 GB/hour, migrating a 1 TB database of medium complexity might take 10 hours to migrate the data with 1 additional hour to integrate the metadata using Oracle's Datapump utility. Oracle's response to this is either use its separately licensed Golden Gate option or wrestle with its approximate 7000 line Perl script which requires maintaining configuration files on both source and target servers.

|APPLICATION AVAILABLE|ELAPSED TIME|SOURCE DATABASE|TARGET DATABASE|
|:---:|--|--|--|
|:white_check_mark:||**START MIGRATION**||
|:no_entry:|5 mins|`./runMigration -m EXECUTE`||
|:no_entry:|||`./runMigration -c CRED -t TNS -p PDB`|
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
|:white_check_mark:||`./runMigration -m INCR`||
|:white_check_mark:||**BACKUP LVL=0**|`sqlplus @tgt_migr`|
|:white_check_mark:||**BACKUP LVL=1**|**CREATE PDB**|
|:white_check_mark:||**BACKUP LVL=1**|**TRANSFER LVL=0**|
|:white_check_mark:||**BACKUP LVL=1**|**TRANSFER LVL=1 & ROLL FORWARD**|
|:white_check_mark:||:repeat:|:repeat:|
|:white_check_mark:|TOTAL: **13 hours**|||
|:no_entry:||`./runMigration -m EXECUTE`||
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

Run the migration script in "ANALYZE" mode to report on relevant migration details, e.g. database size, version, server platform.

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


## REFERENCES 

Oracle Product Manager for upgrades / migration maintains a comprehensive blog at https://mikedietrichde.com

Oracle Global Pricing (September 2020) https://www.oracle.com/assets/technology-price-list-070617.pdf
