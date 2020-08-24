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
Rem CREATE SESSION privilege is required because access via DB LINK results in this user starting a database session
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
Rem The following is a "private fixed user" DB LINK, which includes the authentication details of the remote database user.
Rem
Rem The USING clause refers to a TNS alias entry in the DATAMART's tnsnames.ora network configuration file. Note that he TNS entry or
Rem EZ Naming syntax can also be employed as in the equivalent USING '//10.1.25.21/SALES' - however, as explained below, this is
Rem not advised as it will cause unnecessary additional effort when deploying to other environments.
Rem
Rem Note that CREATE PUBLIC DATABASE LINK is strongly ill-advised as it enables access to ALL database users.
Rem
Rem When issuing a DML statement that references a DB LINK, Oracle checks whether the name of the DB LINK starts with the remote GLOBAL NAME of the database.
Rem If the remote database has set the initialization parameter GLOBAL_NAMES=TRUE, which is Oracle's recommendation, then the DB LINK must at least include the remote database's global name. 

ALTER SESSION SET CURRENT_SCHEMA=sales_schema;
CREATE DATABASE LINK SALES_LINK CONNECT TO dblink_user IDENTIFIED BY "Password12!" USING 'SALES_DATA_SERVICE';
EOF
```

3. An entry in DATAMART's "tnsnames.ora" network configuration file includes an identically named tns alias entry 
"SALES_DATA_SERVICE", e.g.

```
# Best Practice
# -------------
# Note the use of a generic name describing the service, rather than the database name - this greatly simplifies  
# code deployments in organizations where database naming standards requires denoting the environment (e.g. D, T, P)

SALES_DATA_SERVICE=(
  DESCRIPTION=
  (ADDRESS_LIST=(ADDRESS=(PROTOCOL=tcp)(HOST=10.1.25.21)(PORT=1521)))
	(CONNECT_DATA=(SERVER=DEDICATED)(SERVICE_NAME=SALES)))
```
Test connectivity using the "tnsping" utlility:
```
$ tnsping SALES_DATA_SERVICE
```


ANALYZE DB LINK USAGE
---------------------
As noted above, use of a DB LINK in a SELECT statement (or indeed, any authorized DML statement) starts a database session in the remote database.

If a database has implemented AUDIT SESSION, monitoring DB LINK usage is as simple as

```
CONNECT /AS SYSDBA
set linesize 1000                
column userid format a15
column ntimestamp# format a30
column comment$text format a200

select userid, ntimestamp#, comment$text from sys.aud$ where action=100 and comment$text like '%DBLINK%';


```
