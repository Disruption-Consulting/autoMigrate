# BACKGROUND

Since version 12.2, a CDB database created with AL32UTF8 character (default) set may now comprise PDBs with different character sets.

To follow the procedure, assume following:
- the end target database is an AL32UTF8 CDB, called CDBAL32
- a temporary CDB with character set WE8ISO8859P9 has been created, called CDBWEP9
- the source WE8ISO8859P9 database has been migrated to CDBWEP9 as a PDB called PDBWEP9

On CDBWEP9

1. Create a common user in CDBWE9, C##CLONE_USER, with CREATE SESSION privilege

4. Set current container to the migrated PDB and grant SYSOPER privilege

5. On target AL32UTF8 CDB, create database link to C##CLONE_USER

6. CREATE PLUGGABLE DATABASE 
