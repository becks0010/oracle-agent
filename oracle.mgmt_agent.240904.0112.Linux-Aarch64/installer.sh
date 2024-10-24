#! /bin/bash
set -e

# ######################################################################################
#
# Copyright (c) 2021, Oracle and/or its affiliates. All rights reserved.
#
# Installer script for Management Agent
# Usage:  installer.sh [Path-to-input.rsp/-u]
#						- Path-to-input.rsp: Full path to input.rsp file
#						- Path-to-input.rsp: Full path to input.rsp file, service-name
#						- u: Upgrade flag to specify agent upgrade
# ######################################################################################

# Set default locale
export LC_ALL=C

if [ ! "$BASH_VERSION" ] ; then
    echo "Unsupported shell: please execute as /bin/bash $0 or invoke it directly as ./$0"
    exit 1
fi

# In docker user may pass UID/GID to override default mgmt_agent user
DOCKER_USER_OVERRIDE=${DOCKER_USER_OVERRIDE:-false}

if [[ $EUID -ne 0 && "$DOCKER_USER_OVERRIDE" == "false" ]]; then
   echo "This script must be executed as root" 
   exit 1
fi

CURRENT_DIR=$(dirname "$0")
INSTALL_PARENT_DIR="/opt/oracle"

if [[ "$DOCKER_USER_OVERRIDE" == "true" ]]; then
	INSTALL_PARENT_DIR=${DOCKER_BASE_DIR:-${PWD}}
fi

SERVICE_NAME="mgmt_agent"
INSTALL_BASE_DIR="${INSTALL_PARENT_DIR}/${SERVICE_NAME}"
STATE_DIR="${INSTALL_BASE_DIR}/agent_inst"
ZIP_DIR="${INSTALL_BASE_DIR}/zip/"

# /opt/oracle/mgmt_agent to preexist as a symlink
OPT_ORACLE_SYMLINK=${OPT_ORACLE_SYMLINK:-false}

IS_UPGRADE="false"
SETUP_OPTS=""

###########################################################
# Update parameters required to install/upgrade agent
# Input: service-name
function update_service_params() {
  SERVICE_NAME="$1"
  INSTALL_BASE_DIR="${INSTALL_PARENT_DIR}/${SERVICE_NAME}"
  STATE_DIR="${INSTALL_BASE_DIR}/agent_inst"
  ZIP_DIR="${INSTALL_BASE_DIR}/zip/"
}

###########################################################
# Display help and exit script
function show_usage() {
  printf "Usage:  installer.sh <Path-to-input.rsp/-u> [service-name]"
  printf "\n\t - to install: installer.sh <Full path to input.rsp file>"
  printf "\n\t - to install with service name: installer.sh <Full path to input.rsp file> <service name>"
  printf "\n\t - to upgrade: installer.sh -u"
  printf "\n\t - to upgrade with service name: installer.sh -u <service name>\n"
  exit 1
}

###########################################################
# Check if multiple agent installs exist
# Returns: 0 if exists, otherwise 1
function is_multiagents_present() {
  local childcount=0
  local dirpath="${INSTALL_PARENT_DIR}"
  for child in "$dirpath"/* ; do
  	if [[ -d "${child}" ]] && [[ "${child##*/}" =~ ^mgmt_agent.*$ ]]; then
  		childcount=$(($childcount+1))
  		if [ $childcount -gt 1 ]; then
  		  return 0
  		fi
  	fi
  done
  return 1
}

###########################################################
# Validate service name starts with mgmt_agent and contains
# alpha-numeric characters with hyphen & underscore allowed
# Input: mgmt_agent-abc-123_xyz
# Returns: 0 if valid, otherwise exits script with error
function validate_servicename() {
  local svcname=$1
  if ! [[ "${svcname}" =~ ^"mgmt_agent"-.+$ ]]; then
  	echo "Service name must be of the format mgmt_agent-<alphanumeric_value>, exiting ..."
  	show_usage
  fi

  # alphanumeric with hyphen, and underscore allowed
  if ! [[ "${svcname}" =~ ^[a-zA-Z0-9_-]+$ ]]; then
  	echo "Service name may only contain alphanumeric characters with hyphen and underscore, exiting ..."
  	show_usage
  fi
}

###########################################################
# Copy install artifacts to staging dir (./zip)
function setup_files() {
  mkdir -p ${INSTALL_BASE_DIR}/zip
  cp -r ${CURRENT_DIR}/zip/* ${INSTALL_BASE_DIR}/zip/
}

###########################################################
# Execute agent install flow. If SYSTEM_MANAGER_OVERRIDE is
# set then only configure otherwise full install
function exec_install_agent() {
  if [[ ${SETUP_OPTS} == "" ]]; then
    echo "Missing mandatory input response file"
    show_usage
  fi
	
  if [[ -d ${INSTALL_BASE_DIR} && "${OPT_ORACLE_SYMLINK}" == "false" ]] ; then
    echo "Please un-install the previous agent or try upgrading"
    show_usage
  fi
  
  if [[ ! -h ${INSTALL_BASE_DIR} && "${OPT_ORACLE_SYMLINK}" == "true" ]] ; then
    echo "${INSTALL_BASE_DIR} must be a Symlink if OPT_ORACLE_SYMLINK==true"
    show_usage
  fi
	
  # It's fresh install send flag 1
  /bin/bash ${CURRENT_DIR}/preinstallscript.sh 1 ${SERVICE_NAME}
	
  setup_files
	
  /bin/bash ${CURRENT_DIR}/postinstallscript.sh 1 ${SERVICE_NAME}
	
  if [[ -z "$SYSTEM_MANAGER_OVERRIDE" ]]; then
    /bin/bash ${STATE_DIR}/bin/setup.sh opts=${SETUP_OPTS}
  else
    /bin/bash ${STATE_DIR}/bin/setup.sh opts=${SETUP_OPTS} --configureOnly
  fi
}

###########################################################
# Execute agent upgrade flow.
function exec_upgrade_agent() {
  if [[ ! -d ${INSTALL_BASE_DIR} ]]; then
    echo "Please install the agent before trying to upgrade"
    show_usage
  fi
	
  setup_files
	
  # It's a upgrade send flag > 1
  /bin/bash ${CURRENT_DIR}/preinstallscript.sh 2 ${SERVICE_NAME}
	
  /bin/bash ${CURRENT_DIR}/postinstallscript.sh 2 ${SERVICE_NAME}
}


if [[ $1 == "-u" ]]; then
  IS_UPGRADE="true"
elif [[ -f "$1" ]]; then
  SETUP_OPTS=$1
else
  echo "Invalid argument: $1"
  show_usage
fi

# optional second arg to specify service name used for multi-agent installs
if [[ $# -eq 2 ]]; then
  # validate given name for installs only
  if [[ ${IS_UPGRADE} == "false" ]]; then
    validate_servicename "$2"
  fi
  update_service_params "$2"
else
  # check multiagent exist on upgrade if service name is not given
  if [[ ${IS_UPGRADE} == "true" ]]; then
    if is_multiagents_present ; then
      echo "Multiple instances of Management Agent exist, service name is required to upgrade"
      show_usage
    fi
  fi
fi

if [[ ${IS_UPGRADE} == "false" ]]; then
  exec_install_agent
else
  exec_upgrade_agent
fi
