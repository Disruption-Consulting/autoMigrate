# BACKGROUND

Since version 12.2, a CDB database created with AL32UTF8 character (default) set may now comprise PDBs with different character sets.

However, we cannot directly migrate a non-AL32UTF8 database into a pluggable database within an AL32UTF8 CDB; we have to first migrate to an interim CDB with the same character set and then relocate the PDB to the target AL32UTF8 CDB.


# PROCESS

To follow the procedure, assume:

- the end target database is an AL32UTF8 CDB, called CDBAL32
- a temporary CDB with character set WE8ISO8859P9 has been created, called CDBWEP9
- the source WE8ISO8859P9 database has been migrated to CDBWEP9 as a PDB called PDBWEP9

```sql
export ORACLE_SID=CDBWEP9
export ORAENV_ASK=NO
. oraenv
sqlplus / as sysdba<<EOF
CREATE USER C##CLONE_USER IDENTIFIED BY clone_user;
GRANT CREATE SESSION TO C##CLONE_USER;
ALTER SESSION SET CONTAINER=PDBWEP9;
GRANT SYSOPER TO C##CLONE_USER;
EXIT
EOF
```

On the target CDBAL32 we need to now create a database link to C##CLONE_USER on CDBWEP9 and relocate the migrated PDB:

```sql
export ORACLE_SID=CDBAL32
export ORAENV_ASK=NO
. oraenv
sqlplus / as sysdba<<EOF
CREATE DATABASE LINK CLONE_LINK CONNECT TO C##CLONE_USER IDENTIFIED BY clone_user USING '//localhost/CDBWEP9';
CREATE PLUGGABLE DATABASE PDBWEP9 FROM PDBWEP9@CLONE_LINK RELOCATE FILE_NAME_CONVERT=('CDBWEP9','CDBAL32');
EXIT
EOF
```

At the end of this exercise, the AL32UTF8 CDB called CDBAL32 wil contain the WE8ISO8859P9 PDB called PDBWEP9.

Keep all non-AL32UTF8 CDBs created for this purpose until the end of the migration project and then delete them.

There should be no space issue since RELOCATE physically moves the PDB data files. 
