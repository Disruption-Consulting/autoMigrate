BACKGROUND
----------
V19 is the current terminal release of Oracle Dataase, providing patching support until 2026. 

V18, by comparison, is an interim release which ends patching support in 2021.

See MOS Doc ID 742060.1 for the most up-to-date release information.

PROCESS OVERVIEW
----------------
1. Download Oracle v19 software from My Oracle Support (MOS)
2. Create new v19 home directory and unzip download
3. Download latest OPatch utility and replace in v19 home
4. Download 19.7 patchset and install (this is the latest patchset issued April 2020)
5. Create a zip of the 19.7 home for re-deployment on other VMs / servers.
6. Create a CDB using the new home and back it up

In order to minimize the overall effort involved, it is strongly advised that once the upgrade has been completed and tested on one VM, that a zip is created for direct deployment when upgrading other VMs. The above steps represent about 6 hours work if you get it right and there are no network availability issues; by creating a zip of the tested home, future upgrades are reduced to a 5 minute unzip operation.

1. Download software packages from MOS
--------------------------------------
You will need to download from MOS the following 3 files into your install directory (assume /tmp):

a) LINUX.X64_193000_db_home.zip - https://www.oracle.com/database/technologies/oracle-database-software-downloads.html#19c

b) p6880880_190000_Linux-x86-64.zip - https://support.oracle.com

c) p30869156_190000_Linux-x86-64.zip - https://support.oracle.com

You also need a starter install response file (db_install.rsp available in this Git repository)


2. Create v19 home directory
----------------------------
Logon or sudo to target VM as "oracle" software owner. Assume existing v18 home.

Edit as necessary the installation response file in /tmp/db_install.rsp

```
unset ORACLE_HOME
unset ORACLE_BASE
unset ORACLE_SID
unset TNS_ADMIN

mkdir -p /u01/app/oracle/product/19.0.0/dbhome_1

cd /u01/app/oracle/product/19.0.0/dbhome_1

unzip -q /tmp/LINUX.X64_193000_db_home.zip

./runInstaller -ignorePrereq -waitforcompletion -silent -responseFile /tmp/db_install.rsp
```

3. Replace OPatch 
-----------------



