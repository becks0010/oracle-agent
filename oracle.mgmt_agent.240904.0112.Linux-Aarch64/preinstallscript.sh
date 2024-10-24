#! /bin/bash

# ------------------------------------------------------------------------------------
# Copyright (c) 2021, Oracle and/or its affiliates. All rights reserved.
#
# Installer script for Management Agent
#
# Note: Please don't execute this script directly, it can mess up your environment.
# ------------------------------------------------------------------------------------

# Set default locale
export LC_ALL=C

if [[ $# -lt 1 ]]; then
    echo "Script executed in unknown context, aborting..."
    exit 1
fi

NEW_AGENT_VERSION="240904.0112"

SERVICE_NAME="mgmt_agent"

# Default user/group is mgmt_agent
DEFAULT_OS_USER=mgmt_agent

# /opt/oracle/mgmt_agent to preexist as a symlink
OPT_ORACLE_SYMLINK=${OPT_ORACLE_SYMLINK:-false}

# If it's docker skip this check, old agents were setting just the user
if [[ ( -d /opt/oracle-mgmtagent-staging || -d /opt/oracle-mgmtagent-bootstrap ) && $RUN_AGENT_AS_USER == $DEFAULT_OS_USER ]]; then
	echo "Agent is running in container and RUN_AGENT_AS_USER is set to $RUN_AGENT_AS_USER, skipping group check"
else
	if [[ -z $RUN_AGENT_AS_USER && -n $AGENT_USER_GROUP ]]; then
		echo "RUN_AGENT_AS_USER is not set but AGENT_USER_GROUP is provided"
		echo "Please set both environment variables or none"
	    exit 1
	fi
	
	if [[ -n $RUN_AGENT_AS_USER && -z $AGENT_USER_GROUP ]]; then
		echo "AGENT_USER_GROUP is not set but RUN_AGENT_AS_USER is provided"
		echo "Please set both environment variables or none"
	    exit 1
	fi
fi

RUN_AGENT_AS_USER=${RUN_AGENT_AS_USER:-$DEFAULT_OS_USER}
AGENT_USER_GROUP=${AGENT_USER_GROUP:-$DEFAULT_OS_USER}

# In docker user may pass UID/GID to override default mgmt_agent user
DOCKER_USER_OVERRIDE=${DOCKER_USER_OVERRIDE:-false}

# Second argument can be passed to this script to override the base dir and service name
if [[ $# -eq 2 ]]; then
	SERVICE_NAME=$2
fi

BASE_DIR="/opt/oracle/${SERVICE_NAME}"

if [[ "$DOCKER_USER_OVERRIDE" == "true" ]]; then
	RUN_AGENT_AS_USER=$(id -u)
	AGENT_USER_GROUP=$(id -g)
	if [[ -n ${DOCKER_BASE_DIR} ]]; then
		BASE_DIR=${DOCKER_BASE_DIR}/${SERVICE_NAME}
	else
		BASE_DIR=${PWD}/${SERVICE_NAME}
	fi
fi

LOGNAME="preinstall_$(date -u '+%Y-%m-%d_%H').log"
LOGDIR="$BASE_DIR/installer-logs"
LOGFILE="${LOGDIR}/$LOGNAME"

is_required_version_available=false
operation="install"
java_found_at=""
version=""

if [[ $1 -gt 1 ]]; then
	# its upgrade
	operation="upgrade"
fi

# Logs the message on console and log file if present
# arg1: String to log, arg2(optional): format to use while logging
function log() {
  if [ -d "$LOGDIR" ]; then
    printf '[%s] %s - %s\n' "`date -u`" "${0##*/}" "$1" >> "$LOGFILE" 2>&1
  fi
  
  if [[ ! -z $2 ]]; then
  	printf "$2" "$1" 2>&1

  else
  	printf '%s\n' "$1" 2>&1
  fi
}

function fix_permissions_before_exit(){
	# fix file owner and permissions
	if [[ -f $LOGFILE ]]; then
		chmod 750 $LOGFILE		
		chown $RUN_AGENT_AS_USER:$AGENT_USER_GROUP $LOGFILE
	fi

	# set owner for OPT_ORACLE_SYMLINK case
	if [[ -h "$BASE_DIR" && "$OPT_ORACLE_SYMLINK" == "true" ]] ; then
		chown -h $RUN_AGENT_AS_USER:$AGENT_USER_GROUP "$BASE_DIR"
	fi
}

#
# Validates if owner environment variables are set correctly when base_dir is not
# owned by the default user. Auto-Upgrade, Docker and OCA cases are skipped as it
# is already supported
function verify_owner_set_or_fail(){
	if [[ ! ( -d /opt/oracle-mgmtagent-staging || -d /opt/oracle-mgmtagent-bootstrap ) ]]; then
		if [[ $distOs == "aix" ]]; then
			CURRENT_RUN_USER=$(istat "${BASE_DIR}" | awk -F"[()]" '/Owner/{print $2}')
			CURRENT_USER_GROUP=$(istat "${BASE_DIR}" | awk -F"[()]" '/Owner/{print $4}')
		else
			CURRENT_RUN_USER=$(stat -c '%U' ${BASE_DIR})
			CURRENT_USER_GROUP=$(stat -c '%G' ${BASE_DIR})
		fi

		log "Current agent run-as-user is ${CURRENT_RUN_USER}" "\t\t%s\n"
		log "Current user group is ${CURRENT_USER_GROUP}" "\t\t%s\n"
		if [[ "${CURRENT_RUN_USER}" != "${DEFAULT_OS_USER}" ]]; then
			log "${CURRENT_RUN_USER} is not the default user, checking if required environment variables are set" "\t\t%s\n"
			if [[ "${RUN_AGENT_AS_USER}" != "${CURRENT_RUN_USER}" ]]; then
				log "RUN_AGENT_AS_USER=${RUN_AGENT_AS_USER} contains an unexpected value" "\t\t%s\n"
				echo "Expected RUN_AGENT_AS_USER value to be ${CURRENT_RUN_USER}, exiting"
			    exit 1
			fi

			if [[ "${AGENT_USER_GROUP}" != "${CURRENT_USER_GROUP}" ]]; then
				log "AGENT_USER_GROUP=${AGENT_USER_GROUP} contains an unexpected value" "\t\t%s\n"
				echo "Expected AGENT_USER_GROUP value to be ${CURRENT_USER_GROUP}, exiting"
			    exit 1
			fi
		fi
	fi
}

function verify_agent_version(){

	log "Checking agent version" "\t%s\n"
	
	AGENT_CORE_FILE=$BASE_DIR/agent_inst/bin/agentcore
	
	if [ -f "$AGENT_CORE_FILE" ]; then
		installedVersion=$(/bin/bash $AGENT_CORE_FILE version)
		installedVersionP1=10#$(cut -d '.' -f1 <<< $installedVersion)
		installedVersionP2=10#$(cut -d '.' -f2 <<< $installedVersion)
		
		newVersionP1=10#$(cut -d '.' -f1 <<< $NEW_AGENT_VERSION)
		newVersionP2=10#$(cut -d '.' -f2 <<< $NEW_AGENT_VERSION)
		
		if (( ( $newVersionP1 < $installedVersionP1 ) || ( $newVersionP1 == $installedVersionP1 && $newVersionP2 <= $installedVersionP2 ) )); then
			log "Newer agent version $installedVersion is already installed. Skipping $operation for $NEW_AGENT_VERSION" "\t\t%s\n"
			log "Please note that this can happen if agent auto-upgrade is on" "\t\t%s\n"
			exit 1
		fi
	fi
}

function check_java_version(){
	type=$("$1" -version 2>&1 | awk 'NR==1 {print $1}')
	version=$("$1" -version 2>&1 | grep "version" | awk -F'"' 'NR==1 {print $2}')
	
	if [[ $distOs == "aix" && $type != "openjdk" ]]; then
		log "AIX requires openjdk" "\t\t%s\n"
	elif [[ $version == 1.8* && $version == *"_"* ]]; then
		upgradeVersion=$(cut -d '_' -f2 <<< $version)
		
		# some java versions has "-" separator used for non-GA releases
		# for e.g. 1.8.0_222-ea, we only care about first part
		if [[ $upgradeVersion == *"-"* ]]; then
			upgradeVersion=$(cut -d '-' -f1 <<< $upgradeVersion)
		fi
		
		if [ $upgradeVersion -ge 162 ]; then
			bit_check=$($1 -d64 -version 2>&1)
			EXIT_CODE=$?
			if [ $EXIT_CODE -ne 0 ]; then
				log "$java_found_at is not a 64-bit JVM!" "\t\t%s\n"
			else
				is_required_version_available=true
				java_found_at="$1"
			fi
		fi
	fi
}

trap fix_permissions_before_exit EXIT 

log "Checking pre-requisites"

distOs=$(uname -s | tr "[A-Z]" "[a-z]" | tr -d ' ')

if [[ ${distOs} == "sunos" ]]; then
	distOs="solaris"
fi 

if [[ ${distOs} == "solaris" || ${distOs} == "aix" ]]; then
	processName=$(ps -p 1 -o comm=)
else
	processName=$(ps --no-headers -o comm 1)
fi

#Execute only if its rpm -i(fresh install)
if [[ $1 == 1 ]]; then
		
	log "Checking if any previous agent service exists" "\t%s\n"
	
	if [[ $processName == "systemd" ]]; then
		FILE=/etc/systemd/system/${SERVICE_NAME}.service
		
	elif [[ $processName == "init" ]];then
		FILE=/etc/init/${SERVICE_NAME}.conf
	
	# Solaris returns process name as: /usr/sbin/init which is init.d different than OL6 init
	elif [[ $processName == *"init"* ]]; then
		FILE=/etc/init.d/${SERVICE_NAME}
	fi
	
	# AIX returns init as PID 1 but it does not have /etc/init/*.conf deamon files
	if [[ $distOs == "aix" ]]; then
		process_exists=$(lssrc -s ${SERVICE_NAME} > /dev/null 2>&1; echo $?)
		if [[ $process_exists -eq 0 ]]; then
			log "Please uninstall the agent before installing new agent!" "\t\t%s\n"
			exit 1
		fi
	elif [[ ! -z "$FILE" && -f $FILE ]]; then
		log "Please uninstall the agent and remove service file ($FILE) before installing new agent!" "\t\t%s\n"
		exit 1
	fi

	agent_pid_file="/opt/oracle/${SERVICE_NAME}/agent_inst/log/agent.pid"
	if [[ -f $agent_pid_file ]]; then
		agent_pid=$(grep -Po "(?<=pid=)\d+" $agent_pid_file)
		if ps -p $agent_pid > /dev/null; then
			log "Agent already exists. Please remove it before installing new agent!" "\t\t%s\n"
			exit 1
		else
			log "Previous agent found in failed state. Please remove it before installing new agent!" "\t\t%s\n"
			exit 1
    	fi
	fi
	
	# If user is not mgmt_agent we're overriding OS user to run management agent process as
	# validate that user/group exists
	if [[ "$RUN_AGENT_AS_USER" != "$DEFAULT_OS_USER" && "$DOCKER_USER_OVERRIDE" == "false" ]]; then
		
		log "Checking if OS user '$RUN_AGENT_AS_USER' exists" "\t%s\n"
		id -u $RUN_AGENT_AS_USER > /dev/null
		EXIT_CODE=$?
		if [[ $EXIT_CODE != 0 ]]; then
			log "OS user $RUN_AGENT_AS_USER does not exist, aborting the install" "\t\t%s\n"
			exit 1
		fi
		
		# Check if user is part of the group specified
		log "Checking if OS user belongs to group '$AGENT_USER_GROUP'" "\t%s\n"
		if [[ $distOs == "aix" ]]; then
			lsgroup -a $AGENT_USER_GROUP > /dev/null
		else
			groups $RUN_AGENT_AS_USER | tr ' ' '\n' | grep "^$AGENT_USER_GROUP$"
		fi
		EXIT_CODE=$?
		if [[ $EXIT_CODE != 0 ]]; then
			log "OS user $RUN_AGENT_AS_USER does not belong to group $AGENT_USER_GROUP, aborting the install" "\t\t%s\n"
			exit 1
		fi
	fi
	
	# If empty then only check for systemd/initctl presence
	if [[ -z "$SYSTEM_MANAGER_OVERRIDE" ]]; then 
		log "Checking if OS has systemd or initd" "\t%s\n"
		if [[ $processName != "systemd" && $processName != "init" && $processName != *"init"* ]]; then
			log "This Operating System does not have systemd, initd or init.d, aborting the install" "\t\t%s\n"
			exit 1
		fi
	fi
	
	log "Checking available disk space for agent install" "\t%s\n"
	
	if [[ $distOs == "solaris" ]]; then
	
		# This returns available space in KB
		availableMem=$(df -k /opt | awk 'NR==2 {print $4}')
		
		if (( availableMem <= 204800 )); then
			log "Available disk space found was $availableMem MB" "\t\t%s\n"
			log "Agent install requires minimum of 200 MB available disk space. Please free up some disk space and retry installing" "\t\t%s\n"
			exit 1
		fi
		
		log "Checking if environment variable SUDO_PATH is set" "\t%s\n"
		if [[ -z ${SUDO_PATH} && -f ${SUDO_PATH} ]]; then
			log "Please set SUDO_PATH environment variable with path to sudo executable" "\t\t%s\n"
			exit 1
		fi
	else
		# posix format makes sure all information is printed on exactly one line
		# This returns available space in MB
		availableMem=$(df -m -P /opt | awk ' NR == 2 {print $4}')
		
		# AIX returns floating point value
		availableMem=${availableMem%.*}
		
		if (( availableMem <= 200 )); then
			log "Available disk space found was $availableMem MB" "\t\t%s\n"
			log "Agent install requires minimum of 200 MB available disk space. Please free up some disk space and retry installing" "\t\t%s\n"
			exit 1
		fi
	fi
	
	log "Checking if ${BASE_DIR} directory exists" "\t%s\n"
	if [[ -d ${BASE_DIR} && "${OPT_ORACLE_SYMLINK}" == "false" ]]; then
		log "Installation cannot proceed. Please retry installing after deleting ${BASE_DIR} directory" "\t\t%s\n"
		exit 1
	fi
	
	# Create user only if it's default (mgmt_agent)
	if [[ "$RUN_AGENT_AS_USER" == "$DEFAULT_OS_USER" && "$DOCKER_USER_OVERRIDE" == "false" ]]; then
		log "Checking if '$DEFAULT_OS_USER' user exists" "\t%s\n"
		user_exists=$(id -u $DEFAULT_OS_USER > /dev/null 2>&1; echo $?)
		if [[ $user_exists -eq 0 ]]; then
			log "'$DEFAULT_OS_USER' user already exists, the agent will proceed installation without creating a new one." "\t\t%s\n"
		else
			userHome="/usr/share"
			if [[ -n $USER_HOME_DIR_ROOT ]]; then
				userHome=$USER_HOME_DIR_ROOT
			fi
			
			if [[ -d $userHome && -w $userHome ]]; then
				
				if [[ $distOs == "solaris" ]]; then
					getent group $DEFAULT_OS_USER 2>&1 > /dev/null || groupadd $DEFAULT_OS_USER
					out=$(useradd -d "$userHome/$DEFAULT_OS_USER" -m -c "Disabled polaris agent" -s /bin/false -g $DEFAULT_OS_USER $DEFAULT_OS_USER 2>&1)
					EXIT_CODE=$?
				elif [[ $distOs == "aix" ]]; then
					lsgroup $DEFAULT_OS_USER > /dev/null 2>&1 || mkgroup $DEFAULT_OS_USER
					out=$(useradd -d "$userHome/$DEFAULT_OS_USER" -m -c "Disabled polaris agent" -s /bin/false -g $DEFAULT_OS_USER $DEFAULT_OS_USER 2>&1)
					EXIT_CODE=$?
				else
					mkdir -p $userHome/$DEFAULT_OS_USER
					if [[ $(getent group $DEFAULT_OS_USER) ]]; then
						out=$(useradd -m -r -g $DEFAULT_OS_USER -d $userHome/$DEFAULT_OS_USER -s /bin/false -c "Disabled Oracle Polaris Agent" $DEFAULT_OS_USER 2>&1)
						EXIT_CODE=$?
					else
						out=$(useradd -m -r -U -d $userHome/$DEFAULT_OS_USER -s /bin/false -c "Disabled Oracle Polaris Agent" $DEFAULT_OS_USER 2>&1)
						EXIT_CODE=$?
					fi
				fi
				
				if [[ $EXIT_CODE != "0" ]]; then
					log "Failed to create $DEFAULT_OS_USER user. Reason: $out" "\t\t%s\n"
					exit 1
				fi
					
				chown $RUN_AGENT_AS_USER:$AGENT_USER_GROUP $userHome/$DEFAULT_OS_USER
				chmod 700 $userHome/$DEFAULT_OS_USER
					
			else
				log "Unable to create $DEFAULT_OS_USER user." "\t\t%s\n"
				log "$userHome is not writable or not a directory. Please set USER_HOME_DIR_ROOT environment variable with home directory path to use for the $DEFAULT_OS_USER user." "\t\t%s\n"
				exit 1
			fi
		fi
	fi
	
	log "Checking Java version" "\t%s\n"

	if [[ -n $JAVA_HOME ]]; then
		log "Trying $JAVA_HOME" "\t\t%s\n"
		check_java_version "$JAVA_HOME/bin/java"
	else
		log "JAVA_HOME is not set or not readable to root" "\t\t%s\n"
	fi
	
	if [ $is_required_version_available = false ]; then
		if [[ $distOs == "aix" ]]; then
			log "Trying default path /usr/java8_64/bin/java" "\t\t%s\n"
			check_java_version "/usr/java8_64/bin/java"
		else
			log "Trying default path /usr/bin/java" "\t\t%s\n"
			check_java_version "/usr/bin/java"
		fi
	fi
	
	#Final check
	if [ $is_required_version_available = true ]; then
		log "Java version: $version found at $java_found_at" "\t\t%s\n"
		JH=${java_found_at%/bin/java}
		echo $JH > /tmp/requiredJava
	else
		log "Agent only supports JDK 8 with a minimum upgrade version JDK 8u281 -b02. Please set your preferred path in JAVA_HOME" "\t\t%s\n"
		exit 1
	fi	
fi

#Executes only on upgrade

if [ $1 -gt 1 ]; then
	
	log "Checking available disk space for agent upgrade" "\t%s\n"
	if [[ $distOs == "solaris" ]]; then
	
		# This returns available space in KB
		availableMem=$(df -k /opt | awk 'NR==2 {print $4}')
		
		if (( availableMem <= 307200 )); then
			log "Available disk space found was $availableMem MB" "\t\t%s\n"
			log "Agent upgrade requires minimum of 300 MB available disk space. Please free up some disk space and retry installing" "\t\t%s\n"
			exit 1
		fi
	else
		availableMem=$(df -m -P /opt | awk ' NR == 2 {print $4}')
		
		# AIX returns floating point value
		availableMem=${availableMem%.*}
		
		if (( availableMem <= 300 )); then
			log "Available disk space found was $availableMem MB" "\t\t%s\n"
			log "Agent upgrade requires minimum of 300 MB available space. Please free up some memory and retry upgrading" "\t\t%s\n"
			exit 1
		fi
	fi

	verify_owner_set_or_fail
fi

# Executes on both rpm -i and rpm -U

verify_agent_version
