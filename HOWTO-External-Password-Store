BACKGROUND
----------
This HOWTO explains how to configure and use the Oracle External Password store, which enables password-less connections to Oracle programs like sqlplus and expdp/impdp. In earlier versions (pre 10), the ability to run scripts without passwords was achieved by External Oracle accounts whereby an OS system account would be defined in the Oracle database as "IDENTIFIED EXTERNALLY"; in this way, the OS user would logon to their password-protected host operating system account and then connect to their corresponding Oracle account by entering "sqlplus /". 

With the External Password Store, credentials of Oracle accounts are maintained in an Oracle wallet enabling user access through "sqlplus /@TNSNAME" where TNSNAME is an entry in the current tnsnames.ora file. In this way, the overhead and risk of maintaining host operating system accounts is removed. 

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

ORACLE_SID=${1}                      # Establish ORACLE_SID of the object Oracle database (will be the CDB if running multitenant)
ORAENV_ASK=NO                        # Call the Oracle-supplied oraenv script to source the environment for ORACLE_SID without prompts
. oraenv                             # Sets ORACLE_HOME and PATH from details held in /etc/oratab for the ORACLE_SID

export TNS_ADMIN=/tmp                # Set TNS_ADMIN to point to directory /tmp
sqlplus user/password@alias<<EOF     # Routing information for "alias" retrieved from /tmp/tnsnames.ora
  exec schema.procedure
EOF

exit
```

By configuring an External Password store in /tmp we can avoid hard-coding user passwords in scripts when TNS_ADMIN points to the drectory containing a valid wallet and supporting network configuration files.


1. Create Oracle Wallet
-----------------------



2. Add credentials to the Wallet
--------------------------------

3. Add entry to tnsnames.ora 
----------------------------


4. Configure sqlnet.ora
-----------------------
