# automigrate
Utility to consistently migrate NON-CDB Oracle databases to PDB with minimal cost and delay.

- uses features only included in the basic Enterprise Edition software license
- reduces application downtime to a minimum
- source database versions >  10.1.0.2
- target database versions >= 19.9

Oracle's Multitenant architecture improves use of resources by consolidating multiple application databases (PDB) within a single Container Database (CDB). The literature refers to the pre-Multitenant database as a NON-CDB, in which a set of application tablespaces is typically managed through a single dedicated instance and related background processes. By contrast, a CDB can "contain" up to 252 independent sets of application tablespaces (PDBs) which it manages through a single instance and set of background processes. In this way, migrating to Multitenant can potentially transform an I.T. organisation's costs and improve efficiency by an order of magnitude. Up to 3 PDBs per version 19 CDB is cost-free - otherwise the full Multitenant option is 3850 USD / year / Processor.


# OVERVIEW

Upgrading to a new Oracle database version can incur significant cost and disruption, which is why many organizations avoid it for as long as possible. However, at the time of writing (2020) there are several factors that make it increasingly incumbent on Oracle customers to migrate now:

- version 19 offers Premier and Extended support until April 2024 and April 2027 respectively
- all earlier version databases are fast reaching end-of-life incurring significant extra support costs
- NON-CDB is no longer available as of version 20 having been deprecated since release 12.1
- each version 19 CDB may now comprise 3 PDBs at no additional cost
- version 19 enables limited cost-free use of features like in-Memory which can drastically improve query performance

Many organizations that have moved from NON-CDB to CDB have seen massive benefits - e.g. Swiss insurance company Mobiliar runs over 700 PDBs consolidated within 5 CDBs which it is able to upgrade over a weekend. However, a change of this magnitude is widely considered to be a complex, costly undertaking that incurs considerable risk and disruption. 

The aim of the "autoMigrate" utility is to simplify the migration effort by providing an adaptable framework that automates the many tasks involved in database migration and thereby mimimize the overall cost and delay. Failure to migrate always leads to increasing costs and eventually to a situation where support includes neither security patches nor bug fixes. For example, Premier support for 12.1.0.2 ended in June 2018 at which point extending support would have cost a further 10% the following year and a further 20% until June 2022 when this version will fall into Sustaining support - i.e. running without security patches and without error correction whilst still incurring an additional 4% annual support increase.


![MRUpdatedReleaseRoadmap5282020](https://user-images.githubusercontent.com/42802860/90099785-2e6a2400-dd33-11ea-826f-661b58bf3d0b.png)

# FINANCIAL MOTIVATION

By way of example, the support costs over the next 10 years of running Oracle Enterprise Edition together with the Partitioning, OLAP, Diagnostic and Tuning Packs on a modest 24-core (Intel) server can be summarized as (all figures in USD, no discount applied):

|<br>`Release Date:`|19C<br>`Apr 2019`|18C<br>`Jul 2018`|12.1.0.2<br>`Jun 2013`|11.2.0.4<br>`Sep 2009`|10.2.0.5<br>`Jul 2005`|
|:---:|:--:|:--:|:--:|:--:|:--:|
|2020|256K|264K|322K|373K|439K|
|2021|266K|274K|335K|388K|457K|
|2022|277K|285K|348K|403K|475K|
|2023|288K|297K|362K|420K|494K|
|2024|300K|309K|377K|436K|514K|
|2025|312K|321K|392K|454K|534K|
|2026|324K|334K|407K|472K|556K|
|2027|337K|347K|424K|491K|578K|
|2028|351K|361K|441K|510K|601K|
|2029|365K|375K|458K|531K|625K|
|2030|379K|390K|477K|552K|650K|
|TOTAL PERIOD:|3454K|3557K|4342K|5030K|5923K|

The steady annual increase results from Oracle's indexation rule whereby all licensed products are subject to a year-on-year 4% increase; remaining on version 12.1.0.2, for example, would see annual support costs climbing from 322K to 477K over the next 10 years. Premier support for 12.1.0.2, however, ended in 2018, after which it fell into Sustaining support unless the client agreed to pay a fixed penalty over typically a 3 year period to extend Premier support. What the figures do not show is that Sustaining support does **NOT** include new security patches or bug fixes; your databases would effectively be running unprotected from any new security breaches.

By upgrading to 19C, however, you would have access to the full range of cover provided by Premier support until the end of 2024 for a total support cost that is 26% less than if you remained on 12.1.0.2 for the same period. So why would you **NOT** upgrade if it costs 26% **LESS** to have your databases fully protected on fully-supported software?

Full details of what is included in the various support levels are published at https://www.oracle.com/us/assets/lifetime-support-technology-069183.pdf


In addition to reducing support costs, upgrading to 19C provides an opportunity to signicantly reduce infrastructure costs. It is certainly possible, with good planning, to obtain the same or even greater overall performance on much reduced infrastructure since the Multitenant architecture is predicated on sharing computer resources. As commercial software moves increasingly to a core-based cost model it becomes ever more important to run applications on right-sized infrastructure.

# AUTOMIGATE UTILITY

To help migrate from NON-CDB to PDB, the "autoMigrate" utility provides an adaptable framework for coordinating the large number of tasks involved and reducing the exercise to a minimum of interventions. Organizations running hundreds of databases would spend far too much, take far too long and incur considerable risk by using a manual step-by-step migration approach. "autoMigrate" is a shell script called "runMigration.sh" and supporting PLSQL that is run once on each of the source and target databases; it determines the optimal migration method based on source database version and automatically executes the required data transfer, metadata integration and post-migration tasks.

Of course, no single solution can cover every migration situation. What do you do if your organization uses Apex, for example? Answer: perform a separate export of Apex workspaces/applications for importing into the target PDB where Apex is pre-configured. Or what do you do if your applications are distributed (i.e. use database links)? Answer: plan the order in which the involved databases are migrated. Adopting a scripted approach, however, ensures each migration is carried out consistently with a minimum of intervention and a maximum of control. 

There are 3 principal methods for migrating NON-CDB to PDB: 1) Golden Gate, 2) Clone/Upgrade/Convert and 3) Datapump 

1) Golden Gate is a separately licensed option (3850 USD/Processor/Year) which is complex to configure but enables near zero down-time migration; to minimise cost of ownership and maintain simplicity we do not consider this technique as part of a generic, least-cost migration solution. Moreover, autoMigrate includes a mode of operation for minimizing downtime using functionality that is already part of the basic software license, which will provide in most cases an acceptable solution.

2) Clone/Upgrade/Convert is only relevant since version 12.1 and only works where the target and source databases share the same endianness; moreover, in cases where migration implies a software upgrade, e.g. migrating 12.1.0.2 to 19C, the source dictionary once cloned has to be upgraded which takes at least 20 minutes on the fastest platforms, before being converted into a PDB which can take at least another 10 minutes assuming there are no errors. 

3) Migration by Datapump requires that the target PDB is pre-created which takes only a few seconds to complete, eliminating the long elapsed times required for upgrade and conversion in method 2). It works on all source versions since 10.1.0.2, automatically handles cross-endianness migration and offers a fully integrated mechanism for minimizing application downtime. A common complaint against use of Datapump is that it involves many manual tasks, which is true and was the main motivation behind automating those tasks within a single script. Hence, we only need to run runMigration.sh once on the source and once on the target to complete a migration.

"runMigration.sh" does the following:

- prepares the source database for migration, checking application tablespace integrity before setting these read only
- prepares the source database for taking incremental backups if requested
- creates common user in the target CDB database with least privileges to perform all migration tasks
- restartable data transport to avoid re-work in the event of network or systems failure
- ensures any endianess conversion is done automatically by using the dbms_file_transfer utility
- creates the Pluggable Database 
- integrates all application metadata into the target by using the Full Transportable Database option of Datapump
- automatically uses the Transportable Tablespace option if source database version < 11.2.0.3
- reconciles both transferred data and metadata object counts
- gathers statistics of the migrated database including dictionary and fixed objects
- migrates any version 11 Access Control Entries 
- confirms use of any DIRECTORY objects in source that need to be present in target
- confirms use of any DATABASE LINK objects that may need to be configured for use in target
- grants on any SYS-owned source objects to application schemas/users are replayed in the target database
- ensures application tablespaces are set to their pre-migration status on completion in both source and target databases

A recent migration of a 500GB database running on 11.2.0.4 on AIX over a network supporting 100 GB/hour bandwidth to a target 19C PDB database running on Red Hat Enterprise Linux involved:

|APPLICATION AVAILABLE|ELAPSED TIME|SOURCE DATABASE|TARGET DATABASE|
|:---:|--|--|--|
|:white_check_mark:||**START MIGRATION**||
|:no_entry:|1 minute|`./runMigration`||
|:no_entry:|||`./runMigration`|
|:no_entry:|1 minute||**CREATE PDB**|
|:no_entry:|5 hours||**TRANSFER DATA**|
|:no_entry:|10 minutes||**RUN DATAPUMP**|
|:no_entry:|TOTAL **5 hours 12 minutes**|||
|:white_check_mark:|||**MIGRATION COMPLETE**|

In this case, the client's business could afford the approximate 5 hours application downtime, which starts unavoidably as soon as the source database application tablespaces are set to read only. In cases where the database is critical to business operations, a much shorter period of downtime will be required. For this reason, autoMigrate allows the application to remain fully available whilst regular incremental backups are taken and applied to the target database rolling it forward to near-synchronicity with the source database. The same 500GB database could have been migrated using this method as follows:


|APPLICATION AVAILABLE|ELAPSED TIME|SOURCE DATABASE|TARGET DATABASE|
|:---:|--|--|--|
|:white_check_mark:||**START MIGRATION**||
|:white_check_mark:||`./runMigration -i`||
|:white_check_mark:||**BACKUP LVL=0**|`./runMigration`|
|:white_check_mark:|||**CREATE PDB**|
|:white_check_mark:|||**TRANSFER LVL=0**|
|:white_check_mark:||**BACKUP LVL=1** :repeat:|**TRANSFER LVL=1 & ROLL FORWARD** :repeat:|
|:white_check_mark:|TOTAL: **24 hours**|||
|:no_entry:||`./runMigration -m EXECUTE`||
|:no_entry:|1 minute|**BACKUP LVL=1 FINAL**||
|:no_entry:|1 minute||**TRANSFER LVL=1 & ROLL FORWARD FINAL**|
|:no_entry:|10 mins||**RUN DATAPUMP**|
|:no_entry:|TOTAL: **12 minutes**|||
|:white_check_mark:|||**MIGRATION COMPLETE**|


In this way, near-synchronous copies of the source application data files are maintained on the target database until the business decides to complete the migration by running `./runMigration -m EXECUTE` at which point the application tablespaces are set read only before a final incremental backup is taken and applied. From there the migration proceeds in exactly the same way resulting in only 12 minutes application downtime.   
 

# AUTOMIGRATE SCRIPTS
The migration scripts are included in "autoMigrate.zip" available in this repository and include:

## runMigration.sh

- Bash shell script that runs on both both SOURCE and TARGET database servers. 
- Determines at run time whether it processes a SOURCE or TARGET database based on the CDB value in V$DATABASE - if YES then TARGET else SOURCE
- Creates external password wallet store to securely maintain all Oracle account passwords used in the migration
- Creates schema "MIGRATION19" if running on SOURCE to act as object of Database Link that is subsequently created on TARGET
- Creates common user "C##MIGRATION" if running on TARGET
- Creates PDB from PDB$SEED when running on TARGET


## pck_migration_src.sql

- PLSQL Package that is compiled on SOURCE server within schema "MIGRATION19"
- Entry points in this package are called by runMigration.sh to:
  - report on database properties that are relevant to the migration
  - execute the migration by setting application tablespaces to read only
  - prepare database for taking incremental backups if requested


## pck_migration_cdb.sql

PLSQL Package that is compiled on TARGET server within common user "C##MIGRATION"
Entry points in this package are called by runMigration.sh to:
  - manage the data file transfer process from SOURCE to TARGET destination directory
  - recognize when all application tablespaces have been set read only to trigger datapump phase
  - automatically apply incremental backup pieces to local level 0 file copies

4. pck_migration_pdb.sql
------------------------
PLSQL Package that is compiled on TARGET server within the "PDBADMIN" schema that is created with the PDB
Entry points in this package are called by runMigration.sh to:
  - generate appropriate parfiles for operation of impdp (Datapump)
  - run post-datapump fixup tasks, e.g. gather database statistics, apply grants to SYS-owned objects


## SAMPLE MIGRATION

### SOURCE

Logon to SOURCE as oracle software owner or member of "dba" group, copy autoMigrate.zip to /tmp

```
mkdir /tmp/migrate

cd /tmp/migrate

unzip /tmp/autoMigrate.zip

# identify database to be migrated
export ORACLE_SID=DB1
. oraenv

# review details of the database including version, characterset, size of application tablespaces
./runMigration.sh

# prepare database for migration and display command to be run on TARGET
./runMigration -m EXECUTE
```

### TARGET

Logon to TARGET as oracle software owner or member of "dba" group, copy autoMigrate.zip to /tmp

```
mkdir /tmp/migrate

cd /tmp/migrate

unzip /tmp/autoMigrate.zip

# run command generated by runMigration.sh on SOURCE, e.g.
./runMigration.sh -c MIGRATION19/'"DiHX9B7#qm"' -t 172.17.0.3:1521/DB121 -p PDB1  

```

### Logging

runMigration.sh produces always at least one log file in the installation directory for activities perfromed on the $ORACLE_SID

After running on a SOURCE database called for example DB1, a single log file named runMigration.DB1.log is created.

After running on a TARGET database called for example CDB1 where the pdb that is being migrated is called PDB1, 2 log files are created:
  - runMigration.CDB1.log
  - runMigration.PDB1.log

In addition, logs are maintained in the "migration_log" table that is held in the following schemas:
  - MIGRATION19
  - C##MIGRATION
  - PDBADMIN
  
To simplify management of parallel migrations, the "migration_log" table in C##MIGRATION maintains a summary of progress at PDB level.

Datapump is only run **AFTER** all data files have been copied. To review progress of data file transfers, particularly of large databases, run the following query:

```
SELECT * FROM C##MIGRATION.migration_log WHERE pdb_name='PDBNAME' ORDER BY id;
```

For a more detailed progress report that shows all files and their current transfer status, run this query:

```
SELECT * FROM c##migration.migration_ts WHERE pdb_name='PDBNAME';
```


## REFERENCES 

Oracle Product Manager for upgrades / migration maintains a comprehensive blog at https://mikedietrichde.com

Oracle Global Pricing (September 2020) https://www.oracle.com/assets/technology-price-list-070617.pdf
