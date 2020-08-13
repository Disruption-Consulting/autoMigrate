# automigrate
Automate migration of non-CDB Oracle databases to Multitenant (CDB/PDB) architecture.
- Tested on source database versions 10.1, 10.2, 11.2, 12.1, 12.2, 18.3
- Tested on target database versions 19.7, 19.8 

OVERVIEW
--------
Migrating to a new version of Oracle database is invariably a costly and inherently disruptive affair, which most organizations avoid for as long as possible. However, at the time of writing (July 2020) there are a number of factors that now make it incumbent on Oracle customers to migrate to the current terminal release - version 19:
- Oracle no longer supports the non-Multitenant architecture, i.e. non-CDB, as of version 20
- Oracle offers 3 PDBs per CDB license-free
- version 19 has the longest support timeframe (until 2027)
- through sharing infrastructure resources, adoption of Multitenant significantly lowers total cost of ownership
- version 19 enables limited use of features like in-Memory at no extra license cost

Essentially, all pre-19 databases need to be migrated before falling out of support, as shown below from the Oracle support site -

![MRUpdatedReleaseRoadmap5282020](https://user-images.githubusercontent.com/42802860/90099785-2e6a2400-dd33-11ea-826f-661b58bf3d0b.png)



The "autoMigrate" utility was developed to reduce the complexity and large number of manual tasks involved in database migration. These include, but are by no means limited to:

- transporting business data from source to target, ensuring the process is restartable in the event of network failure
- ensuring endianess compatibility of source and transported data
- copying metadata definitions from source to target 
- reconciling counts of the transferred data and metadata
- gathering accurate statistics of transferred data objects
- confirming use of any DIRECTORY objects in source that may need to be redefined in target
- confirming use of any DATABASE LINK objects that may need to be redefined in target
- ensuring all grants to SYS-owned objects are replayed in the target database
- ensure target tablespaces are set to their pre-migration status on the source database

Even for a simple database the above can represent many dozens of individual tasks that need to be prepared, coordinated and tested. 

Based on the Transportable Tablespace feature, available starting version 10.1.0.3, the autoMigrate utility reduces database migration to at most 3 steps:
1. run sqlplus script on the source database, optionally signalling the start of a protracted data migration process
2. run sqlplus script on the target database
3. if step 1 started a data migration process then run the same script on the source database to signal end of the process

A "protracted data migration process" allows data to be migrated within a timeframe that supports availability requirements of the application. Alternatively, and by default, source data files are set to read only and therefore unavailable to the application until the migration is complete. 

For example, migrating a 10TB database over an effective network bandwith of 100GB/hour would take at least 100 elapsed hours during which the application would by default be unavailable. To mitigate such cases, the autoMigrate utility allows the application to remain fully online whilst it takes incremental data file backups which are  transfered and applied automatically to the target database; in this way, very large, active databases can be transfered over say, a week before a final incremental backup taken say, on the weekend is applied and used to complete the migration which could complete within an hour (depending on the degree of source database udate activity).
