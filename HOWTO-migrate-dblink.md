ANALYZE DB LINK USAGE
---------------------
runMigration.sh on the SOURCE database lists all DB LINKs together with an indication of whether each link is functional.

In the first instance, this should be discussed with the Application owner to confirm whether listed DB LINKs are required. We cannot assume that a functioning DB LINK is actually required by the Application; I've seen many cases where functioning DB LINKs have been created, found to be no longer required but not dropped. In other cases, DB LINKs are redefined at run-time according to some dynamic routing requirement. 

The use of DB LINKs generally complicates database migration planning since it implies one or more of the following:
1. Do we need to migrate the database which is the object of the DB LINK as a pre-requisite to migrating the original database?
2. Do we migrate only the original database but configure our network and tnsnames to point to the object of the DB LINK until that is migrated?
3. What about other applications that access the migrated database by DB LINK? Will these need to be reconfigured / recreated?

Until recently and not surprisingly, Oracle infrastructure service providers insisted on **ZERO** use of DB LINKs.

DB LINKs, however, have proven to be very useful and many organizations' I.T. business operations depend on functioning DB LINKs. So how do we migrate them? 

Full Database migration using Datapump will migrate all DB LINK definitions. Running the migrated application, however, will most likely fail unless the routing for the DB LINK is functional (see notes below for basic understanding of how DB LINKs work). 

Routing is defined in the USING clause of the CREATE DATABASE LINK command which will look similar to one of the following:

CREATE DATABASE LINK dblink CONNECT TO remote-user IDENTIFIED BY password USING 'tns-alias';

CREATE DATABASE LINK dblink CONNECT TO remote-user IDENTIFIED BY password USING 'hostname:port/service';

CREATE DATABASE LINK dblink CONNECT TO remote-user IDENTIFIED BY password USING '(DESCRIPTION=(ADDRESS=(PROTOCOL=TCP)(HOST=hostname)(PORT=port))(CONNECT_DATA=(SERVICE_NAME=service)))';

If using tns-name then we have to ensure that the entry has been migrated from the source database's tnsnames.ora file; we then need to test that the link is functional from the new target database.

In the other 2 cases, routing is hard-coded in the definition itself; tnsnames.ora is not relevant but the links will only work if SQLNET network connectivity from the new target server is enabled. 

In order to enhance understanding of actual DB LINK usage, it helps enourmously if the effected databases have implemented AUDIT SESSION, since monitoring DB LINK usage is as simple as issuing the following query. All Oracle databases should AUDIT SESSION as an absolute minimum.

```
CONNECT /AS SYSDBA
set linesize 1000                
column userid format a15
column ntimestamp# format a30
column comment$text format a200

select userid, ntimestamp#, comment$text from sys.aud$ where action=100 and comment$text like '%DBLINK%';
```

DB LINK BASICS
--------------
A DB LINK is a database object that enables a session in one database to access tables, views and run procedures in another database. Oracle refers to this as distributed processing. 

For example, a session in the Database called DMPROD retrieves rows from the customer table in the SLSPROD database by running "SELECT * FROM SALES.CUSTOMER@SALES_LINK". The following configuration exists in order for this to work:

1. A user is defined in the SLSPROD database that acts as a conduit for access to the "SALES.CUSTOMER" table, e.g.

```
export ORACLE_SID=SLSPROD

sqlplus /nolog<<EOF
CONNECT /AS SYSDBA

Rem --------------
Rem Best practices
Rem --------------
Rem Create user with least privileges to provide required access.
Rem CREATE SESSION privilege is required because access via DB LINK results in this user starting a database session
Rem

CREATE USER dblink_user IDENTIFIED BY "Password12!";
GRANT CREATE SESSION TO dblink_user;
GRANT SELECT ON CLIENT.customer TO dblink_user;
EOF
```

2. A DB LINK called "SALES_LINK" is created in the DMPROD database 

```
export ORACLE_SID=DMPROD

sqlplus /nolog<<EOF
CONNECT USER/PASSWORD

Rem --------------
Rem Best practices
Rem --------------
Rem The following is a "private fixed user" DB LINK, which includes the authentication details of the remote database user.
Rem Note that we connected USER/PASSWORD. You cannot create database links in other schemas from a privileged user unless you obtain that schema's
Rem password, temporarily reset it, connect and create the db link, and finally reset the password to its original value. One of the best accounts of
Rem how this is done is "http://www.peasland.net/2016/02/18/oracle-12c-identified-by-values"
Rem
Rem The USING clause refers to a TNS alias entry in DMPROD's tnsnames.ora network configuration file. Note that he TNS entry or
Rem EZ Naming syntax can also be employed as in the equivalent USING '//10.1.25.21/SLSPROD' - however, as explained below, this is
Rem not advised as it will cause unnecessary additional effort when deploying to other environments - e.g. from SLSTEST to SLSPROD.
Rem
Rem Note that CREATE PUBLIC DATABASE LINK is strongly ill-advised as it enables ALL database users to access.
Rem
Rem When issuing a DML statement that references a DB LINK, Oracle checks whether the name of the DB LINK starts with the remote GLOBAL NAME of the database.
Rem If the remote database has set the initialization parameter GLOBAL_NAMES=TRUE, which is Oracle's recommendation, then the DB LINK must at least include the remote database's global name. 


CREATE DATABASE LINK SALES_LINK CONNECT TO dblink_user IDENTIFIED BY "Password12!" USING 'SALES_DATA_SERVICE';
EOF
```

3. An entry in DMPROD's "tnsnames.ora" network configuration file includes an identically named tns alias entry 
"SALES_DATA_SERVICE", e.g.

```
# Best Practice
# -------------
# Note the use of a generic name describing the service, rather than the database name - this greatly simplifies  
# code deployments in organizations where database naming standards requires denoting the environment (e.g. D, T, P)

SALES_DATA_SERVICE=(
  DESCRIPTION=
  (ADDRESS_LIST=(ADDRESS=(PROTOCOL=tcp)(HOST=10.1.25.21)(PORT=1521)))
	(CONNECT_DATA=(SERVER=DEDICATED)(SERVICE_NAME=SLSPROD)))
```
Test connectivity using the "tnsping" utlility:
```
$ tnsping SALES_DATA_SERVICE
TNS Ping Utility for Linux: Version 11.2.0.4.0 - Production on 24-AUG-2020 13:53:27

Copyright (c) 1997, 2016, Oracle.  All rights reserved.

Used parameter files:


Used TNSNAMES adapter to resolve the alias
Attempting to contact ( DESCRIPTION=( ADDRESS_LIST= (ADDRESS= (PROTOCOL = tcp) (HOST = 10.1.25.21) ( PORT=1521))) (CONNECT_DATA= (SERVER=DEDICATED)(SERVICE_NAME=SLSPROD)))
OK (0 msec)
```
