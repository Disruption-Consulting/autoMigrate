# automigrate
Two scripts developed to reduce the effort and cost to migrate Oracle databases to the current terminal version 19 release.

- no use of extra-cost options, like Goldengate and Active Data Guard
- tested on source database versions 10.1, 10.2, 11.2, 12.1, 12.2, 18.3
- tested on target database versions 19.3 through 19.8 


# OVERVIEW

Migrating or even upgrading Oracle database can incur significant cost and disruption, which is why many organizations avoid it for as long as possible. However, at the time of writing (July 2020) there are several factors that now make it incumbent on Oracle customers to migrate to version 19:

- starting with version 20 non-CDB will no longer be supported by Oracle
- you can now run 3 PDBs per CDB license-free
- version 19 has the longest support timeframe (see diagram below from the Oracle Support site)
- adoption of Multitenant architecture significantly lowers the total cost of ownership
- version 19 enables limited but cost-free use of features like in-Memory which can drastically reduce elapsed times of some queries
- some variants of Unix (e.g. Solaris, HPUX) are exiting the market as adoption of Linux and Cloud infrastructure continues to gather momentum

![MRUpdatedReleaseRoadmap5282020](https://user-images.githubusercontent.com/42802860/90099785-2e6a2400-dd33-11ea-826f-661b58bf3d0b.png)


The "autoMigrate" utility was developed to provide a repeatable, coherent framework for executing the large number of tasks involved in database migration, including:

- transporting application data from source to target as an easily restartable process in the event of network failure for example
- ensuring endianess compatibility of source and transported data
- copying metadata definitions from source to target 
- reconciling counts of the transferred data and metadata
- gathering accurate statistics of transferred data objects
- confirming use of any DIRECTORY objects in source that may need to be redefined in target
- confirming use of any DATABASE LINK objects that may need to be configured for use in target
- ensuring grants of SYS-owned source objects to application schemas are replayed in the target database
- ensuring tablespaces are set to their pre-migration status on completion

Let's assume the following:
- migrating 1TB 11.2.0.4 database named AIXDB to 19.8 Pluggable database named LINUXDB
- effective network bandwith is 100GB/hour



|APPLICATION AVAILABLE|ELAPSED TIME|SOURCE DATABASE|TARGET DATABASE|
|:---:|--|--|--|
|:white_check_mark:|5 mins|`sqlplus / @src_migr`||
|:no_entry:|5 mins|`sqlplus / @tgt_migr`|
|:no_entry:|10 hours||**TRANFER APPLICATION DATA**|
|:no_entry:|30 mins||**TRANSFER METADATA**|
|:no_entry:|30 mins|**POST-MIGRATION TASKS**|
|:white_check_mark:|TOTAL 11 hours 10 minutes|MIGRATION COMPLETE||


An "extended data migration process" is a phased transfer to the target server during which the source database remains fully available; the default process sets all application tablespaces to read only before starting the transfer.

For example, migrating a 10TB database over an effective network bandwith of 100GB/hour would take at least 100 elapsed hours during which the application would by default be unavailable. To mitigate such cases, the autoMigrate utility allows the application to remain fully online whilst it takes incremental data file backups which are  transfered and applied automatically to the target database; in this way, very large, active databases can be transfered over say, a week before a final incremental backup taken say, on the weekend is applied and used to complete the migration which could complete within an hour (depending on the degree of source database udate activity).

Based on the Transportable Tablespace feature, autoMigrate runs the optimal database migration for the source database version - i.e. for version >= 11.2.0.3 this is Full Transportable Database, for version >= 10.1.0.3 and < 11.2.0.3 this is Transportable Tablespace. The important difference is that Transportable Database migrates both DATA and METADATA whereas Transportable Tablespace only migrates DATA; however, the autoMigrate scripts automatically make that determination and proceed accordingly.

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

- `INCR-TS` - starts migration by taking incremental backups in a background job. Tablespaces remain online
                     
- `INCR-TS-FINAL` - sets all tablespaces to read only before taking a final incremental backup
  
- `RESET` - sets tablespaces back to their pre-migration status

- `REMOVE` - remove all database objects and any backups created for the migration
                           
*`INCR-TS-DIR`*
>directory to store file image copies and incremental backups - mandatory parameter if `MODE=INCR-TS`
  
*`INCR-TS-FREQ`*
>frequency for taking incremental backups - default is on the hour every hour - only relevant for `MODE=INCR-TS` Same syntax as used for dbms_scheduler repeat_interval, e.g. *`INCR-TS-FREQ='freq=daily; byhour=6; byminute=0; bysecond=0;'`* is every day at 6AM.

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
  
*`TMPDIR`*
>Directory where generated script and log files are created. Default is `/tmp`

*`OVERRIDE=[CONV-DB|XTTS-TS]`*
- *`CONV-DB`* - forces migration by FULL logical export/import. 
- *`XTTS-TS`* - forces migration by TRANSPORTABLE TABLESPACE. *** FOR TESTING ONLY ***

*`MODE=[REMOVE]`*
- *`REMOVE`* - drops the PDB identified by PDBNAME parameter. Use this prior to a complete database refresh for example.

# APPENDIX

## REFERENCES

https://www.oracle.com/a/tech/docs/twp-upgrade-oracle-database-19c.pdf
