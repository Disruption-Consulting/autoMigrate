BASICS
------
A DB LINK is a database object that enables a session in one database to access tables, views and run procedures in another database. Oracle refers to this as distributed processing. For example, a session in the Database called DATAMART retrieves rows from the customer table in the SALES database by running "SELECT * FROM CLIENT.customer@SALES_LINK". The following configuration exists in order for this to work:

1. A user is defined in the SALES database that acts as a conduit for access to the "CLIENT.customer" table, e.g.

```
export ORACLE_SID=SALES

sqlplus /nolog<<EOF
CONNECT /AS SYSDBA

Rem --------------
Rem Best practices
Rem --------------
Rem Create user with least privileges to provide required access.
Rem CREATE SESSION required is required because access via DB LINK results in this user starting a database session
Rem

CREATE USER dblink_user IDENTIFIED BY "Password12!";
GRANT CREATE SESSION TO dblink_user;
GRANT SELECT ON CLIENT.customer TO dblink_user;
EOF
```

2. A DB LINK called "SALES_LINK" is created in the DATAMART database 

```
export ORACLE_SID=DATAMART

sqlplus /nolog<<EOF
CONNECT /AS SYSDBA

Rem --------------
Rem Best practices
Rem --------------
Rem The following is a "private fixed user" DB LINK, which include the authentication details of the remote database user.
Rem
Rem The USING clause refers to a TNS alias entry in the DATAMART's tnsnames.ora network configuration file. 
Rem CREATE PUBLIC DATABASE LINK is strongly ill-advised - it provides access to ALL database users.

ALTER SESSION SET CURRENT_SCHEMA=sales_schema;
CREATE DATABASE LINK SALES_LINK CONNECT TO dblink_user IDENTIFIED BY "Password12!" USING 'SALES_DATA_SERVICE';


EOF
```

3. An entry in DATAMART's "tnsnames.ora" network file includes an identically named tns alias entry "SALES_DATA_SERVICE", e.g.

```
# Best Practice
# -------------
# Note the use of a generic name describing the service, rather than the database name - this greatly simplifies  
# code deployments in environments where the database naming standards includes a string denoting Test / UAT / Production.

SALES_DATA_SERVICE=(
  DESCRIPTION=
  (ADDRESS_LIST=(ADDRESS=(PROTOCOL=tcp)(HOST=10.1.25.21)(PORT=1521)))
	(CONNECT_DATA=(SERVER=DEDICATED)(SERVICE_NAME=SALES)))
```

While DATAPUMP migrates DB LINK definitions, it does not confirm that they are actually used. Auditing sessions in the database enables us to monitor all  connections and thereby identify DB LINK usage. Ideally, *ALL* databases in the landscape should be audited for incoming connections as a minimum. 

remains  an Oracle database application makes use of DB LINKS to access data in another database specific actions may be required to maintain application functionality  after the migration. In particular, where all databases are being migrated to a new platform (e.g. AIX to LINUX) and there is no bi-directional network support, migrating AIX database A that uses a db link to AIX database B will necessitate migrating both A and B to the target LINUX platform at the same time.

ANALYZE DB LINK USAGE
---------------------
If a database has implemented AUDIT SESSION, monitoring DB LINK usage is as simple as

```
CONNECT /AS SYSDBA
set linesize 1000                
column userid format a15
column ntimestamp# format a30
column comment$text format a200

select userid, ntimestamp#, comment$text from sys.aud$ where action=100 and comment$text like '%DBLINK%';


```
