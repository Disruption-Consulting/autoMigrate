BACKGROUND
----------
Where an Oracle database application makes use of DB LINKS to access data in another database specific actions may be required to maintain application functionality  after the migration. In particular, where all databases are being migrated to a new platform (e.g. AIX to LINUX) and there is no bi-directional network support, migrating AIX database A that uses a db link to AIX database B will necessitate migrating both A and B to the target LINUX platform at the same time.

PROCESS OVERVIEW
----------------
1. Download Oracle v19 software from MOS
2. Create new v19 home directory and unzip download
3. Download latest OPatch utility and replace in v19 home
4. Download 19.8 patchset and install (this is the latest patchset issued July 2020)
5. Create a v19.8 Container Database (CDB) with "dbca" from the new Oracle home


1. Download software packages from MOS
--------------------------------------
You will need to download from MOS the following 3 files into your install directory (assume "/tmp") for your environment (assume "Linux x86_64"):

a) LINUX.X64_193000_db_home.zip - https://www.oracle.com/database/technologies/oracle-database-software-downloads.html#19c

b) Opatch utility - 6880880 - https://support.oracle.com

c) Release Update - 31281355 - https://support.oracle.com

You also need an install response file (e.g. "db_install.rsp" in this Git repository)


2. Create v19 home directory
----------------------------
Logon or sudo as "oracle" software owner. Shutdown any running instance(s).

Edit as necessary the installation response file in /tmp/db_install.rsp

```
sqlplus / as sysdba<<EOF
shutdown immediate
EOF

lsnrctl stop

unset ORACLE_HOME
unset ORACLE_BASE
unset ORACLE_SID
unset TNS_ADMIN

mkdir -p /u01/app/oracle/product/19.0.0/dbhome_1

cd /u01/app/oracle/product/19.0.0/dbhome_1

unzip -q /tmp/LINUX.X64_193000_db_home.zip

./runInstaller -ignorePrereq -waitforcompletion -silent -responseFile /tmp/db_install.rsp
```
