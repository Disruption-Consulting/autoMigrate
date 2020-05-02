
|SOURCE DATABASE|TARGET DATABASE|
|--|--|
|aix_migr MODE=EXECUTE||
|*start downtime*|| 
||rhel_migr|
|| **transfer**|
|| **datapump**|
||MIGRATION COMPLETE|


Where business needs demand that application downtime be minimized, then the following alternative migration steps can be followed:

|SOURCE DATABASE|TARGET DATABASE|
|--|--|
|aix_migr MODE=INCR-TS||
|*available*|| 
||rhel_migr|
|| **transfer**|
|aix_migr MODE=INCR-TS-FINAL||
|*start downtime*||
||**final transfer**|
||*datapump*|
| aix_migr MODE=RESET||
| *end downtime*||

INSTALLATION
------------
The installation comprises only one script file, "rhel_migr.sql". 

Logon (or sudo) to "oracle" software owner, although any account that belongs to "dba" group and has sysdba
privilege can run this script.

Place the script on a suitable filesystem - it only generates a few bytes of informational output.


RUN COMMAND                         
-----------
              
```
sqlplus / as sysdba @rhel_migr.sql \
    USER=SNFTRANSFER \
    HOST=xxxxxxxxxxx \
    SERVICE=ssssssss \
    PDBNAME=pppppppp 
```


                         
PARAMETERS (7):
---------------           
(1)           
USER   
  Default is "SNFTRANSFER" - this is the user created on source database that we use to create a global database link
  through which we access data and metadata on the source database.

(2)
HOST
  Name of the server hosting the source database.

(3)
SERVICE
  Name of the service running on the source database that is registered with the local listener. We use these first 3 
  items to create the database link.

(4)
PDBNAME
  Name of the Pluggable database (PDB) to be created in the current CDB. Will normally be the name of the source database.

(5)
START=PDB
  Start the process by creating a new PDB (DEFAULT)

START=TRANSFER 
  Start the process by transferring data files from the source database. Once complete will run the datapump migration.

(6)
MIGRATE=CONV-DB
  Forces migration by FULL import - i.e. logical data export/import instead of file transfer.
  Originally intended as a solution for changing characterset to AL32UTF8 (the default for CDB). 
  NB: Since 12.2 PDBs of any characterset can be plugged into an AL32UTF8 CDB.
  
MIGRATE=XTTS-TS
  Forces migration by TRANSPORTABLE TABLESPACE - only for me to test as I don't have Oracle 10 (or 11 for that matter).

(7)
ACTION=FORCE-STOP
  Forces a running MIGRATION_JOB to be stopped before relaunching. E.g. for use when previous transfer run interrupted by network failure

ACTION=DEL-UNPLUG
  If deleting PDB on a re-run, will delete any tablespace data files that have been transferred but not plugged in


OPERATING NOTES
---------------
Once the source database has been prepared (aix_migr.sql), running this script on the destination server (e.g. RHEL) will migrate the source database into a new PDB named according to the PDBNAME script parameter.

The other script parameters (USER, HOST, SERVICE) are used to create a DATABASE LINK within the PDB that connects to the source database. This DB LINK is central to the migration and performs the following major tasks:

1) transfer application tablespace data files from the source database
2) integrate these into the PDB along with application metadata.

The integration step uses the DATAPUMP transportable tablespace feature, hence all application tablespaces must be set to READ ONLY on the source database prior to the migration. This is done using the "aix_migr.sql" script either by running that script with MODE=EXECUTE or MODE=INCR-TS. Note that this effects only HOW the data is transferred.

For example, if the source database is relatively small and the business can tolerate a proportionally small period of application downtime, then the following steps will work:








