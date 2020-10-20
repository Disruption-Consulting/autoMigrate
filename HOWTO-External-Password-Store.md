BACKGROUND
----------
The Oracle External Password store enables password-less connections to Oracle programs like sqlplus and expdp/impdp. In earlier versions (pre 10), the ability to run scripts without passwords was achieved by External Oracle accounts whereby an OS system account would be defined in the Oracle database as "IDENTIFIED EXTERNALLY"; in this way, the OS user would logon to their password-protected host operating system account and then connect to their corresponding Oracle account by entering "sqlplus /". 

With the External Password Store, credentials of Oracle accounts are maintained in an Oracle wallet enabling user access through "sqlplus /@TNSNAME" where TNSNAME is an entry in the current tnsnames.ora file. In this way, the overhead and risk of maintaining host operating system accounts is removed, whilst enabling much greater flexibility and range of access.

The use of External Password Store is the recommended mechanism for securely managing user access to Oracle accounts.


PROCESS OVERVIEW
----------------
1. Create Oracle Wallet
2. Add credentials to the Wallet
3. Add entry to tnsnames.ora 
4. Configure sqlnet.ora


Understanding TNS_ADMIN
-----------------------
By default, an Oracle database's network configuration files (tnsnames.ora and sqlnet.ora) are stored in the directory $ORACLE_HOME/network/admin

When a user enters "sqlplus user/password@TNSNAME", routing information for TNSNAME is obtained from $ORACLE_HOME/network/admin/tnsnames.ora *UNLESS* the user has overridden the network directory location by setting the variable TNS_ADMIN.

For example, a script may set TNS_ADMIN to a specified directory before running sqlplus. In this case, the TNSNAME will be resolved from the file tnsnames.ora stored in that directory:

```
#!/bin/bash

ORACLE_SID=${1}                          # Establish ORACLE_SID of the object Oracle database (will be the CDB if running multitenant)
ORAENV_ASK=NO                            # Call the Oracle-supplied oraenv script to source the environment for ORACLE_SID without prompts
. oraenv                                 # Sets ORACLE_HOME and PATH from details held in /etc/oratab for the ORACLE_SID

export TNS_ADMIN=/tmp                    # Set TNS_ADMIN to point to directory /tmp
sqlplus TESTUSER/Dogface34@DB1<<EOF      # Routing information for "DB1" retrieved from /tmp/tnsnames.ora. The password is hard-coded.
  exec schema.procedure
EOF

exit
```

By configuring an External Password store in /tmp we can avoid hard-coding user passwords by pointing TNS_ADMIN to the drectory containing network configuration files supporting wallet-protected tns aliases....


1. Create Oracle Wallet
-----------------------
```
cd /tmp
mkstore -wrl wallet

# mkstore prompts twice for a wallet password and creates directory /tmp/wallet
```

2. Add credentials to the Wallet
--------------------------------
```
# create credential named DB1_TESTUSER for Oracle user account TESTUSER with password "AvP2t23#Z+"

mkstore -wrl wallet -createCredential DB1_TESTUSER  TESTUSER  "AvP2t23#Z+"

# mkstore prompts once for the wallet password entered twice in the previous step
# note use of double quotes surrounding the password enables any printable character to be used enhancing security
```

3. Add entry to tnsnames.ora 
----------------------------
```
# add entry for alias DB1_TESTUSER to /tmp/tnsnames.ora

cat >>/tmp/tnsnames.ora<<EOF
DB1_TESTUSER=(DESCRIPTION=(ADDRESS=(PROTOCOL=TCP)(HOST=10.1.25.10)(PORT=1521))(CONNECT_DATA=(SERVER=DEDICATED)(SERVICE_NAME=DB1)))
EOF
```

4. Configure sqlnet.ora
-----------------------
```
# sqlnet.ora includes location of wallet plus directive allowing use of password-less connections. Here, we've configured the wallet in the same
# directory as the network files but this is not mandatory. The DIRECTORY clause in WALLET_LOCATION indicates where the wallet is stored.

cat >/tmp/sqlnet.ora<<EOF
WALLET_LOCATION = (SOURCE = (METHOD = FILE)(METHOD_DATA =(DIRECTORY = /tmp/wallet)))
SQLNET.WALLET_OVERRIDE = TRUE
EOF


# At this point if we try to run sqlplus and connect as user TESTUSER it will fail

sqlplus /@DB1_TESTUSER

ERROR:
ORA-12154: TNS:could not resolve the connect identifier specified

# Let's set TNS_ADMIN to the location of our wallet and local network configuration files and retry

export TNS_ADMIN=/tmp

sqlplus /@DB1_TESTUSER

SQL*Plus: Release 19.0.0.0.0 - Production on Wed Oct 14 11:47:50 2020
Version 19.8.0.0.0

Copyright (c) 1982, 2020, Oracle.  All rights reserved.

Last Successful login time: Tue Oct 13 2020 13:50:43 +00:00

Connected to:
Oracle Database 19c Enterprise Edition Release 19.0.0.0.0 - Production
Version 19.8.0.0.0

SQL> show user
USER is "TESTUSER"

```

The original script that included a hard-coded password can now be re-written as:


```
#!/bin/bash

ORACLE_SID=${1}                      # Establish ORACLE_SID of the object Oracle database (will be the CDB if running multitenant)
ORAENV_ASK=NO                        # Call the Oracle-supplied oraenv script to source the environment for ORACLE_SID without prompts
. oraenv                             # Sets ORACLE_HOME and PATH from details held in /etc/oratab for the ORACLE_SID

export TNS_ADMIN=/tmp                # Set TNS_ADMIN to point to directory /tmp
sqlplus /@DB1_TESTUSER<<EOF          # Routing information retrieved from /tmp/tnsnames.ora. Password obtained from wallet.
  exec schema.procedure
EOF

exit
```

CONSOLIDATING ACCOUNTS
----------------------
The External password store is used throughout the runMigration.sh script in order to minimize use of external access implicitly through the "oracle" software account owner (i.e. sqlplus / as sysdba)

In order to avoid changing a running Production environment, the wallet is created and maintained in the current directory at the time runMigration.sh is run - e.g. /tmp

However, in a new target environment it would be recommended to maintain a single wallet and set of configuration files in $ORACLE_HOME/network/admin in order to avoid hard-coding passwords in connection requests by default, either through scripts or online.
