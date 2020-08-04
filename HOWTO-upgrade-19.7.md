BACKGROUND
----------
V19 is the current terminal release of Oracle Database, providing Premier support until April 2024 and extended support until April 2027. 

See "My Oracle Support" (MOS) Doc ID 742060.1 for the most up-to-date release information.

PROCESS OVERVIEW
----------------
1. Download Oracle v19 software from MOS
2. Create new v19 home directory and unzip download
3. Download latest OPatch utility and replace in v19 home
4. Download 19.7 patchset and install (this is the latest patchset issued April 2020)
5. Create a CDB using the new home and back it up

The above steps represent about 6 hours work if you get it all right and there are no network availability issues.

1. Download software packages from MOS
--------------------------------------
You will need to download from MOS the following 3 files into your install directory (assume "/tmp"):

a) LINUX.X64_193000_db_home.zip - https://www.oracle.com/database/technologies/oracle-database-software-downloads.html#19c

b) p6880880_190000_Linux-x86-64.zip - https://support.oracle.com

c) p30869156_190000_Linux-x86-64.zip - https://support.oracle.com

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

After some minutes the software will be installed. You should then log on as root and run 

```
/u01/app/oracle/product/19.0.0/dbhome_1/root.sh
```


3. Replace OPatch 
-----------------
Set ORACLE_HOME to the new home directory and set PATH to include OPatch directory before replacing OPatch.

```
export ORACLE_HOME=/u01/app/oracle/product/19.0.0/dbhome_1
export PATH=$ORACLE_HOME/bin:$ORACLE_HOME/OPatch:$PATH

cd $ORACLE_HOME
mv OPatch OPatch_old
unzip /tmp/p6880880_190000_Linux-x86-64.zip
opatch version
```
Version should return "OPatch Version: 12.2.0.1.19"

4. Upgrade to v19.7
-------------------
```
cd /tmp
unzip p30869156_190000_Linux-x86-64.zip
cd /tmp/30869156
opatch apply
```

Answer "yes" when prompted and wait until returns "OPatch succeeded".


5. Preserve the 19.7 home for future deployments
------------------------------------------------
```
cd /u01/app/oracle/product/19.0.0
zip /tmp/ora197home.zip dbhome_1
```

6. Create v19.7 Database
------------------------
```
dbca -silent -createDatabase \
-templateName General_Purpose.dbc \
-gdbname CDB19 \
-sid CDB19 \
-responseFile NO_VALUE \
-characterSet AL32UTF8 \
-sysPassword Dogface34 \
-systemPassword Dogface34 \
-createAsContainerDatabase true \
-databaseType MULTIPURPOSE \
-totalMemory 1500 \
-automaticMemoryManagement false \
-datafileDestination '/u02/oradata' \
-redoLogFileSize 50 \
-emConfiguration NONE \
-ignorePreReqs
```

Check upgrade worked:


```
cat /etc/oratab. # should see your database here listed with correct home

export ORACLE_SID=CDB19
sqlplus / as sysdba
SELECT * FROM V$VERSION;
exit
```

The above should confirm that this indeed is a v19.7 database.


Note on Switching homes (LINUX)
-------------------------------
Easily accessing multiple Oracle databases built from different homes on the same server can be achieved by configuring functions in the "oracle" account's ".bash_profile" file.

For example, if you have used the "dbac" utility to create a v18 database CDB18 and a v19 database CDB19, then the following functions in ".bash_profile" allow easy acesss to both:

```
CDB19 () { ORACLE_SID=CDB19; ORAENV_ASK=NO; . oraenv; ORAENV_ASK=YES; }
CDB18 () { ORACLE_SID=CDB18; ORAENV_ASK=NO; . oraenv; ORAENV_ASK=YES; }
```
"dbac" on LINUX updates the /etc/oratab startup file which is used by the ".oraenv" script to set ORACLE_HOME, ORACLE_SID and PATH.

Enter "ORA19" and you're all set for database CDB19; enter "CDB18" and you're all set for database CDB18.
