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

# Default user/group is mgmt_agent
DEFAULT_OS_USER=mgmt_agent
RUN_AGENT_AS_USER=${RUN_AGENT_AS_USER:-$DEFAULT_OS_USER}
AGENT_USER_GROUP=${AGENT_USER_GROUP:-$DEFAULT_OS_USER}

# In docker user may pass UID/GID to override default mgmt_agent user
DOCKER_USER_OVERRIDE=${DOCKER_USER_OVERRIDE:-false}

# /opt/oracle/mgmt_agent to preexist as a symlink
OPT_ORACLE_SYMLINK=${OPT_ORACLE_SYMLINK:-false}

if [[ $# -lt 1 ]]; then
    echo "Script executed in unknown context, aborting..."
    exit 1
fi

SERVICE_NAME="mgmt_agent"

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

MGMTAGENT_VERSION="240904.0112"
ARTIFACT_VERSION="1.0.9065"
ORACLE_HOME="${BASE_DIR}/${MGMTAGENT_VERSION}"
BIN_DIR="${BASE_DIR}/agent_inst/bin"
AGENTCORE_FILE="${BIN_DIR}/agentcore"
INTERNAL_ZIP=oracle.mgmt_agent-${MGMTAGENT_VERSION}.linux.zip

archType=$(uname -m | tr "[A-Z]" "[a-z]")
if [[ $archType == "aarch64" ]]; then
	INTERNAL_ZIP=oracle.mgmt_agent-${MGMTAGENT_VERSION}.linuxarm.zip
else
	INTERNAL_ZIP=oracle.mgmt_agent-${MGMTAGENT_VERSION}.linux.zip
fi

LOGNAME="postinstall_$(date -u '+%Y-%m-%d_%H').log"
LOGDIR="${BASE_DIR}/installer-logs"
LOGFILE="${LOGDIR}/$LOGNAME"

distOs=$(uname -s | tr "[A-Z]" "[a-z]" | tr -d ' ')

if [[ ${distOs} == "sunos" ]]; then
	distOs="solaris"
	INTERNAL_ZIP=oracle.mgmt_agent-${MGMTAGENT_VERSION}.solaris.zip
elif [[ ${distOs} == "aix" ]]; then
	INTERNAL_ZIP=oracle.mgmt_agent-${MGMTAGENT_VERSION}.aix.zip
fi 

if [[ ${distOs} == "solaris" || ${distOs} == "aix" ]]; then
	processName=$(ps -p 1 -o comm=)
else
	processName=$(ps --no-headers -o comm 1)
fi

captureInfo=""
JAVAHOME=""

log() {
  if [ -d "$LOGDIR" ]; then
    printf '[%s] %s - %s\n' "`date -u`" "${0##*/}" "$1" >> "$LOGFILE" 2>&1
  fi
  
  if [[ ! -z $2 ]]; then
  	printf "$2" "$1" 2>&1

  else
  	printf '%s\n' "$1" 2>&1
  fi
}

fix_permissions_before_exit(){
	# fix file owner and permissions
	if [[ -f $LOGFILE ]]; then
		chmod 750 $LOGFILE		
		chown $RUN_AGENT_AS_USER:$AGENT_USER_GROUP $LOGFILE
	fi

	if [[ -h "$BASE_DIR" && "$OPT_ORACLE_SYMLINK" == "true" ]] ; then
		chown -h $RUN_AGENT_AS_USER:$AGENT_USER_GROUP "$BASE_DIR"
	fi
}

generateStatusCheckScript() {
	
	if [[ $processName == "systemd" ]]; then
		STATUS_CMD="systemctl status ${SERVICE_NAME}"		
	elif [[ $processName == "init" ]];then
		STATUS_CMD="/sbin/initctl status ${SERVICE_NAME}"
	elif [[ $processName == *"init"* ]];then
		STATUS_CMD="${AGENTCORE_FILE} status"
	fi

	file="$BASE_DIR/agent_inst/bin/agent-status.sh"
	printf "#!/bin/sh \n\n"     > $file
	printf "# Copyright (c) 2020, Oracle and/or its affiliates. All rights reserved. \n\n" >> $file
	printf "# Agent status script to check agent status \n" >> $file 
	printf "# Usage:  agent-status.sh \n\n" >> $file
	printf "$STATUS_CMD \n" >> $file
	
	# fix file owner and permissions
	chmod 750 $file
	chown $RUN_AGENT_AS_USER:$AGENT_USER_GROUP $file
}

generateAgentPackage(){
	packageFile="$BASE_DIR/agent.package"
	
	if [[ $BASH_SOURCE == *"rpm"* ]]; then
		echo "packageType=RPM" > $packageFile
	else
		echo "packageType=ZIP" > $packageFile
	fi
	
	if [[ ${distOs} == "aix" ]]; then
		echo "packageArchitectureType=$(uname -p)" >> $packageFile
	else
		echo "packageArchitectureType=$(uname -m)" >> $packageFile 
	fi
	
	fileContent=$(cat $packageFile)
	captureInfo+="Current agent package content: ${fileContent}"$'\n'
	
	chmod 750 $packageFile
	chown $RUN_AGENT_AS_USER:$AGENT_USER_GROUP $packageFile
}

trap fix_permissions_before_exit EXIT 

initServiceFile="/etc/init/${SERVICE_NAME}.override"

# Starts service at run level 2 serially at index 99
solarisStartFile="/etc/rc2.d/S99${SERVICE_NAME}"

# Kills service at run level 0 serially at index 99
solarisKillFile="/etc/rc0.d/K99${SERVICE_NAME}"

# Solaris daemon service file (symlink to agentcore)
solarisServiceFile="/etc/init.d/${SERVICE_NAME}"
	
# Returns 0 if enabled
isProcessEnabled() {
	enabled=0
	if [[ $processName == "systemd" ]]; then
		#systemctl list-unit-files --state=disabled | grep -q ${SERVICE_NAME}.service
		systemctl -q is-enabled ${SERVICE_NAME}
		enabled=$?	
	elif [[ $processName == "init" ]];then
		# TODO: Find better way to see if service is disabled	
		if [ -f "$initServiceFile" ]; then
			if grep -Fxq "manual" $initServiceFile; then
				enabled=1
			fi
		fi
	elif [[ $processName == *"init"* ]];then
		if [[ -f $solarisServiceFile && ! -f $solarisStartFile ]]; then
			enabled=1
		fi
	fi
	
	echo $enabled
}

# Create links to the appropriate rc n.d directory
enableSolaris() {

	captureInfo+="Creating symlinks in /etc/rcn.d directory"$'\n'
	
	if [ ! -f "$solarisStartFile" ]; then
		ln $solarisServiceFile $solarisStartFile
	fi
	
	if [ ! -f "$solarisKillFile" ]; then
		ln $solarisServiceFile $solarisKillFile
	fi
}

disableService() {
	if [[ $processName == "systemd" ]]; then
		systemctl disable ${SERVICE_NAME} > /dev/null 2>&1
		EXIT_CODE=$?
		captureInfo+="Service disabled with exit code: ${EXIT_CODE}"$'\n'
	elif [[ $processName == "init" ]];then
		if [ -f "$initServiceFile" ]; then
			if grep -Fxq "manual" $initServiceFile; then
				captureInfo+="Service is already disabled"$'\n'
			fi
		else
			echo manual >> $initServiceFile
			EXIT_CODE=$?
			captureInfo+="Service disabled with exit code: ${EXIT_CODE}"$'\n'
		fi		
	elif [[ $processName == *"init"* ]]; then
		# init.d processes
		if [ -f $solarisStartFile ]; then
			mv "$solarisStartFile" "_$solarisStartFile"
			EXIT_CODE=$?
			captureInfo+="Service disabled with exit code: ${EXIT_CODE}"$'\n'
		fi
	fi
}

if [ $1 -gt 1 ]; then
	# only during upgrade service might be available before install
	if [[ -z "$SYSTEM_MANAGER_OVERRIDE" ]]; then
		isServiceEnabled=$( isProcessEnabled )
		captureInfo+="Service is enabled: ${isServiceEnabled}"$'\n'	
	fi
fi

log "Executing install" "\n%s\n"

if [ -f /tmp/requiredJava ]; then
	JAVAHOME=$(cat /tmp/requiredJava)
	rm -rf /tmp/requiredJava
fi

# During upgrade we don't check for java version, get it from script
if [ -f "${BIN_DIR}/javaPath.sh" ]; then
	JAVAHOME=$(dirname $( dirname $(/bin/bash "${BIN_DIR}/javaPath.sh")))
fi

if [[ ! -n $JAVAHOME ]]; then
	log "JavaHome is not set aborting agent install"
	exit 1
fi

export JAVAHOME=$JAVAHOME
export AGENT_USER_GROUP=$AGENT_USER_GROUP
export RUN_AGENT_AS_USER=$RUN_AGENT_AS_USER

if [[ -f "$AGENTCORE_FILE" && -z "$SYSTEM_MANAGER_OVERRIDE" ]]; then
	SVC_REMOVE_CMD="$AGENTCORE_FILE remove"
	captureInfo+="Executing: ${SVC_REMOVE_CMD}"$'\n'
	res=$(${SVC_REMOVE_CMD} 2>&1)
	EXIT_CODE=$?
	captureInfo+="Response: $res"$'\n'
	captureInfo+="Service remove completed with exit code: ${EXIT_CODE}"$'\n'
	
	# Additional delay required for initctl processes to stop completely 
	if [[ $processName == "init" ]]; then
		agent_pid_file="${BASE_DIR}/agent_inst/log/agent.pid"
		if [[ -f $agent_pid_file ]]; then
			agent_pid=$(grep 'pid='  $agent_pid_file | awk -F '=' '{print $2}')
			if ps -p $agent_pid > /dev/null; then
				captureInfo+="Daemon process is still running, waiting for 5s: $agent_pid"$'\n'
				sleep 5s
			fi
		fi
	fi
fi

UNPACK_DIR=${BASE_DIR}/zip/unpack

if [ -d "$UNPACK_DIR" ]; then
	captureInfo+="Cleanup unpack artifacts in: ${UNPACK_DIR}"$'\n'
	rm -rf "$UNPACK_DIR"
fi

if [[ "$DOCKER_USER_OVERRIDE" == "true" ]]; then
	INSTALL_CMD="$JAVAHOME/bin/java -Dpolyglot.engine.AllowExperimentalOptions=true -Dpolyglot.js.nashorn-compat=true ${INSTALLER_NATIVE_IMAGE_OPTIONS} -jar ${BASE_DIR}/zip/unpack/${MGMTAGENT_VERSION}/jlib/agent-install-${ARTIFACT_VERSION}.jar skipSteps=UnZipStep,UserStep agentBaseDir=${BASE_DIR} oracleHome=${ORACLE_HOME} agentStateDir=${BASE_DIR}/agent_inst"
else
	if [[ -z "$INSTALLER_LOG_LEVEL" ]]; then
		INSTALL_CMD="$JAVAHOME/bin/java -Dpolyglot.engine.AllowExperimentalOptions=true -Dpolyglot.js.nashorn-compat=true ${INSTALLER_NATIVE_IMAGE_OPTIONS} -jar ${BASE_DIR}/zip/unpack/${MGMTAGENT_VERSION}/jlib/agent-install-${ARTIFACT_VERSION}.jar skipSteps=UnZipStep agentBaseDir=${BASE_DIR} oracleHome=${ORACLE_HOME} agentStateDir=${BASE_DIR}/agent_inst user=$RUN_AGENT_AS_USER group=$AGENT_USER_GROUP"
	else
		INSTALL_CMD="$JAVAHOME/bin/java -Dpolyglot.engine.AllowExperimentalOptions=true -Dpolyglot.js.nashorn-compat=true ${INSTALLER_NATIVE_IMAGE_OPTIONS} -DInstaller.log.level=$INSTALLER_LOG_LEVEL -jar ${BASE_DIR}/zip/unpack/${MGMTAGENT_VERSION}/jlib/agent-install-${ARTIFACT_VERSION}.jar skipSteps=UnZipStep agentBaseDir=${BASE_DIR} oracleHome=${ORACLE_HOME} agentStateDir=${BASE_DIR}/agent_inst user=$RUN_AGENT_AS_USER group=$AGENT_USER_GROUP"
	fi
fi

# Use user home dir override if set (userHomeDirRoot)
if [ -n "$USER_HOME_DIR_ROOT" ]; then
	log "Override default user home ($USER_HOME_DIR_ROOT)" "\t%s\n"
	INSTALL_CMD="$INSTALL_CMD userHomeDirRoot=$USER_HOME_DIR_ROOT"
fi

log "Unpacking software zip" "\t%s\n"
captureInfo+="Executing $JAVAHOME/bin/java ${INSTALLER_NATIVE_IMAGE_OPTIONS} -jar ${BASE_DIR}/zip/zip_extractor/agent-unpack-${ARTIFACT_VERSION}.jar ${BASE_DIR}/zip/${INTERNAL_ZIP} ${BASE_DIR}/zip/unpack "$'\n'

$JAVAHOME/bin/java ${INSTALLER_NATIVE_IMAGE_OPTIONS} -jar ${BASE_DIR}/zip/zip_extractor/agent-unpack-${ARTIFACT_VERSION}.jar ${BASE_DIR}/zip/${INTERNAL_ZIP} ${BASE_DIR}/zip/unpack

captureInfo+="Executing ${INSTALL_CMD}"$'\n'

# During install, generate agent package details file before calling installer
if [[ $1 == 1 ]]; then
	generateAgentPackage
fi 

eval ${INSTALL_CMD}
						
installer_logs_path="${BASE_DIR}/installer-logs"
file="$installer_logs_path/installer.state.journal.SUCCESS"
rpmVersion="${BASE_DIR}/agent_inst/config/rpm.version"

if [ -f "$file" ]
then
	captureInfo+="$file found. Install successful."$'\n'
	
	# fix file owner and permissions
	chmod 750 $file
	chown $RUN_AGENT_AS_USER:$AGENT_USER_GROUP $file
	
	if [[ $BASH_SOURCE == *"rpm"* ]]; then
		captureInfo+="Updating rpm version in file $rpmVersion to $MGMTAGENT_VERSION."$'\n'
		echo $MGMTAGENT_VERSION > $rpmVersion
	
		chmod 750 $rpmVersion
		chown $RUN_AGENT_AS_USER:$AGENT_USER_GROUP $rpmVersion
	fi
else
	captureInfo+="$file not found. Install run into errors"$'\n'
	log "Check failure logs at $installer_logs_path" "\t%s\n"
	exit 1
fi

# set owner and exec bit for OPT_ORACLE_SYMLINK case
if [[ -h "$BASE_DIR" && "$OPT_ORACLE_SYMLINK" == "true" ]] ; then
	chown -h $RUN_AGENT_AS_USER:$AGENT_USER_GROUP "$BASE_DIR"
fi

# Persist override settings for install and upgrade
if [[ -n "$DIST_LINUX_FAMILY_OVERRIDE" ]]; then
  log "Saving setup environment settings" "\t%s\n"
  echo "DIST_LINUX_FAMILY_OVERRIDE=\"${DIST_LINUX_FAMILY_OVERRIDE}\"" > "${BIN_DIR}/setupEnvVars.sh"
  chown $RUN_AGENT_AS_USER:$AGENT_USER_GROUP "${BIN_DIR}/setupEnvVars.sh"
fi

# Skip daemon process creation if this flag is set
if [[ -z "$SYSTEM_MANAGER_OVERRIDE" ]]; then
	log "Creating ${SERVICE_NAME} daemon" "\t%s\n"
	SVC_INSTALL_CMD="${AGENTCORE_FILE} install"
	captureInfo+="Executing: ${SVC_INSTALL_CMD}"$'\n'
	res=$(${SVC_INSTALL_CMD} 2>&1)
	EXIT_CODE=$?
	captureInfo+="Service install completed with exit code: ${EXIT_CODE}"$'\n'
	
	if [ ${EXIT_CODE} -ne 0 ]; then 
		log "${SERVICE_NAME} service creation failed. Reason: $res" "\t\t%s\n"
		exit $EXIT_CODE
	fi
	
	if [[ ${distOs} == "solaris" ]]; then
		enableSolaris
	fi
fi

operation="install"
if [ $1 -gt 1 ]; then
	# its upgrade
	operation="upgrade"
	FILE=${BASE_DIR}/agent_inst/config/configure.required
	
	if [[ ! -f $FILE  && -z "$SYSTEM_MANAGER_OVERRIDE" ]]; then
		if [[ $isServiceEnabled == 0 ]]; then
			log "Starting ${SERVICE_NAME}" "\t%s\n"
			SVC_START_CMD="${AGENTCORE_FILE} start"
			res=$(${SVC_START_CMD} 2>&1)
			EXIT_CODE=$?
			captureInfo+="Service started with exit code: ${EXIT_CODE}"$'\n'
			if [ ${EXIT_CODE} -ne 0 ]; then 
				log "Failed to restart ${SERVICE_NAME} service after upgrades. Reason: $res" "\t\t%s\n"
				exit $EXIT_CODE
			fi
		else
			disableService
			captureInfo+="Service was disabled before upgrade, skipping agent restart."$'\n'
		fi
	fi	
fi	

log "Agent Install Logs: ${BASE_DIR}/installer-logs/installer.log.0" "\t%s\n"

# Configure is required only on fresh installs
if [ $1 = 1 ]; then

	generateStatusCheckScript
	
	# Don't print this during zip based installs
	if [[ $BASH_SOURCE == *"rpm"* ]]; then
		log "Post install step:"  "\n"
		
		log "Setup agent using input response file (run as any user with 'sudo' privileges)" "\t%s\n"
		log "Usage:" "\t%s\n"
		log "sudo ${BASE_DIR}/agent_inst/bin/setup.sh opts=[FULL_PATH_TO_INPUT.RSP] " "\t\t%s\n"
	fi
fi

log "Agent $operation successful" "\n%s"

echo $'\n'
echo `date -u` >> "$LOGFILE" 
echo "$captureInfo" >> "$LOGFILE" 
 
exit ${EXIT_CODE}

