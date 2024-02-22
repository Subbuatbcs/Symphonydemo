#! /bin/bash
# version 04
# parameterization of this script: use parameter --config-file or enter a valid file name
# in line 267
# Documentation see SAP Note 1651055
# Change with respect to version 02: the query to find "obsolete" log files also takes care
# of the backup catalog files, see SAP Notes https://service.sap.com/sap/support/notes/1812980 and 
# https://service.sap.com/sap/support/notes/1852242
# Change with respect to version 03: 
# - adapted change in hdbsql syntax that prevented correct log backup listing
# - introduced delete from backup catalog via BACKUP CATALOG DELETE
# - introduced logging of inifile customizing (record all changed DB parameters)
# - clean-up of temp files
# - introduced several acknowledgements to reminde people that this script is demo, not SAP software.

USAGE()
{
  cat << EOF

Usage: 
  ${0} -h                  --> print this help screen
  ${0}                     --> run backup with backup 
                                      file for current day of week
                                      [-> same as option -w]
  ${0} --config-file       --> pass system-specific configuration via cfg file

  ======== Backup mode: automatic file names of user-defined names ============
  ${0} -w                  --> run backup with backup file for 
                                      current day of week (explicitly)
                                      [-> backup overwritten every seven days]
  ${0} -o                  --> run backup with backup file for parity of
                                      day of year (ODD / EVEN)
                                      [-> backup overwritten every other day]
  ${0} --suffix=<SUFFIX>   --> run backup into files with
                                      given suffix.
  ${0} --retention=<#days> --> run backup into file with running number, overwriting
                                      every <#days> days.

  ======== Further Options ====================================================
  ${0} -d                  --> Only create backup of data files
  ${0} -c                  --> Only create backup of configuration files
  ${0} -t                  --> test mode: only text output, no backup
  ${0} -q                  --> suppress display of splash screen
  ${0} -p                  --> Print script parameterization into log file
                                      (only for backup creation, not for log mgmt)

  ======== Housekeeping Options ===============================================
  ${0} -ld                 --> list data backups
  ${0} -ll                 --> list log backup files that are older than a given 
                                      data backup ID.
                                      (requires option --backup-id)
  ${0} -cd                 --> delete all log backups from disk and catalog
                                      that are older than either --backup-id or
                                      than the oldest existing data backup (option -od)
  ${0} -cl                 --> only list backups that still exist (clean list)
  ${0} -od                 --> for listing log backups: use backup ID of oldest
                                      data backup (oldest existing data backup
                                      if option -cl or cd is given).
  ${0} --backup-id=<ID>    --> specify data backup ID for option -ll or -cd
  ${0} --output-file=<file> --> write output lists of -ld or -ll to <file>

  Note: Options -c and -d cannot be combined.
        Options -w, -d and --suffix= cannot be combined.
        Options -ll, -cd, and -ld cannot be combined
        


EOF
}



# Do not change these 14 variables!
# They must all be set to FALSE for correct
# command line option handling.
TESTMODE=FALSE
QUIETMODE=FALSE
DATA_BACKUP_ONLY=FALSE
CONFIG_BACKUP_ONLY=FALSE
PRINT_PARAMETERIZATION=FALSE
SUFFIX_MODE=INITIAL
LIST_DATA_BACKUPS=FALSE
LIST_LOG_BACKUPS=FALSE
USE_OLDEST_BACKUP=FALSE
CATALOG_DELETE=FALSE
DATA_BACKUP_ID=""
CLEAN_BACKUP_LIST=FALSE
LIST_OUTPUT_FILE=""
CFG_FILENAME=""
declare -i ERROR_CODE=0
ERROR=""
for OPT in $@; do
  case "${OPT}" in
    "-h" )
      USAGE
      exit 0
      ;;
    "-q" )
      QUIETMODE=TRUE
      ;;
    "-t" )
      TESTMODE=TRUE
      ;;
    "-d" )
      DATA_BACKUP_ONLY=TRUE
      if [ "${CONFIG_BACKUP_ONLY}" == "TRUE" ]; then
        ERROR_CODE=12
        ERROR="Combining options -c and -d is not sensible."
        break;
      fi
      ;;
    "-c" )
      CONFIG_BACKUP_ONLY=TRUE
      if [ "${DATA_BACKUP_ONLY}" == "TRUE" ]; then
        ERROR_CODE=12
        ERROR="Combining options -c and -d is not sensible."
        break;
      fi
      ;;
    "-p" )
      PRINT_PARAMETERIZATION=TRUE
      ;;
    "-w")
      if ! [ "${SUFFIX_MODE}" == "INITIAL" ]; then
        ERROR_CODE=13
        ERROR="Combining options -w, -p and user-defined suffix is not sensible."
        break;
      fi
      SUFFIX_MODE="WEEKDAY"
      ;;
    "-o")
      if ! [ "${SUFFIX_MODE}" == "INITIAL" ]; then
        ERROR_CODE=13
        ERROR="Combining options -w, -p and user-defined suffix is not sensible."
        break;
      fi
      SUFFIX_MODE="PARITY"
      ;;
    "-ld")
      if [ "${LIST_LOG_BACKUPS}" == "TRUE" ]; then
        ERROR_CODE=16
        ERROR="Combining options -ld and -ll is not sensible"
        break;
      fi
      LIST_DATA_BACKUPS="TRUE"
      ;;
    "-cd")
       if [ "${LIST_LOG_BACKUPS}" == "TRUE" ] || [ "${LIST_DATA_BACKUPS}" == "TRUE" ]; then
         ERROR="Combining options -ld and cd is not allowed"
         ERROR_CODE=17
         break;
       fi
       CATALOG_DELETE="TRUE"
       ;;
    "-cl")
      CLEAN_BACKUP_LIST="TRUE"
      ;;
    "-od")
      USE_OLDEST_BACKUP="TRUE"
      ;;
    "-ll")
      if [ "${LIST_DATA_BACKUPS}" == "TRUE" ]; then
        ERROR_CODE=16
        ERROR="Combining options -l and --list-free-logs is not sensible"
        break;
      fi
      LIST_LOG_BACKUPS="TRUE"
      ;;
    * )
      COMMAND=$(echo ${OPT} | cut -d '=' -f 1)
      if [ "${COMMAND}" == "--help" ]; then
        USAGE
        exit 0;
      fi
      if [ "${COMMAND}" == "--suffix" ]; then
        if ! [ "${SUFFIX_MODE}" == "INITIAL" ]; then
          ERROR_CODE=13
          ERROR="Combining options -w, -p and user-defined suffix is not sensible."
          break;
        fi
        SUFFIX_MODE="USER"
        SUFFIX=$(echo ${OPT} | cut -d '=' -f 2)
      elif [ "${COMMAND}" == "--retention" ]; then
          if ! [ "${SUFFIX_MODE}" == "INITIAL" ]; then
            ERROR_CODE=13
            ERROR="Combining options -w, -p and user-defined suffix is not sensible."
            break;
          fi
        SUFFIX_MODE="RETENTION"
        SUFFIX=$(echo ${OPT} | cut -d '=' -f 2)
      elif [ "${COMMAND}" == "--backup-id" ]; then          
        DATA_BACKUP_ID=$(echo ${OPT} | cut -d '=' -f 2)
      elif [ "${COMMAND}" == "--output-file" ]; then
        LIST_OUTPUT_FILE=$(echo ${OPT} | cut -d '=' -f 2)
      elif [ "${COMMAND}" == "--config-file" ]; then 
        CFG_FILENAME=$(echo ${OPT} | cut -d '=' -f 2)
      else
        USAGE
        # return code 11: invalid command line option
        ERROR_CODE=11
        ERROR="invalid command line option: ${OPT}"
        break;
      fi
      ;;
  esac;
done

case ${SUFFIX_MODE} in
    "WEEKDAY")
      # Day of the week in three-letter abbreviatio (Mon, Tue, ..., Sun)
      # Used for rolling backup, one file per weekday.
      SUFFIX=$(date +%a)
      ;;
    "PARITY")
      # Parity of the day of the year (day from 1..365 [366 in leap years];
      # if that is an even number, we use "EVEN" as a suffix, otherwise 
      # we use "ODD". This creates rolling backups, backup being overwritten
      # every other day.
      #
      # compute day of year:
      DAYOFYEAR_STRING=$(date +%j)
      # strip leading zeros for numeric conversion:
      DUMMY=$(expr "${DAYOFYEAR_STRING}" : '0*\([1-9][0-9]*\)');
      declare -i DAYOFYEAR_NUMERIC=${DUMMY}
      if [ $((DAYOFYEAR_NUMERIC%2)) -eq 0 ]; then
        SUFFIX="EVEN"
      else
        SUFFIX="ODD"
      fi
      ;;
    "USER")
      # user defined suffix, we do not change the provided suffix
      if [ ${#SUFFIX} -eq 0 ]; then
        ERROR_CODE=14
        ERROR="No value given with option --suffix"
      fi
      ;;
    "RETENTION")
      # test if the argument is purely numerical
      DUMMY=$(echo ${SUFFIX} | grep -e [^0-9]);
      if [ $? -eq 0 ]; then
        ERROR_CODE=15
        ERROR="Non-numeric retention time given"
      fi
      if [ ${#SUFFIX} -eq 0 ]; then
        ERROR_CODE=15
        ERROR="No value given with option --retention"
      fi
      declare -i RETENTION_TIME=${SUFFIX}
      DAYOFYEAR_STRING=$(date +%j)
      # strip leading zeros for numeric conversion:
      DUMMY=$(expr "${DAYOFYEAR_STRING}" : '0*\([1-9][0-9]*\)');
      declare -i DAYOFYEAR_NUMERIC=${DUMMY}
      SUFFIX=COUNT_$((DAYOFYEAR_NUMERIC%RETENTION_TIME))
      ;;
    *)
       SUFFIX_MODE="WEEKDAY";
       SUFFIX=$(date +%a)
       ;;
esac

############### Configuration ######################################
#if  [ ${CFG_FILENAME} == "" ]; then 
declare -i CFG_FILE_LINE=$LINENO+3
if  [ "${CFG_FILENAME}" == "" ]; then
  # in case no configuration has been given on the command line
  CFG_FILENAME="<enter file name here>"
fi
if ! [ -e "${CFG_FILENAME}" ]; then
  cat << EOF

Error: invalid configuration file name: ${CFG_FILENAME}

You can specify a configuration file:
- via command line option --config-file=<name>
- by inserting the file name at line ${CFG_FILE_LINE}

You can see all available options by running $0 --help

EOF
  ERROR_CODE=18
  ERROR="No valid configuration file given"
  exit $ERROR_CODE
fi
source ${CFG_FILENAME}


#######################################################
################ Temporary Files ######################
# File we use to keep track of all temp files created
TMP_FILE_TMP=$(mktemp --tmpdir=/tmp backup_temp_files.XXX)
# file used by hdbsql for actual backup execution
BACKUP_SQL=$(mktemp --tmpdir=/tmp backup_sql.XXX)
echo ${BACKUP_SQL} >> ${TMP_FILE_TMP}
# temporary file needed fore above statistics collection
TIME_TMP=$(mktemp --tmpdir=/tmp backup_${SID}_timing_temp.XXX)
echo ${TIME_TMP} >> ${TMP_FILE_TMP}
# temporary file used for outputting backup start information
START_TMP=$(mktemp --tmpdir=/tmp backup_${SID}_start_temp.XXX)
echo ${START_TMP} >> ${TMP_FILE_TMP}
# temporary file for SQL statements sent during statistics logging
SQL_TMP=$(mktemp --tmpdir=/tmp backup_${SID}_sql_temp.XXX)
echo ${SQL_TMP} >> ${TMP_FILE_TMP}
# temporary file used for output of queries related to statistics logging
SQL_OUT_TMP=$(mktemp --tmpdir=/tmp backup_${SID}_sql_out_temp.XXX)
echo ${SQL_OUT_TMP} >> ${TMP_FILE_TMP}
# temporary file used for printing the system parameterization
PARAM_TMP=$(mktemp --tmpdir=/tmp backup_${SID}_param_temp.XXX)
echo ${PARAM_TMP} >> ${TMP_FILE_TMP}

declare -i ACKLINEONE=$LINENO+1
I_ACKNOWLEDGE_THAT_THIS_SCRIPT_IS_NOT_SUPPORTED_BY_SAP="No"
if ! [ "${I_ACKNOWLEDGE_THAT_THIS_SCRIPT_IS_NOT_SUPPORTED_BY_SAP}" == "YES" ]; then
  cat << EOF
  
  ERROR: You did not acknowledge that this script is not supported by SAP.

  At line $ACKLINEONE of the script, change the value of a varaible named
  I_ACKNOWLEDGE_THAT_THIS_SCRIPT_IS_NOT_SUPPORTED_BY_SAP
  to "YES".

  This step was introduced to point out even more clearly that the script
  is only provided as part of an SAP consulting note and does not represent
  official SAP software.

  Should you run into any difficulties when running this script, you cannot
  expect to receive assistance from the author or other parties at SAP.

EOF
  exit 99
fi


#######################################################
########  Write backup status log to DB tables ########
log_status()
{
  # parameters: 
  # 1: time stamp (date +%F\ %T)
  # 2: suffix of backup run (weekday or suffix)
  # 3: return code
  # 4: text for return code
 
  if [ ${TESTMODE} == "TRUE" ]; then
    return;
  fi
  if [ ${WRITE_STATS_TO_TABLE} == "TRUE" ]; then

    ########## Test if table exists 
    cat > ${SQL_TMP} << EOF
select * from M_CS_TABLES where SCHEMA_NAME='${STATS_SCHEMA}' and TABLE_NAME='${LOG_TABLE}'
EOF
    if [ "${USE_HDBUSERSTORE}" == "TRUE" ]; then
      USERSTORE_OPTION="-U ${USERSTORE_KEY_STATS}"
    else
      USERSTORE_OPTION=""
    fi
    ${HDBSQL_EXE} -a -c \; ${USERSTORE_OPTION} -I ${SQL_TMP} -o ${SQL_OUT_TMP}
    LINECOUNT=$(wc ${SQL_OUT_TMP} | awk '{ print $1 }')

    # if it doesn't exist, create it
    if [ "${LINECOUNT}" == "0" ]; then
      cat > ${SQL_TMP} << EOF
create column table ${STATS_SCHEMA}.${LOG_TABLE} (
  TIME_STAMP VARCHAR(20) PRIMARY KEY,
  DATE VARCHAR(20),
  TIME VARCHAR(20),
  FILE_SUFFIX VARCHAR(128),
  RETURN_CODE VARCHAR(4),
  RETURN_CODE_TEXT VARCHAR(256)
);
EOF
      ${HDBSQL_EXE} -c \; ${USERSTORE_OPTION} -I ${SQL_TMP} -o ${SQL_OUT_TMP}
    fi # table created

    THE_DATE=$(echo ${1} | awk '{ print $1 }')
    THE_TIME=$(echo ${1} | awk '{ print $2 }')

    # insert log message into table:
    cat > ${SQL_TMP} << EOF
insert into ${STATS_SCHEMA}.${LOG_TABLE} 
  (TIME_STAMP,DATE,TIME,FILE_SUFFIX,RETURN_CODE,RETURN_CODE_TEXT) 
  values ('${1}','${THE_DATE}','${THE_TIME}','${2}','${3}','${4}');
EOF
    ${HDBSQL_EXE} -c \; ${USERSTORE_OPTION} -I ${SQL_TMP} -o ${SQL_OUT_TMP}

    # clean up temp files
    rm ${SQL_TMP}
    rm ${SQL_OUT_TMP}
  fi
} # end of log_status()




print_parameterization()
{
  cat > ${PARAM_TMP} << EOF

**********************************************
**** Script Parameterization *****************

*** Command line Options ***
 Backup suffix mode = ${SUFFIX_MODE}
 Backup file suffix = ${SUFFIX}
 Test mode = ${TESTMODE}
 Quiet mode = ${QUIETMODE}
 Backup data only = ${DATA_BACKUP_ONLY}
 Backup configuration only = ${CONFIG_BACKUP_ONLY}
 Print parameterization = ${PRINT_PARAMETERIZATION}

*** Script parameterization ***
 * Database system specifics:
  SID = ${SID}
  Instance = ${INSTANCE}
  Host name = ${HOSTNAME}
  HANA installation directory = ${SIDPATH}
  HANA instance directory = ${INSTPATH}

 * target directory and file name for backup
  Backup base directory = ${BACKUP_BASE_DIRECTORY}
  Data backup directory = ${BACKUP_DATA_DIRECTORY}
  Configuration backup directory = ${BACKUP_CONFIG_DIRECTORY}
  Backup file name = ${BACKUP_FILE_NAME}
  Fully qualified backup file name = ${BACKUP_FILE_FULL_NAME}
 
 * hdbsql and hdbuserstore information
  Executable for hdbsql = ${HDBSQL_EXE}
  Input file for backup in hdbsqbl = ${BACKUP_SQL}
  Usage of hdbuserstore = ${USE_HDBUSERSTORE}
  Userstore key = ${USERSTORE_KEY}

 * log and statistics output in text files
  Log output directory = ${LOG_DIRECTORY}
  Log file for script execution = ${SCRIPT_LOG}
  Log file for backup execution in hdbsql = ${BACKUP_LOG}
  Statistics file for backup performance measurement = ${TIME_MEASUREMENTS}

 * log and statistics output into database tables
  Write statistics to databaes table = ${WRITE_STATS_TO_TABLE}
  Schema in which statistics table lies = ${STATS_SCHEMA}
  Table name for statistics output = ${STATS_TABLE}
  Table name for log output = ${LOG_TABLE}
  Userstore key for statistics writing = ${USERSTORE_KEY_STATS}

 * Program control
  Display splash screen = ${WAIT_AND_WARN}
  Wait time for splash screen = ${WAIT_TIME}

******* End of  Parameterization *************
**********************************************

EOF
} # end of print_parameterization()








run_backup()
{

###########################################################
###### Test if backup directories exist ###################
#
# and try creating directories if they do not exist
# exit this script if creation of backup directories fails 
if [ ${TESTMODE} == FALSE ]; then
  # check if backup target directory exists; create if it doesn't exist.
  if ! [ -d ${BACKUP_BASE_DIRECTORY} ]; then
    mkdir -p ${BACKUP_BASE_DIRECTORY} 
    if ! [ $? -eq 0 ]; then
      echo "Directory ${BACKUP_BASE_DIRECTORY} does not exist and could not be created" > ${SCRIPT_LOG}
      # return code 1: could not create backup base directory
      timestamp2=$(date +%F\ %T)
      log_status "${timestamp2}" "${SUFFIX}" 1 "Could not create backup base directory ${BACKUP_BASE_DIRECTORY}"
      exit 1;
    fi
  fi
  if ! [ -d ${BACKUP_DATA_DIRECTORY} ]; then
    mkdir -p ${BACKUP_DATA_DIRECTORY}
    if ! [ $? -eq 0 ]; then
      echo "Directory ${BACKUP_DATA_DIRECTORY} does not exist and could not be created" > ${SCRIPT_LOG}
      # return code 2: could not create data backup directory
      timestamp2=$(date +%F\ %T)
      log_status "${timestamp2}" "${SUFFIX}" 2 "Could not create data backup directory ${BACKUP_DATA_DIRECTORY}"
      exit 2;
    fi
  fi
  if ! [ -d ${BACKUP_CONFIG_DIRECTORY} ]; then
    mkdir -p ${BACKUP_CONFIG_DIRECTORY}
    if ! [ $? -eq 0 ]; then
      echo "Directory ${BACKUP_CONFIG_DIRECTORY} does not exist and could not be created" > ${SCRIPT_LOG}
      # return code 3: could not create config backup directory
      timestamp2=$(date +%F\ %T)
      log_status "${timestamp2}" "${SUFFIX}" 3 "Could not create config backup directory ${BACKUP_CONFIG_DIRECTORY}"
      exit 3;
    fi
    rmdir ${BACKUP_CONFIG_DIRECTORY}
  fi
fi

#################################################################
############### CREATE BACKUP.SQL FILE ##########################
#
# remove the backup.sql to be used in hdbsql (only if it exists)
if [ -e ${BACKUP_SQL} ]; then
  rm ${BACKUP_SQL}
fi

# and create a new backup.sql uses the correct output file
cat > ${BACKUP_SQL} << EOF
BACKUP DATA ALL USING FILE ('${BACKUP_FILE_FULL_NAME}');
EOF
# Note:
# If you cannot or do not want to use hdbuserstore, 
# you can enter the connection details into the ${BACKUP_SQL}
# file instead. File ${BACKUP_SQL} should then begin 
# as follows:
# \connect -n ${hostname} -i ${INSTANCE} -u <USER> -p <PASSWORD>;
#
# of course, the line must not start with the hash #
# and <USER> and <PASSWORD> need to be replaced with the 
# credentials of a backup admin user.
# 
# Also Note: we are calling hdbsql with option "-c ;" which means
# the delimiter for multiple statements inside of file ${BACKUP_SQL}
# has to be the semicolon ";". See "hdbsql -h" for a full description
# of hdbsql options.


if [ "${USE_HDBUSERSTORE}" == "TRUE" ]; then
  USERSTORE_OPTION="-U ${USERSTORE_KEY}"
else
  USERSTORE_OPTION=""
fi


###########################################################
########### Prepare Backup Start Information ##############
#
cat > ${START_TMP} << EOF

  Starting backup for
  SAP HANA Database
  SID: ${SID}
  Instance: ${INSTANCE}
  Into backup path ${BACKUP_DATA_DIRECTORY}
  backup files: ${BACKUP_FILE_NAME}
EOF
  # display statistical information of last backup:
  if [ -e ${TIME_MEASUREMENTS} ]; then
    LASTTIME=$(cat ${TIME_MEASUREMENTS} | tail -n 1 | cut --delimiter=, --fields=3)
    declare -i LASTSIZE=$(cat ${TIME_MEASUREMENTS} | tail -n 1 | cut --delimiter=, --fields=2)
    LASTSIZE=${LASTSIZE}/1024/1024
    declare -i FREESIZE=$(df -P ${BACKUP_DATA_DIRECTORY} | tail -n 1 | awk '{ print $4 }')
    FREESIZE=${FREESIZE}/1024/1024
    cat >> ${START_TMP} << EOF

  Size of last backup: ${LASTSIZE} GB
  Free space on drive: ${FREESIZE} GB

  Run time of last backup: ${LASTTIME} seconds
EOF
  fi
  # and announce that we'll wait plus display "progress of waiting"
  cat >> ${START_TMP} << EOF 

  Backup will start in ${WAIT_TIME} seconds.
  Press CTRL+C to prevent running backup.
EOF

###########################################################
################## "Splash Screen" ########################
#
# do not display if called with -q
if [ "${QUIETMODE}" == "TRUE" ]; then
  WAIT_AND_WARN=FALSE
fi
# and else: only display if so configured
if [ ${WAIT_AND_WARN} == "TRUE" ]; then
  if [ ${TESTMODE} == "TRUE" ]; then
    echo ""
    echo "  *** Test Mode - no files will be written ***"
  fi
  # we prepared all important information in the temp file
  cat ${START_TMP}
  # and add the test-mode disclaimer if needed.
  if [ ${TESTMODE} == "TRUE" ]; then
    echo ""
    echo "  *** Test Mode - no files will be written ***"
  fi
  echo -n "  "
  declare -i count=0
  while [ $count -lt ${WAIT_TIME} ]; do
    echo -n '.'
    count=${count}+1
    sleep 1
  done
  echo ""
  echo "  Time up, starting backup"
  echo ""
fi


##################################################################
################ Statistics gathering ############################
#
# Check if the timing measurements file exists. If not, create it.
if ! [ -e ${TIME_MEASUREMENTS} ]; then
  touch ${TIME_MEASUREMENTS}
  echo "TIME_STAMP,BACKUP_SIZE,REAL_TIME,USER_TIME,SYSTEM_TIME" >> ${TIME_MEASUREMENTS}
fi

#####################
# Some log messages:
# Weekday:
echo "===================================================="  > ${SCRIPT_LOG}
echo "=== Backup Log $(date)" >> ${SCRIPT_LOG}










##################################################################
############### Logging Configuration Customizing ################

echo "writing to DB" >> ${SCRIPT_LOG}
if [ ${TESTMODE} == "FALSE" ]; then
 if ! [ "${CONFIG_BACKUP_ONLY}" == "TRUE" ]; then
  if [ ${WRITE_STATS_TO_TABLE} == "TRUE" ]; then

    # Before running the backup, we insert the configuration customizing
    # with BACKUP_ID = 0. Once the backup is finished, we will update this
    # to reflect the actual backup ID.
    BACKUP_ID="0"

    ##############################################################################
    # Log all configuration changes (values not DEFAULT) into logging table:

    ########## Test if table exists 
    cat > ${SQL_TMP} << EOF
select * from M_CS_TABLES where SCHEMA_NAME='${STATS_SCHEMA}' and TABLE_NAME='${CONFIG_TABLE}'
EOF
    cat ${SQL_TMP} >> ${SCRIPT_LOG}
    if [ "${USE_HDBUSERSTORE}" == "TRUE" ]; then
      USERSTORE_OPTION="-U ${USERSTORE_KEY_STATS}"
    else
      USERSTORE_OPTION=""
    fi
    rm ${SQL_OUT_TMP}
    ${HDBSQL_EXE} -a -c \; ${USERSTORE_OPTION} -I ${SQL_TMP} -o ${SQL_OUT_TMP}
    echo "Tested if config change table ${CONFIG_TABLE} exists" >> ${SCRIPT_LOG}
    echo "Result of test query:" >> ${SCRIPT_LOG}
    echo "----------------- BEGIN test query result --------------" >> ${SCRIPT_LOG}
    cat ${SQL_OUT_TMP} >> ${SCRIPT_LOG}
    echo "----------------- END test query result --------------" >> ${SCRIPT_LOG}
    LINECOUNT=$(wc ${SQL_OUT_TMP} | awk '{ print $1 }')
    # if it doesn't exist, create it
    if [ "${LINECOUNT}" == "0" ]; then
      echo "Creating configuration customizing log table ${STATS_SCHEMA}.${CONFIG_TABLE}" >> ${SCRIPT_LOG}
      cat > ${SQL_TMP} << EOF
create column table ${STATS_SCHEMA}.${CONFIG_TABLE} (
    BACKUP_ID BIGINT, 
    FILE_NAME VARCHAR(256), 
    LAYER_NAME VARCHAR(16), 
    TENANT_NAME VARCHAR(256),
    HOST VARCHAR(64),
    SECTION VARCHAR(128),
    KEY VARCHAR(128),
    VALUE VARCHAR(5000),
    PRIMARY KEY (BACKUP_ID, FILE_NAME, LAYER_NAME, TENANT_NAME, HOST, SECTION, KEY)
)
EOF
    cat ${SQL_TMP} >> ${SCRIPT_LOG}
      ${HDBSQL_EXE} -c \; ${USERSTORE_OPTION} -I ${SQL_TMP} -o ${SQL_OUT_TMP}
      echo "Result of creating table: " >> ${SCRIPT_LOG}
      cat ${SQL_OUT_TMP} >> ${SCRIPT_LOG}
    fi # config change log table created
    
    # make sure there are no entries in the table with BACKUP_ID = 0:
    cat > ${SQL_TMP} << EOF
DELETE FROM ${STATS_SCHEMA}.${CONFIG_TABLE} 
  WHERE BACKUP_ID = 0
EOF
    echo "Deleting any entry with BACKUP_ID = 0 from config log table" >> ${SCRIPT_LOG}
    cat ${SQL_TMP} >> ${SCRIPT_LOG}
    ${HDBSQL_EXE} -c \; ${USERSTORE_OPTION} -I ${SQL_TMP} -o ${SQL_OUT_TMP} 2> /dev/null

    # insert customized parameters into table:
    cat > ${SQL_TMP} << EOF
INSERT INTO ${STATS_SCHEMA}.${CONFIG_TABLE} 
  ( SELECT ${BACKUP_ID} AS BACKUP_ID, FILE_NAME, LAYER_NAME, TENANT_NAME, 
           HOST, SECTION, KEY, VALUE
    FROM M_INIFILE_CONTENTS where LAYER_NAME != 'DEFAULT' );
EOF
    cat ${SQL_TMP} >> ${SCRIPT_LOG}
    ${HDBSQL_EXE} -c \; ${USERSTORE_OPTION} -I ${SQL_TMP} -o ${SQL_OUT_TMP}
    echo "Entered Parameter customizing into log table ${STATS_SCHEMA}.${CONFIG_TABLE}." >> ${SCRIPT_LOG}

cat >> ${SCRIPT_LOG} << EOF

===============================================================
=============     Inifile Customization    ====================

At the time of backup creation 
the inifile customization as recorded in table ${STATS_SCHEMA}.${CONFIG_TABLE}
was in place. Initially, entries are recoded with BACKUP_ID=0. If the backup
finishes successfully, they will be updated to the actual backup ID.

to implement these parameter changes in a database system, you may run 
the SQL statements below.

EOF
  # Create list of all customizing parameter changes:
    cat > ${SQL_TMP} << EOF
select 'ALTER SYSTEM ALTER CONFIGURATION  ('''|| file_name ||''', '''||
                        case layer_name 
                                      when 'SYSTEM' then layer_name 
                                      when 'HOST' then layer_name ||''', '''|| host 
                         end ||
                        ''') SET ('''|| section ||''', '''|| key ||''') = '''||value ||''' WITH RECONFIGURE;'
from m_inifile_contents 
  where layer_name != 'DEFAULT'
EOF
    ${HDBSQL_EXE} -c \; ${USERSTORE_OPTION} -I ${SQL_TMP} -o ${SQL_OUT_TMP}
    cat ${SQL_OUT_TMP} >> ${SCRIPT_LOG}

    cat >> ${SCRIPT_LOG} << EOF

==============================================================

The list of SQL statement was generated using the following query:
EOF
    cat ${SQL_TMP} >> ${SCRIPT_LOG}
    # end of writing customizing to statistics table.
  fi
 fi
fi







# write the prepared backup start information to the log file.
echo "" >> ${SCRIPT_LOG}
cat ${START_TMP} >> ${SCRIPT_LOG}

if [ ${PRINT_PARAMETERIZATION} == "TRUE" ]; then
  print_parameterization
  cat ${PARAM_TMP} >> ${SCRIPT_LOG}
  rm ${PARAM_TMP}
fi

# Output files:
echo "" >> ${SCRIPT_LOG}
echo "Data backup written to files ${BACKUP_FILE_FULL_NAME}_databackup_*" >> ${SCRIPT_LOG}
echo "Configuration backup written to directory ${BACKUP_CONFIG_DIRECTORY}" >> ${SCRIPT_LOG}

echo "" >> ${SCRIPT_LOG}
if [ -e ${BACKUP_FILE_FULL_NAME}_databackup_0_1 ]; then
# Size of previous backup:
  echo -n "Old backup size for ${SUFFIX}: " >> ${SCRIPT_LOG}
  du -hcs ${BACKUP_FILE_FULL_NAME}_databackup_* | tail -n 1 >> ${SCRIPT_LOG}
else
  echo "No previous backup existing for ${SUFFIX}" >> ${SCRIPT_LOG}
fi
# Time stamp from before the backup
echo "" >> ${SCRIPT_LOG}
echo -n "Backup started at: " >> ${SCRIPT_LOG}
date >> ${SCRIPT_LOG}

#####################################################################
#################### Run the actual backup: #########################
#
echo "Run backup: ${HDBSQL_EXE} -c \; ${USERSTORE_OPTION} -I ${BACKUP_SQL} -o ${BACKUP_LOG}" >> ${SCRIPT_LOG}
echo "Content of ${BACKUP_SQL}:" >> ${SCRIPT_LOG}
cat ${BACKUP_SQL} >> ${SCRIPT_LOG}

# run data backup, unless CONFIG_BACKUP_ONLY is set to TRUE
if ! [ "${CONFIG_BACKUP_ONLY}" == "TRUE" ]; then
  if [ ${TESTMODE} == FALSE ]; then
    # current time stamp in format YYYY-MM-DD_HH:MM:SS
    timestamp=$(date +%F_%T)
    timestamp2=$(date +%F\ %T)
    # run backup and measure time 

    /usr/bin/time -p -o ${TIME_TMP} ${HDBSQL_EXE} -c \; ${USERSTORE_OPTION} -I ${BACKUP_SQL} -o ${BACKUP_LOG} 

    declare -i HDBSQL_EXIT=$?
    if ! [ ${HDBSQL_EXIT} -eq 0 ]; then
      echo "Data backup failed. Return code of hdbsql: ${HDBSQL_EXIT}" >> ${SCRIPT_LOG}
      echo "See hdbsql log: ${BACKUP_LOG}" >> ${SCRIPT_LOG}
      timestamp2=$(date +%F\ %T)
      log_status "${timestamp2}" "${SUFFIX}" 4 "Data backup failed with hdbsql return code ${HDBSQL_EXIT}. See hdbsql log ${BACKUP_LOG}"
      exit 4
    fi
    realtime=$(cat ${TIME_TMP} | grep real | awk '{ print $2 }' | cut --delimiter=. --fields=1)
    usertime=$(cat ${TIME_TMP} | grep user | awk '{ print $2 }' | cut --delimiter=. --fields=1)
    systime=$(cat ${TIME_TMP} | grep sys | awk '{ print $2 }' | cut --delimiter=. --fields=1)
    # determine size of backup in bytes
    backupsize=$(du -cs ${BACKUP_FILE_FULL_NAME}_databackup_* | tail -n 1 | awk '{ print $1 }') 
    # append time and size info to csv file
    echo "${timestamp},${backupsize},${realtime},${usertime},${systime}" >> ${TIME_MEASUREMENTS}
    rm ${TIME_TMP}
  fi
  # Time of finishing backup
  echo -n "Backup finished at: " >> ${SCRIPT_LOG}
  date >> ${SCRIPT_LOG}
  echo "" >> ${SCRIPT_LOG}
  echo -n "New backup size: " >> ${SCRIPT_LOG}
  if [ "${TESTMODE}" == FALSE ]; then
    du -hcs ${BACKUP_FILE_FULL_NAME}_databackup_* | tail -n 1 >> ${SCRIPT_LOG}
  else
    echo "N/A" >> ${SCRIPT_LOG}
  fi
fi


echo "Copying Configuration Files" >> ${SCRIPT_LOG}
echo "- Global configuration files:" >> ${SCRIPT_LOG}
echo "  from ${SIDPATH}/SYS/global/hdb/custom/config/ to ${BACKUP_CONFIG_DIRECTORY}/global/" >> ${SCRIPT_LOG}
echo "- host configuration files:" >> ${SCRIPT_LOG}
echo "  from ${INSTPATH}/${HOSTNAME}/ to ${BACKUP_CONFIG_DIRECTORY}/${HOSTNAME}" >> ${SCRIPT_LOG}


if [ ${TESTMODE} == FALSE ]; then
  if ! [ "${DATA_BACKUP_ONLY}" == "TRUE" ]; then
    ######################################
    # now create backup of config files:
    # remove old backup for weekday/suffix if exists
    if [ -d ${BACKUP_CONFIG_DIRECTORY} ]; then 
      rm ${BACKUP_CONFIG_DIRECTORY}/global/*.ini
      rm ${BACKUP_CONFIG_DIRECTORY}/${HOSTNAME}/*.ini
      rmdir ${BACKUP_CONFIG_DIRECTORY}/global
      rmdir ${BACKUP_CONFIG_DIRECTORY}/${HOSTNAME}
      rmdir ${BACKUP_CONFIG_DIRECTORY}
    fi  # end of removing old backup directories
    # prepare target directories
    mkdir -p ${BACKUP_CONFIG_DIRECTORY}
    mkdir ${BACKUP_CONFIG_DIRECTORY}/global
    mkdir ${BACKUP_CONFIG_DIRECTORY}/${HOSTNAME}
    # back up global configuration
    cp -a ${SIDPATH}/SYS/global/hdb/custom/config/*.ini ${BACKUP_CONFIG_DIRECTORY}/global
    # back up system/host configuration
    cp -a ${INSTPATH}/${HOSTNAME}/*.ini ${BACKUP_CONFIG_DIRECTORY}/${HOSTNAME}
  fi # end of backing up configuration files
fi


##################################################################
############### Logging into database table if wanted ############

echo "writing to DB" >> ${SCRIPT_LOG}
if [ ${TESTMODE} == "FALSE" ]; then
 if ! [ "${CONFIG_BACKUP_ONLY}" == "TRUE" ]; then
  if [ ${WRITE_STATS_TO_TABLE} == "TRUE" ]; then
    ########## Test if table exists 
    cat > ${SQL_TMP} << EOF
select * from M_CS_TABLES where SCHEMA_NAME='${STATS_SCHEMA}' and TABLE_NAME='${STATS_TABLE}'
EOF
    cat ${SQL_TMP} >> ${SCRIPT_LOG}
    if [ "${USE_HDBUSERSTORE}" == "TRUE" ]; then
      USERSTORE_OPTION="-U ${USERSTORE_KEY_STATS}"
    else
      USERSTORE_OPTION=""
    fi
    ${HDBSQL_EXE} -a -c \; ${USERSTORE_OPTION} -I ${SQL_TMP} -o ${SQL_OUT_TMP}
    echo "Tested if script statistics table ${STATS_TABLE} exists" >> ${SCRIPT_LOG}
    LINECOUNT=$(wc ${SQL_OUT_TMP} | awk '{ print $1 }')
    # if it doesn't exist, create it
    if [ "${LINECOUNT}" == "0" ]; then
      cat > ${SQL_TMP} << EOF
create column table ${STATS_SCHEMA}.${STATS_TABLE} (
  BACKUP_ID BIGINT PRIMARY KEY,
  TIME_STAMP VARCHAR(20),
  DATE VARCHAR(20),
  TIME VARCHAR(20),
  BACKUP_SIZE BIGINT,
  REAL_TIME INT,
  USER_TIME INT,
  SYSTEM_TIME INT
)
EOF
    cat ${SQL_TMP} >> ${SCRIPT_LOG}
      ${HDBSQL_EXE} -c \; ${USERSTORE_OPTION} -I ${SQL_TMP} -o ${SQL_OUT_TMP}
    fi # script statistics table created

    # find backup_id of latest full data backup:
    cat > ${SQL_TMP} << EOF
select TOP 1 BACKUP_ID from M_BACKUP_CATALOG 
  where entry_type_name='complete data backup'
  order by SYS_END_TIME desc;
EOF
    cat ${SQL_TMP} >> ${SCRIPT_LOG}
    ${HDBSQL_EXE} -a -c \; ${USERSTORE_OPTION} -I ${SQL_TMP} -o ${SQL_OUT_TMP}
    BACKUP_ID=$(cat ${SQL_OUT_TMP})
    
    # find time and date of finishing backup:
    THE_DATE=$(echo ${timestamp2} | awk '{ print $1 }')
    THE_TIME=$(echo ${timestamp2} | awk '{ print $2 }')

    # insert statistics into table:
    cat > ${SQL_TMP} << EOF
insert into ${STATS_SCHEMA}.${STATS_TABLE} 
  (BACKUP_ID, TIME_STAMP, DATE, TIME, BACKUP_SIZE, REAL_TIME, USER_TIME, SYSTEM_TIME) 
  values (${BACKUP_ID},'${timestamp2}','${THE_DATE}','${THE_TIME}',${backupsize},${realtime},${usertime},${systime});
EOF
    cat ${SQL_TMP} >> ${SCRIPT_LOG}
    ${HDBSQL_EXE} -c \; ${USERSTORE_OPTION} -I ${SQL_TMP} -o ${SQL_OUT_TMP}

    ##############################################################################
    # We must also change the BACKUP_ID in the config customizing log table:

    # insert customized parameters into table:
    cat > ${SQL_TMP} << EOF
UPDATE ${STATS_SCHEMA}.${CONFIG_TABLE} 
  SET BACKUP_ID=${BACKUP_ID} WHERE BACKUP_ID=0 
EOF
    echo "Updating BACKUP ID in config customizing table:" >> ${SCRIPT_LOG}
    cat ${SQL_TMP} >> ${SCRIPT_LOG}
    ${HDBSQL_EXE} -c \; ${USERSTORE_OPTION} -I ${SQL_TMP} -o ${SQL_OUT_TMP}

    echo "Updated BACKUP_ID in config customizing log ${STATS_SCHEMA}.${CONFIG_TABLE}." >> ${SCRIPT_LOG}

cat >> ${SCRIPT_LOG} << EOF

===============================================================
=============     Inifile Customization    ====================

At the end of backup creation for Backup ID = ${BACKUP_ID}
the inifile customization as recorded in table ${STATS_SCHEMA}.${CONFIG_TABLE}
was in place.

EOF
  fi
 fi
fi
# and write a status message into the log file    
log_status "${timestamp2}" "${SUFFIX}" 0 "Backup finished successfully"

} # end of run_backup()







list_data_backups()
{
    ########## Get list of data backups
    # We list all backup IDs and backup file names for 
    # * data backups
    # * that have been completed successfully
    # * where the data file is that of the indexserver
    #   (expected to be the biggest file in the data backup)
    #
    # If option -cl is given (clean list), we only list those
    # backup files that still exist on disk in their original
    # location. 
    #
    # Output is ordered by start time of the backup in descending
    # order (latest backup first)
    if [ "${CLEAN_BACKUP_LIST}" == "FALSE" ]; then
      cat > ${SQL_TMP} << EOF
select A.BACKUP_ID as BACKUP_ID, 
       A.SYS_START_TIME as START_TIME, 
       B.DESTINATION_PATH as BACKUP_FILE_NAME 
from "PUBLIC"."M_BACKUP_CATALOG" as A
  inner join 
     "PUBLIC"."M_BACKUP_CATALOG_FILES" as B
on A.BACKUP_ID = B.BACKUP_ID
where A.ENTRY_TYPE_NAME='complete data backup'
    and A.STATE_NAME='successful'
    and B.SERVICE_TYPE_NAME='indexserver'
order by A.UTC_START_TIME desc;
EOF
    else
      cat > ${SQL_TMP} << EOF
select x.BACKUP_ID as BACKUP_ID,
     x.START_TIME as START_TIME,
     x.BACKUP_FILE_NAME as BACKUP_FILE_NAME
from
( select A.BACKUP_ID as BACKUP_ID, 
       A.SYS_START_TIME as START_TIME, 
       B.DESTINATION_PATH as BACKUP_FILE_NAME 
  from "PUBLIC"."M_BACKUP_CATALOG" as A
  inner join 
     "PUBLIC"."M_BACKUP_CATALOG_FILES" as B
  on A.BACKUP_ID = B.BACKUP_ID
  where A.ENTRY_TYPE_NAME='complete data backup'
    and A.STATE_NAME='successful'
    and B.SERVICE_TYPE_NAME='indexserver'
) as x
inner join
( select  
       MAX(A.SYS_START_TIME) as START_TIME, 
       B.DESTINATION_PATH as BACKUP_FILE_NAME 
  from "PUBLIC"."M_BACKUP_CATALOG" as A
  inner join 
     "PUBLIC"."M_BACKUP_CATALOG_FILES" as B
  on A.BACKUP_ID = B.BACKUP_ID
  where A.ENTRY_TYPE_NAME='complete data backup'
    and A.STATE_NAME='successful'
    and B.SERVICE_TYPE_NAME='indexserver'
  group by B.DESTINATION_PATH
) as y
on  x.START_TIME = y.START_TIME
  and 
    x.BACKUP_FILE_NAME = y.BACKUP_FILE_NAME
order by START_TIME desc;   
EOF
    fi
    cat ${SQL_TMP} >> ${SCRIPT_LOG}
    if [ "${USE_HDBUSERSTORE}" == "TRUE" ]; then
      USERSTORE_OPTION="-U ${USERSTORE_KEY_STATS}"
    else
      USERSTORE_OPTION=""
    fi
    ${HDBSQL_EXE} -c \; -F " | " ${USERSTORE_OPTION} -I ${SQL_TMP} -o ${SQL_OUT_TMP}
    
    # If option -cl was given:
    # remove all backups from output list for which the backup file cannot 
    # be found any more in the original backup destination:    
    if [ "${CLEAN_BACKUP_LIST}" == "TRUE" ]; then
      CLEAN_LIST_TMP=$(mktemp --tmpdir=/tmp backup_${SID}_clean_list_temp.XXX)
      echo ${CLEAN_LIST_TMP} >> ${TMP_FILE_TMP}
      echo "| BACKUP_ID | START_TIME | BACKUP_FILE_NAME|" >> ${CLEAN_LIST_TMP}
      while read i; do
        FILE=$(echo ${i} | cut --delimiter=\" --fields=4)
        if [ -f "${FILE}" ]; then
          echo ${i} | sed 's#"##g' >> ${CLEAN_LIST_TMP}
        fi
      done < ${SQL_OUT_TMP}
      mv "${CLEAN_LIST_TMP}" "${SQL_OUT_TMP}"
    fi
    if ! [ -z ${LIST_OUTPUT_FILE} ]; 
      then cat ${SQL_OUT_TMP} > ${LIST_OUTPUT_FILE}
    else
      cat ${SQL_OUT_TMP}
    fi
  
} # end of list_data_backups()



list_log_backups()
{
  if [ "${USE_OLDEST_BACKUP}" == "TRUE" ]; then
    CLEAN_LIST_TMP=$(mktemp --tmpdir=/tmp backup_${SID}_clean_list_temp.XXX)
    echo ${CLEAN_LIST_TMP} >> ${TMP_FILE_TMP}
    TMP_LIST_OUTPUT_FILE=${LIST_OUTPUT_FILE}
    LIST_OUTPUT_FILE=$(mktemp --tmpdir=/tmp backup_${SID}_list_temp.XXX)
    echo ${LIST_OUTPUT_TMP} >> ${TMP_FILE_TMP}
    list_data_backups
    DATA_BACKUP_ID=$(cat ${LIST_OUTPUT_FILE} | tail -n 1 | awk '{print $2}')
    rm ${LIST_OUTPUT_FILE}
    LIST_OUTPUT_FILE=${TMP_LIST_OUTPUT_FILE}
  fi

  if [ -z ${DATA_BACKUP_ID} ]; then
    echo ""
    echo "No Backup ID given or no backup ID found with option -od"
    echo ""
    exit 30
  fi
  # test if there exists a data backup with the given DATA_BACKUP_ID that was completed successfully
  cat > ${SQL_TMP} << EOF
select A.BACKUP_ID as BACKUP_ID, 
       A.SYS_START_TIME as START_TIME
from "PUBLIC"."M_BACKUP_CATALOG" as A
where A.ENTRY_TYPE_NAME='complete data backup'
    and A.STATE_NAME='successful'
    and A.BACKUP_ID=${DATA_BACKUP_ID}
order by A.UTC_START_TIME desc;
EOF
    if [ "${USE_HDBUSERSTORE}" == "TRUE" ]; then
      USERSTORE_OPTION="-U ${USERSTORE_KEY_STATS}"
    else
      USERSTORE_OPTION=""
    fi
    ${HDBSQL_EXE} -c \; -a ${USERSTORE_OPTION} -I ${SQL_TMP} -o ${SQL_OUT_TMP}

    NHITS=$(wc ${SQL_OUT_TMP} | awk '{print $1}')
    if [ "${NHITS}" == "0" ]; then
      echo ""
      echo "No successful data backups found for backup ID ${DATA_BACKUP_ID}".
      echo ""
      exit 31;
    fi
     

    ########### Get list of log backups
    # We list all log backup file names with the following properties
    # * log backups
    # * that have last_redo_log_position greater than the
    #   redo_log_position of the given data backup
    #   
    # If command line option -cl is given (clean list), we only list
    # those files that still exist on disk (with fully qualified 
    # path name as listed in the backup catalog).
	# The SQL statement is taken from the SAP HANA Administration guide,
	# if you run into problems with this statement, please also check
	# the admin guide for possible changes.
    cat > ${SQL_TMP} << EOF
  SELECT DISTINCT 
      l.destination_path FROM m_backup_catalog_files l,
      (SELECT * FROM m_backup_catalog_files WHERE backup_id = ${DATA_BACKUP_ID}) d 
    WHERE l.destination_type_name = 'file' 
          AND ((l.last_redo_log_position IS NOT NULL AND l.source_id = d.source_id AND l.last_redo_log_position < d.redo_log_position) 
            OR (l.source_type_name = 'catalog' AND l.backup_id < d.backup_id)) 
    ORDER BY l.destination_path asc;
EOF
    cat ${SQL_TMP} >> ${SCRIPT_LOG}
    ${HDBSQL_EXE} -c \; -a ${USERSTORE_OPTION} -I ${SQL_TMP} -o ${SQL_OUT_TMP}

    # If option -cl was given:
    # remove all log backups from output list for which the backup file cannot 
    # be found any more in the original backup destination:    
    if [ "${CLEAN_BACKUP_LIST}" == "TRUE" ]; then
      CLEAN_LIST_TMP=$(mktemp --tmpdir=/tmp backup_${SID}_clean_list_temp.XXX)      
      echo ${CLEAN_LIST_TMP} >> ${TMP_FILE_TMP}
      cat ${SQL_OUT_TMP} | sed 's#"##g' | while read FILE; do
        if [ -f "${FILE}" ]; then
          echo "${FILE}" >> ${CLEAN_LIST_TMP}
        else #entry might be from DT with bug, so that two names are concatenated
          FILE1=$(echo "$FILE" | cut --delimiter=, --fields=1)
          if [ -f "${FILE1}.1" ]; then
            echo "${FILE1}.1" >> ${CLEAN_LIST_TMP}
          fi
          FILE2=$(echo "$FILE" | cut --delimiter=, --fields=2)
          if [ -f "${FILE2}" ]; then
            echo ${FILE2} >> ${CLEAN_LIST_TMP}
          fi
        fi
      done
      mv "${CLEAN_LIST_TMP}" "${SQL_OUT_TMP}"
    fi

    if ! [ -z ${LIST_OUTPUT_FILE} ]; 
      then cat ${SQL_OUT_TMP} | sed 's#"##g' > ${LIST_OUTPUT_FILE}
    else
      cat ${SQL_OUT_TMP}
    fi    
    # you can now delete obsolete log backups via
    # while read i; do if [ -e $i ]; then echo "$i - exists"; else echo $i; fi; done < list_logs.txt
  
} # end of list_log_backups()




delete_log_backups()
{
  echo "" >> ${SCRIPT_LOG}
  echo "#### Deleting old data and log backups from catalog and disk #######" >> ${SCRIPT_LOG}
  if [ "${USE_OLDEST_BACKUP}" == "TRUE" ]; then
    # determine the backup ID of the oldest data backup that still exists on disk
    CLEAN_LIST_TMP=$(mktemp --tmpdir=/tmp backup_${SID}_clean_list_temp.XXX)
    echo ${CLEAN_LIST_TMP} >> ${TMP_FILE_TMP}
    TMP_LIST_OUTPUT_FILE=${LIST_OUTPUT_FILE}
    LIST_OUTPUT_FILE=$(mktemp --tmpdir=/tmp backup_${SID}_list_temp.XXX)
    echo ${LIST_OUTPUT_FILE} >> ${TMP_FILE_TMP}
    list_data_backups
    DATA_BACKUP_ID=$(cat ${LIST_OUTPUT_FILE} | tail -n 1 | awk '{print $2}')
    rm ${LIST_OUTPUT_FILE}
    LIST_OUTPUT_FILE=${TMP_LIST_OUTPUT_FILE}
  fi

  if [ -z ${DATA_BACKUP_ID} ]; then
    echo ""
    echo "No Backup ID given or no backup ID found with option -od"
    echo ""
    exit 30
  fi
  # test if there exists a data backup with the given DATA_BACKUP_ID that was completed successfully
  cat > ${SQL_TMP} << EOF
select A.BACKUP_ID as BACKUP_ID, 
       A.SYS_START_TIME as START_TIME
from "PUBLIC"."M_BACKUP_CATALOG" as A
where A.ENTRY_TYPE_NAME='complete data backup'
    and A.STATE_NAME='successful'
    and A.BACKUP_ID=${DATA_BACKUP_ID}
order by A.UTC_START_TIME desc;
EOF
    if [ "${USE_HDBUSERSTORE}" == "TRUE" ]; then
      USERSTORE_OPTION="-U ${USERSTORE_KEY_STATS}"
    else
      USERSTORE_OPTION=""
    fi
    ${HDBSQL_EXE} -c \; -a ${USERSTORE_OPTION} -I ${SQL_TMP} -o ${SQL_OUT_TMP}

    NHITS=$(wc ${SQL_OUT_TMP} | awk '{print $1}')
    if [ "${NHITS}" == "0" ]; then
      echo ""
      echo "No successful data backups found for backup ID ${DATA_BACKUP_ID}".
      echo ""
      exit 31;
    fi
     
    # Now we have a valid Backup ID of a data backup that has 
    # been completed succesfully
    #
    # So we can call the BACKUP CATALOG DELETE... syntax

    echo "" >> ${SCRIPT_LOG}
    echo "deleting log and data backups older than backup_id ${DATA_BACKUP_ID}:" >> ${SCRIPT_LOG}
    DISK_DELETE_CLAUSE = ""
    if [ ${CATALOG_DELETE_FROM_DISK} == "TRUE" ]; then
      echo "Deleting log backups from catalog AND from disk" >> ${SCRIPT_LOG}
      DISK_DELETE_CLAUSE="WITH FILE"
    else
      echo "Deleting log backups ONLY from catalog." >> ${SCRIPT_LOG}
    fi
    cat > ${SQL_TMP} << EOF
backup catalog delete all before BACKUP_ID ${DATA_BACKUP_ID} ${DISK_DELETE_CLAUSE};
EOF
    cat ${SQL_TMP} >> ${SCRIPT_LOG}
    ${HDBSQL_EXE} -c \; -a ${USERSTORE_OPTION} -I ${SQL_TMP} -o ${SQL_OUT_TMP}
    cat ${SQL_OUT_TMP} >> ${SCRIPT_LOG}

} # end of delete_log_backups()


declare -i ACKLINETHREE=$LINENO+1
I_ACKNOWLEDGE_THAT_I_MAY_NOT_OPEN_SAP_SUPPORT_MESSAGES_REGARDING_THIS_SCRIPT="No"
if ! [ "${I_ACKNOWLEDGE_THAT_I_MAY_NOT_OPEN_SAP_SUPPORT_MESSAGES_REGARDING_THIS_SCRIPT}" == "Yes" ]; then
  cat << EOF
  
  ERROR: You did not acknowledge that SAP will not process SAP support tickets
  related to this script.

  At line $ACKLINETHREE of the script, change the value of a varaible named
  I_ACKNOWLEDGE_THAT_I_MAY_NOT_OPEN_SAP_SUPPORT_MESSAGES_REGARDING_THIS_SCRIPT
  to "Yes".

  Because this script is not provided as part of SAP-delivered software, but simply
  as a consulting note for educational purposes, SAP support will not be able to
  process SAP support messages related to the script. If you need assistance, 
  you may ask questions in the relevant forums on SAP community network (SCN).

  Should you run into any difficulties when running this script, you cannot
  expect to receive assistance from the author or other parties at SAP.

EOF
  exit 99
fi


###############################################################
####### Test script parameterization ##########################



##############
# Check if the script is correctly parameterized
# For the time being: only check "important" parameters,
# i.e. those that absolutely have to be adjusted
if ! [ ${#SID} -eq 3 ]; then
  # length of SID is zero
  ERROR_CODE=20
  ERROR="Script Parameterization: Length of SID is not 3 characters: ${SID}"
elif ! [ ${#INSTANCE} -eq 2 ]; then
  # length of instance number is zero
  ERROR_CODE=20
  ERROR="Script Parameterization: Length of instance is not 2 characters: ${INSTANCE}"
elif [ ${#HOSTNAME} -eq 0 ]; then
  # length of host name is zero
  ERROR_CODE=20
  ERROR="Script Parameterization: Hostname not specified"
  echo "[ERROR] No host name given in script configuration."
elif [ "${USE_HDBUSERSTORE}" == "TRUE" ] && [ ${#USERSTORE_KEY} -eq 0 ]; then
  # length of user store key is zero, but userstore is set to be used
  ERROR_CODE=20
  ERROR="Script Parameterization: User store shall be used but no key given"
elif ! [ -d ${INSTPATH} ]; then
  # instance path /usr/sap/${SID}/HDB${INSTANCE} does not exist
  ERROR_CODE=20
  ERROR="Script Parameterization: Instance path does not exist: ${INSTPATH}"
elif [ "${WRITE_STATS_TO_TABLE}" == "TRUE" ] && [ -z ${STATS_SCHEMA} ]; then
  ERROR_CODE=20
  ERROR="No statistics schema given for writing statistics to DB tables"
else
  DUMMY=$(echo ${INSTANCE} | grep -e [^0-9]);
  if [ $? -eq 0 ]; then
    # at least one non-numeric character in instance number
    ERROR_CODE=20
    ERROR="Script Parameterization: non-numerical instance given: ${INSTANCE}"
    break;
  fi
  ping -c 1 ${HOSTNAME} &> /dev/null
  if ! [ $? -eq 0 ]; then
    # specified host name cannot be given
    ERROR_CODE=20
    ERROR="Script Parameterization: cannot ping host name: ${HOSTNAME}"
    break;
  fi
fi




# Evaluate errors that may have occured while
# parsing command line parameters:
if ! [ ${ERROR_CODE} -eq 0 ]; then
  touch ${SCRIPT_LOG}
  echo ${ERROR} >> ${SCRIPT_LOG}
  timestamp2=$(date +%F\ %T)
  log_status "${timestamp2}" "${SUFFIX}" ${ERROR_CODE} "${ERROR}"
  exit ${ERROR_CODE}
fi


declare -i ACKLINETWO=$LINENO+1
I_ACKNOWLEDGE_THAT_THIS_IS_THE_FINAL_VERSION_OF_THIS_SCRIPT="No"
if ! [ "${I_ACKNOWLEDGE_THAT_THIS_IS_THE_FINAL_VERSION_OF_THIS_SCRIPT}" == "Certainly" ]; then
  cat << EOF
  
  ERROR: You did not acknowledge that this script will not be developed any further.

  At line $ACKLINETWO of the script, change the value of a varaible named
  I_ACKNOWLEDGE_THAT_THIS_IS_THE_FINAL_VERSION_OF_THIS_SCRIPT
  to "Certainly".

  This check was introduced in order to make every user aware of the fact
  that this script will not be developed any further. If there are items
  not working either at time of publication or any other point in time,
  the script will not be updated. 

  Should you run into any difficulties when running this script, you cannot
  expect to receive assistance from the author or other parties at SAP.

EOF
  exit 99
fi





if [ "${LIST_DATA_BACKUPS}" == "TRUE" ]; then
  list_data_backups
elif [ "${LIST_LOG_BACKUPS}" == "TRUE" ]; then
  list_log_backups
elif [ "${CATALOG_DELETE}" == "TRUE" ]; then
  delete_log_backups
else
  run_backup
fi







# clean up temp filesa
echo "Deleting temporary files" >> ${SCRIPT_LOG}
echo "List of files to check: " >> ${SCRIPT_LOG}
cat ${TMP_FILE_TMP} >> ${SCRIPT_LOG}
cat ${TMP_FILE_TMP} | while read FILE; do
  if [ -f ${FILE} ]; then
    if ! [ "${FILE}" == "" ]; then
      echo "Deleting ${FILE}" >> ${SCRIPT_LOG}
      rm ${FILE}
    fi
  else
    echo "File ${FILE} has already been cleaned up." >> ${SCRIPT_LOG}
  fi
done
echo "Deleting temp file list ${TMP_FILE_TMP}" >> ${SCRIPT_LOG}
if [ -f ${TMP_FILE_TMP} ]; then
  rm ${TMP_FILE_TMP}
fi
echo "------------------ End of Backup Script Execution -------------" >> ${SCRIPT_LOG}
# finished

