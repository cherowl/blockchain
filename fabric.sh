#!/bin/bash

[ -z "$BASE_DIR" ] && pushd ${0%/*}/../ >/dev/null && BASE_DIR=$PWD && popd >/dev/null

CRYPTO_CONFIG_FILE=crypto-config.yaml
CONFIGTX_FILE=configtx.yaml
DOCKER_COMPOSE_FILE=docker-compose.yaml

CRYPTO_CONFIG_DIR=./crypto-config
CHANNEL_ARTIFACTS_DIR=./channel-artifacts
CHAINCODE_DIR=./chaincode

CA_ORG_CA_DIR=/etc/hyperledger/fabric-ca-server-config

CLI_CRYPTO_CONFIG_DIR=/opt/gopath/src/github.com/hyperledger/fabric/peer/crypto
CLI_WORKING_DIR=/opt/gopath/src/github.com/hyperledger/fabric/peer
CLI_CHANNEL_ARTIFACTS_DIR=$CLI_WORKING_DIR/channel-artifacts
CLI_CHAINCODE_DIR=/opt/gopath/src/github.com/chaincode
CLI_ORDERER_TLSCA() {
	echo $CLI_CRYPTO_CONFIG_DIR/ordererOrganizations/$BL_DOMAIN/orderers/orderer.$BL_DOMAIN/tls/ca.crt
}
CLI_PEER_TLSCA() {
	eval "local org_info=(\$ORG${2}_INFO)"
	echo $CLI_CRYPTO_CONFIG_DIR/peerOrganizations/${org_info[1]}/peers/peer$1.${org_info[1]}/tls/ca.crt
}

ORDERER_PORT=7050
PEER_PORT=7051  #,7053
CA_PORT=7054
COUCHDB_PORT=5984

DEFAULT_CONFIG_FILE=$BASE_DIR/config/default

#{{{ tools
SSH="ssh -q -o PasswordAuthentication=no -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o ServerAliveInterval=10 -o ConnectTimeout=10"
SCP="scp -q -o PasswordAuthentication=no -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o ServerAliveInterval=10 -o ConnectTimeout=10"

HLMSG=$'\x1b'"[1;32m"
HLWAR=$'\x1b'"[1;35m"
HLERR=$'\x1b'"[1;31m"
HLEND=$'\x1b'"[0m"

# $* : [ARG_OF_echo] MSG
msg()
{
	local arg
	[ "$1" != "${1#-}" ] && { arg=$1; shift; }
	echo $arg "$HLMSG$1$HLEND"
}
warn()
{
	local arg
	[ "$1" != "${1#-}" ] && { arg=$1; shift; }
	echo $arg "$HLWAR$1$HLEND"
}
err()
{
	local arg
	[ "$1" != "${1#-}" ] && { arg=$1; shift; }
	echo $arg "$HLERR[error] $1$HLEND"
}
is_local_addr()
{
	local check=$1 x
	local ip
	[ -n "${check//[0-9.]}" ] && read check x < <(getent hosts $check)

	for ip in `/sbin/ifconfig | sed -n 's/ *inet addr:\([0-9\.]*\) .*/\1/p'` ; do
    	[ "$check" = "$ip" ] && return 0
	done
	return 1
}
# [IP] command...
run_cmd()
{
	local i arg cmd var val exports
	local ret=0
	local ip ips=${1:-127.0.0.1}
	shift

	for ((i=1;i<=$#;i++)) ; do
    	eval arg="\$$i"
    	cmd="$cmd${cmd:+ }\"$arg\""
	done

	for ip in ${ips//,/ } ; do
    	warn "    	=== run_cmd @$ip: $cmd" >&2
    	if is_local_addr $ip ; then
        	eval "$cmd"
        	((ret|=$?))
    	else
        	exports="REMOTED=y SITE_ID=$ip"
        	while read var ; do
            	[ -z "$var" -o "$var" != "${var#\#}" ] && continue
            	var=${var%%=*}
            	eval val="\$$var"
            	exports="$exports${exports:+ }$var=\"$val\""
        	done < <(sed -n '/^#remoted begin/,/^#remoted end/p' $TESTER_SH)

        	$SSH $SSH_USER${SSH_USER:+@}$ip "$exports $cmd"
        	((ret|=$?))
    	fi
	done
	return $ret
}

# path [u@ip:]path
cp_file()
{
	local cmd ip i arg
	local remote=false

	for i in 1 2 ; do
    	eval "arg=\$$i"

    	if [ "$arg" != "${arg/:}" ] ; then
        	ip=${arg%:*}
        	ip=${ip#*@}
        	[ "$ip" = localhost ] && ip=127.0.0.1
        	is_local_addr $ip && arg=${arg#*:} || remote=true
    	fi
    	cmd="$cmd${cmd:+ }\"$arg\""
	done

	if $remote ; then
    	eval "$SCP $cmd"
	else
    	eval "cp -f $cmd"
	fi
}

REG_OVERRIDING=
reg_overriding()
{
	local p r
	for p in $* ; do
    	for r in $REG_OVERRIDING "" ; do
        	[ "$r" = "$p" ] && break
    	done
    	[ -z "$r" ] && REG_OVERRIDING="$REG_OVERRIDING${REG_OVERRIDING:+ }$p"
	done
}
overriding()
{
	local f=${1##*/}
	local n=${f%.sh}
	[ -z "$n" ] && return 1
	shift

	local os=${OSTYPE%%-*}
	local dir=${BASH_SOURCE%/*}
	local reg

	if [ -f $dir/$f ] ; then
    	[ -f $dir/$n.$os   	] && . $dir/$n.$os
    	[ -f $dir/$n.server	] && . $dir/$n.server
    	[ -f $dir/$n.client	] && . $dir/$n.client
    	for reg in $REG_OVERRIDING ; do
    	[ -f $dir/$n.$reg  	] && . $dir/$n.$reg
    	done
	else
    	local ret=0
    	local handled=0
    	[ "`type -t $n.$os  	`" = function ] && { $n.$os   	$*; ((ret|=$?)); handled=1; }
    	[ "`type -t $n.server   `" = function ] && { run_function $TEST_SERVER \
                                                 	$n.server	$*; ((ret|=$?)); handled=1; }
    	[ "`type -t $n.client   `" = function ] && { run_function $TEST_CLIENT \
                                                 	$n.client	$*; ((ret|=$?)); handled=1; }
    	for reg in $REG_OVERRIDING ; do
    	[ "`type -t $n.$reg 	`" = function ] && { $n.$reg  	$*; ((ret|=$?)); handled=1; }
    	done

    	[ $handled -eq 0 ] && return 0
    	return $ret
	fi
}

deploy_script()
{
	local ips ip client arg

	for arg in $* ; do
    	case $arg in
    	--ip=?*)
        	ips=${arg#*=}
        	;;
    	esac
	done

	[ -z "$ips" ] && {
    	ips=${TEST_SERVER//,/ }
    	for ((client=1; client<=CLIENT_COUNT; client++)) ; do
        	eval "ips=\"\$ips \${CLIENT_${client}_IP}\""
    	done
	}

	for ip in $ips ; do
    	cp_file $0 $SSH_USER@$ip:/tmp/ || {
        	err "$LINENO: cannot deploy test script to $ip"
        	return 1
    	}
    	eval "SH_DEPLOYED_${ip//./_}=yes"
	done
	return 0
}

# ip func param
run_function()
{
	local i arg cmd
	local ip ips=$1
	local ret=0

	shift

	for ((i=1;i<=$#;i++)) ; do
    	eval arg="\$$i"
    	cmd="$cmd${cmd:+ }\"$arg\""
	done

	for ip in ${ips//,/ } ; do

    	if is_local_addr $ip ; then
        	eval "$cmd"
    	else
        	eval "[ -z \"\$SH_DEPLOYED_${ip//./_}\" ]" && {
            	deploy_script --ip=$ip || {
                	err "$LINENO: cannot deploy test script to $ip!" >&2
                	return 1
            	}
        	}

        	eval "run_cmd $ip /tmp/$TESTER_SH $cmd"
    	fi
    	((ret|=$?))
	done

	return $ret
}
#}}}

################################################################################

# $1 type, $2/3 index, e.g. peer0.org1 : peer 0 1
get_ext_port()
{ #{{{
	local host docker dockers
	local peer org type
	local -A ports

	for ((host=1; host<=HOSTS; host ++)) ; do
    	ports[orderer]=$ORDERER_PORT
    	ports[peer]=$PEER_PORT
    	ports[ca]=$CA_PORT
    	ports[couchdb]=$COUCHDB_PORT

    	eval "dockers=\$HOST${host}_DOCKERS"
    	for docker in $dockers ; do
        	type=${docker%%[0-9.]*}
        	case $type in
        	orderer)
            	;;
        	peer|couchdb)
            	peer=${docker%%.*}
            	peer=${peer##*[^0-9]}
            	org=${docker##*.}
            	org=${org##*[^0-9]}
            	[ "$1" = $type -a "$peer" = "$2" -a "$org" = "$3" ] && {
                	echo ${ports[$type]}
                	return
            	}
            	ports[$type]=$((ports[$type]+1000))
            	;;
        	ca)
            	org=${docker##*.}
            	org=${org##*[^0-9]}
            	[ "$1" = $type -a "$org" = "$2" ] && {
                	echo ${ports[$type]}
                	return
            	}
            	ports[$type]=$((ports[$type]+1000))
            	;;
        	esac
    	done
	done
	echo ${ports[$1]}
} #}}}

# $1 type, $2/3 index, e.g. peer0.org1 : peer 0 1
get_domain_name()
{ #{{{
	case $1 in
	orderer|cli)
    	echo $1.$BL_DOMAIN
    	;;
	peer|couchdb)
    	eval "local org_info=(\$ORG${3}_INFO)"
    	echo $1$2.${org_info[1]}
    	;;
	ca)
    	eval "local org_info=(\$ORG${2}_INFO)"
    	echo $1.${org_info[1]}
    	;;
	esac
} #}}}

# $1 type, $2/3 index, e.g. peer0.org1 : peer 0 1
get_host_id()
{ #{{{
	local host docker dockers
	local peer org type

	for ((host=1; host<=HOSTS; host ++)) ; do

    	eval "dockers=\$HOST${host}_DOCKERS"
    	for docker in $dockers ; do
        	type=${docker%%[0-9.]*}

        	case $type in
        	orderer|cli)
            	[ "$1" = $type ] && {
                	echo $host
                	return
            	}
            	;;
        	peer|couchdb)
            	peer=${docker%%.*}
            	peer=${peer##*[^0-9]}
            	org=${docker##*.}
            	org=${org##*[^0-9]}
            	[ "$1" = $type -a "$peer" = "$2" -a "$org" = "$3" ] && {
                	echo $host
                	return
            	}
            	;;
        	ca)
            	org=${docker##*.}
            	org=${org##*[^0-9]}
            	[ "$1" = $type -a "$org" = "$2" ] && {
                	echo $host
                	return
            	}
            	;;
        	esac
    	done
	done
	return 1
} #}}}

# $1: from node, $2: to node
get_connect_port()
{ #{{{
	local from_host=`get_host_id $1`
	local to_host=`get_host_id $2`

	[ $NETWORK_MODE != swarm -a $from_host != $to_host ] && {
    	get_ext_port $2
    	return
	}
	local type=${2%% *}
	eval "echo \$${type^^}_PORT"
} #}}}

# $1: channel number, $2: token
get_channel_info()
{
	local val
	eval "val=\$CHANNEL${1}_${2}"
	[ -z "$val" ] &&
	eval "val=\$CHANNELx_${2}"
	val=${val//\{x\}/$1}
	echo "$val"
}

check()
{ #{{{

	# check fabric installing
	which configtxlator >/dev/null || {
    	err "Hyperledger fabric not detected!"
    	err "	please install hyperledger fabric and set fabric-samples/bin to PATH."
    	err "	version of installed hyperledger fabric would be also used for docker image."
    	exit 1
	}

	[ $NETWORK_MODE = swarm ] && {
    	if docker node list >/dev/null 2>&1 ; then
        	local net_info=`docker network list | sed -n "/.* $NETWORK_NAME  *overlay  *swarm$/p"`
        	[ -z "$net_info" ] && {
            	docker network create --attachable --driver overlay $NETWORK_NAME || {
                	err "create swarm network failed!"
                	exit 1
            	}
        	}
    	else
        	local net_info=`docker network list | sed -n "/.* $NETWORK_NAME  *overlay  *swarm$/p"`
        	[ -z "$net_info" ] && docker run -d --rm --net=$NETWORK_NAME hyperledger/fabric-baseos sleep 60 >/dev/null 2>&1

        	net_info=`docker network list | sed -n "/.* $NETWORK_NAME  *overlay  *swarm$/p"`
        	[ -z "$net_info" ] && {
            	err "swarm network not detected, swarm need to be setup!"
            	exit 1
        	}
    	fi
	}

	FABRIC_VERSION=`configtxlator version | sed -ne 's/^ *Version: //p'`
	msg "Hyperledger fabric version $FABRIC_VERSION detected in the system, this version will be used!"
} #}}}

################################################################################

gen_crypto_config()
{ #{{{
	local org org_info

	cat >$CRYPTO_CONFIG_FILE <<EOF
OrdererOrgs:
  - Name: Orderer
	Domain: $BL_DOMAIN
	Specs:
  	- Hostname: orderer

PeerOrgs:
EOF

	for ((org=1; org<=ORGS; org++)) ; do
    	eval "org_info=(\$ORG${org}_INFO)"

    	cat >>$CRYPTO_CONFIG_FILE <<EOF
  - Name: ${org_info[0]}
	Domain: ${org_info[1]}
	EnableNodeOUs: true
	Template:
  	Count: ${org_info[2]}
	Users:
  	Count: ${org_info[3]}
EOF
	done
} #}}}

gen_configtx()
{ #{{{
	local org org_info ch ch_profile ch_name
	local maj mnr

	maj=${FABRIC_VERSION%%.*}
	mnr=${FABRIC_VERSION#*.}
	mnr=${mnr%%.*}

	cat >$CONFIGTX_FILE <<EOF
---
Organizations:
	- &OrdererOrg
    	Name: OrdererOrg
    	ID: OrdererMSP
    	MSPDir: $CRYPTO_CONFIG_DIR/ordererOrganizations/$BL_DOMAIN/msp
    	Policies:
        	Readers:
            	Type: Signature
            	Rule: "OR('OrdererMSP.member')"
        	Writers:
            	Type: Signature
            	Rule: "OR('OrdererMSP.member')"
        	Admins:
            	Type: Signature
            	Rule: "OR('OrdererMSP.admin')"
EOF

	for ((org=1; org<=ORGS; org++)) ; do
    	eval "org_info=(\$ORG${org}_INFO)"
    	cat >>$CONFIGTX_FILE <<EOF

	- &${org_info[0]}
    	Name: ${org_info[0]}MSP
    	ID: ${org_info[0]}MSP
    	MSPDir: $CRYPTO_CONFIG_DIR/peerOrganizations/${org_info[1]}/msp

    	Policies:
        	Readers:
            	Type: Signature
            	Rule: "OR('${org_info[0]}MSP.admin', '${org_info[0]}MSP.peer', '${org_info[0]}MSP.client')"
        	Writers:
            	Type: Signature
            	Rule: "OR('${org_info[0]}MSP.admin', '${org_info[0]}MSP.client')"
        	Admins:
            	Type: Signature
            	Rule: "OR('${org_info[0]}MSP.admin')"

    	AnchorPeers:
        	- Host: peer0.${org_info[1]}
          	Port: 7051
EOF
	done

	cat >>$CONFIGTX_FILE <<EOF
Capabilities:
	Channel: &ChannelCapabilities
    	V${maj}_${mnr}: true

	Orderer: &OrdererCapabilities
    	V1_1: true

	Application: &ApplicationCapabilities
    	V${maj}_${mnr}: true

Application: &ApplicationDefaults
	Organizations:
	Policies:
    	Readers:
        	Type: ImplicitMeta
        	Rule: "ANY Readers"
    	Writers:
        	Type: ImplicitMeta
        	Rule: "ANY Writers"
    	Admins:
        	Type: ImplicitMeta
        	Rule: "MAJORITY Admins"

Orderer: &OrdererDefaults
	OrdererType: $ORDERER_TYPE
	Addresses:
    	- orderer.${BL_DOMAIN}:$ORDERER_PORT
	BatchTimeout: 2s
	BatchSize:
    	MaxMessageCount: 10
    	AbsoluteMaxBytes: 99 MB
    	PreferredMaxBytes: 512 KB
	Kafka:
    	Brokers:
        	- 127.0.0.1:9092
	Organizations:
	Policies:
    	Readers:
        	Type: ImplicitMeta
        	Rule: "ANY Readers"
    	Writers:
        	Type: ImplicitMeta
        	Rule: "ANY Writers"
    	Admins:
        	Type: ImplicitMeta
        	Rule: "MAJORITY Admins"
    	BlockValidation:
        	Type: ImplicitMeta
        	Rule: "ANY Writers"

Channel: &ChannelDefaults
	Policies:
    	Readers:
        	Type: ImplicitMeta
        	Rule: "ANY Readers"
    	Writers:
        	Type: ImplicitMeta
        	Rule: "ANY Writers"
    	Admins:
        	Type: ImplicitMeta
        	Rule: "MAJORITY Admins"
	Capabilities:
    	<<: *ChannelCapabilities

Profiles:
	$ORDERER_GENESIS_PROFILE:
    	<<: *ChannelDefaults
    	Orderer:
        	<<: *OrdererDefaults
        	Organizations:
            	- *OrdererOrg
        	Capabilities:
            	<<: *OrdererCapabilities
    	Consortiums:
        	$CONSORTIUM_NAME:
            	Organizations:
EOF
	for ((org=1; org<=ORGS; org++)) ; do
    	eval "org_info=(\$ORG${org}_INFO)"
    	cat >>$CONFIGTX_FILE <<EOF
                	- *${org_info[0]}
EOF
	done

	for ((ch=1; ch<=CHANNELS; ch++)) ; do
    	ch_profile=`get_channel_info ${ch} PROFILE`
    	ch_name=`get_channel_info ${ch} NAME`

    	cat >>$CONFIGTX_FILE <<EOF
	$ch_profile:
    	Consortium: $CONSORTIUM_NAME
    	Application:
        	<<: *ApplicationDefaults
        	Organizations:
EOF

    	for ((org=1; org<=ORGS; org++)) ; do
        	eval "org_info=(\$ORG${org}_INFO)"
        	cat >>$CONFIGTX_FILE <<EOF
            	- *${org_info[0]}
EOF
    	done

    	cat >>$CONFIGTX_FILE <<EOF
        	Capabilities:
            	<<: *ApplicationCapabilities

EOF
	done
} #}}}

# $1 : exclusive host, $2 : indent
gen_extra_host()
{ #{{{
	[ $NETWORK_MODE = swarm ] && return

	local exclusive=$1 indent=$2
	local host docker dockers
	local peer org type ip
	local output

	for ((host=1; host<=HOSTS; host ++)) ; do
    	[ $host = $exclusive ] && continue
    	eval "dockers=\$HOST${host}_DOCKERS"
    	eval "ip=\$HOST${host}_IP"
    	for docker in $dockers ; do
        	type=${docker%%[0-9.]*}
        	case $type in
        	orderer|cli)
            	output="$output$indent  - \"`get_domain_name $type $peer $org`:$ip\""$'\n'
            	;;
        	peer|couchdb)
            	peer=${docker%%.*}
            	peer=${peer##*[^0-9]}
            	org=${docker##*.}
            	org=${org##*[^0-9]}
            	output="$output$indent  - \"`get_domain_name $type $peer $org`:$ip\""$'\n'
            	;;
        	ca)
            	org=${docker##*.}
            	org=${org##*[^0-9]}
            	output="$output$indent  - \"`get_domain_name $type $org`:$ip\""$'\n'
            	;;
        	esac
    	done
	done
	[ -n "$output" ] && output="extra_hosts:"$'\n'"$output"
	echo "$output"
} #}}}

# $1 : indent
gen_networks_global()
{ #{{{
	local indent=$1
	[ $NETWORK_MODE != swarm ] && {
    	echo $NETWORK_NAME:
	} || {
    	echo mhnw:
    	echo "$indent  "external:
    	echo "$indent	"name: $NETWORK_NAME
	}
} #}}}

# $1 : container, $2 : indent
gen_networks_container()
{ #{{{
	local cn=$1 indent=$2
	[ $NETWORK_MODE != swarm ] && {
    	echo "- $NETWORK_NAME"
	} || {
    	echo mhnw:
    	echo "$indent  "aliases:
    	echo "$indent	- $cn"
	}
} #}}}

gen_docker_compose_file()
{ #{{{
	local peer org org_info next_peer peer_ext_port couchdb_ext_port

	cat >$DOCKER_COMPOSE_FILE <<EOF
version: '2'

networks:
  `gen_networks_global "  "`

services:

  orderer.${BL_DOMAIN}:
	container_name: orderer.${BL_DOMAIN}
	image: hyperledger/fabric-orderer:$FABRIC_VERSION
	environment:
  	- ORDERER_GENERAL_LOGLEVEL=INFO
  	- ORDERER_GENERAL_LISTENADDRESS=0.0.0.0
  	- ORDERER_GENERAL_GENESISMETHOD=file
  	- ORDERER_GENERAL_GENESISFILE=/var/hyperledger/orderer/orderer.genesis.block
  	- ORDERER_GENERAL_LOCALMSPID=OrdererMSP
  	- ORDERER_GENERAL_LOCALMSPDIR=/var/hyperledger/orderer/msp
  	# enabled TLS
  	- ORDERER_GENERAL_TLS_ENABLED=true
  	- ORDERER_GENERAL_TLS_PRIVATEKEY=/var/hyperledger/orderer/tls/server.key
  	- ORDERER_GENERAL_TLS_CERTIFICATE=/var/hyperledger/orderer/tls/server.crt
  	- ORDERER_GENERAL_TLS_ROOTCAS=[/var/hyperledger/orderer/tls/ca.crt]
	working_dir: /opt/gopath/src/github.com/hyperledger/fabric
	command: orderer
	volumes:
  	- $CHANNEL_ARTIFACTS_DIR/genesis.block:/var/hyperledger/orderer/orderer.genesis.block
  	- $CRYPTO_CONFIG_DIR/ordererOrganizations/$BL_DOMAIN/orderers/orderer.$BL_DOMAIN/msp:/var/hyperledger/orderer/msp
  	- $CRYPTO_CONFIG_DIR/ordererOrganizations/$BL_DOMAIN/orderers/orderer.$BL_DOMAIN/tls/:/var/hyperledger/orderer/tls
  	- /var/hyperledger/production/orderer
	ports:
  	- `get_ext_port orderer`:$ORDERER_PORT
	networks:
  	`gen_networks_container orderer.${BL_DOMAIN} "  	"`
	`gen_extra_host $(get_host_id orderer) "	"`

EOF

	for ((org=1; org<=ORGS; org++)) ; do
    	eval "org_info=(\$ORG${org}_INFO)"

    	for ((peer=0; peer < org_info[2]; peer ++)) ; do
        	next_peer=$((peer+1==org_info[2]?0:peer+1))
        	peer_ext_port=`get_ext_port peer $peer $org`
        	couchdb_ext_port=`get_ext_port couchdb $peer $org`

        	cat >>$DOCKER_COMPOSE_FILE <<EOF
  couchdb$peer.${org_info[1]}:
	container_name: couchdb$peer.${org_info[1]}
	image: hyperledger/fabric-couchdb
	environment:
  	- COUCHDB_USER=
  	- COUCHDB_PASSWORD=
	ports:
  	- "$couchdb_ext_port:$COUCHDB_PORT"
	networks:
  	`gen_networks_container couchdb$peer.${org_info[1]} "    	"`

  peer$peer.${org_info[1]}:
	container_name: peer$peer.${org_info[1]}
	image: hyperledger/fabric-peer:$FABRIC_VERSION
	environment:
  	- CORE_PEER_ID=peer$peer.${org_info[1]}
  	- CORE_PEER_ADDRESS=peer$peer.${org_info[1]}:$PEER_PORT
  	- CORE_PEER_GOSSIP_EXTERNALENDPOINT=peer$peer.${org_info[1]}:$PEER_PORT
  	- CORE_PEER_GOSSIP_BOOTSTRAP=peer${next_peer}.${org_info[1]}:`get_connect_port "peer $peer $org" "peer $next_peer $org"`
  	- CORE_PEER_LOCALMSPID=${org_info[0]}MSP
  	#
  	- CORE_VM_ENDPOINT=unix:///host/var/run/docker.sock
  	#- CORE_VM_DOCKER_HOSTCONFIG_NETWORKMODE=\${COMPOSE_PROJECT_NAME}_$NETWORK_NAME
  	- CORE_VM_DOCKER_HOSTCONFIG_NETWORKMODE=$NETWORK_NAME
  	- CORE_LOGGING_LEVEL=INFO
  	- CORE_PEER_TLS_ENABLED=$PEER_TLS_ENABLED
  	- CORE_PEER_GOSSIP_USELEADERELECTION=true
  	- CORE_PEER_GOSSIP_ORGLEADER=false
  	- CORE_PEER_PROFILE_ENABLED=true
  	- CORE_PEER_TLS_CERT_FILE=/etc/hyperledger/fabric/tls/server.crt
  	- CORE_PEER_TLS_KEY_FILE=/etc/hyperledger/fabric/tls/server.key
  	- CORE_PEER_TLS_ROOTCERT_FILE=/etc/hyperledger/fabric/tls/ca.crt
  	#
  	- CORE_LEDGER_STATE_STATEDATABASE=CouchDB
  	- CORE_LEDGER_STATE_COUCHDBCONFIG_COUCHDBADDRESS=couchdb$peer.${org_info[1]}:`get_connect_port "peer $peer $org" "couchdb $peer $org"`
  	- CORE_LEDGER_STATE_COUCHDBCONFIG_USERNAME=
  	- CORE_LEDGER_STATE_COUCHDBCONFIG_PASSWORD=
	working_dir: /opt/gopath/src/github.com/hyperledger/fabric/peer
	command: peer node start
	volumes:
    	- /var/run/:/host/var/run/
    	- $CRYPTO_CONFIG_DIR/peerOrganizations/${org_info[1]}/peers/peer$peer.${org_info[1]}/msp:/etc/hyperledger/fabric/msp
    	- $CRYPTO_CONFIG_DIR/peerOrganizations/${org_info[1]}/peers/peer$peer.${org_info[1]}/tls:/etc/hyperledger/fabric/tls
    	- /var/hyperledger/production
	ports:
  	- $peer_ext_port:$PEER_PORT
  	- $((peer_ext_port+2)):$((PEER_PORT+2))
	networks:
  	`gen_networks_container peer$peer.${org_info[1]} "    	"`
	`gen_extra_host $(get_host_id peer $peer $org) "	"`
	depends_on:
  	- couchdb$peer.${org_info[1]}

EOF
    	done
	done

	for ((org=1; org<=ORGS; org++)) ; do
    	eval "org_info=(\$ORG${org}_INFO)"
    	local ca_root_cert_file=`echo $CRYPTO_CONFIG_DIR/peerOrganizations/${org_info[1]}/ca/*.pem`
    	local ca_priv_key_file=`echo $CRYPTO_CONFIG_DIR/peerOrganizations/${org_info[1]}/ca/*_sk`

    	cat >>$DOCKER_COMPOSE_FILE <<EOF
  ca.${org_info[1]}:
	image: hyperledger/fabric-ca:$FABRIC_VERSION
	environment:
  	- FABRIC_CA_HOME=/etc/hyperledger/fabric-ca-server
  	- FABRIC_CA_SERVER_CA_NAME=ca.${org_info[1]}
  	- FABRIC_CA_SERVER_TLS_ENABLED=true
  	- FABRIC_CA_SERVER_TLS_CERTFILE=$CA_ORG_CA_DIR/${ca_root_cert_file##*/}
  	- FABRIC_CA_SERVER_TLS_KEYFILE=$CA_ORG_CA_DIR/${ca_priv_key_file##*/}
	ports:
  	- "`get_ext_port ca $org`:$CA_PORT"
	command: sh -c 'fabric-ca-server start --ca.certfile $CA_ORG_CA_DIR/${ca_root_cert_file##*/} --ca.keyfile $CA_ORG_CA_DIR/${ca_priv_key_file##*/} -b admin:adminpw -d'
	volumes:
  	- $CRYPTO_CONFIG_DIR/peerOrganizations/${org_info[1]}/ca/:$CA_ORG_CA_DIR
  	- ./config/fabric-ca-server-config.yaml:/etc/hyperledger/fabric-ca-server/fabric-ca-server-config.yaml
	container_name: ca.${org_info[1]}
	networks:
  	`gen_networks_container ca.${org_info[1]} "    	"`
	`gen_extra_host $(get_host_id ca $org) "	"`

EOF
	done

	org_info=($ORG1_INFO)

	cat >>$DOCKER_COMPOSE_FILE <<EOF
  cli.${BL_DOMAIN}:
	container_name: cli.${BL_DOMAIN}
	image: hyperledger/fabric-tools:$FABRIC_VERSION
	tty: true
	stdin_open: true
	environment:
  	- GOPATH=/opt/gopath
  	- CORE_VM_ENDPOINT=unix:///host/var/run/docker.sock
  	- CORE_LOGGING_LEVEL=INFO
  	- CORE_PEER_ID=cli
  	- CORE_PEER_ADDRESS=peer0.${org_info[1]}:`get_connect_port "cli" "peer 0 1"`
  	- CORE_PEER_LOCALMSPID=${org_info[0]}MSP
  	- CORE_PEER_TLS_ENABLED=$PEER_TLS_ENABLED
  	- CORE_PEER_TLS_CERT_FILE=$CLI_CRYPTO_CONFIG_DIR/peerOrganizations/${org_info[1]}/peers/peer0.${org_info[1]}/tls/server.crt
  	- CORE_PEER_TLS_KEY_FILE=$CLI_CRYPTO_CONFIG_DIR/peerOrganizations/${org_info[1]}/peers/peer0.${org_info[1]}/tls/server.key
  	- CORE_PEER_TLS_ROOTCERT_FILE=$CLI_CRYPTO_CONFIG_DIR/peerOrganizations/${org_info[1]}/peers/peer0.${org_info[1]}/tls/ca.crt
  	- CORE_PEER_MSPCONFIGPATH=$CLI_CRYPTO_CONFIG_DIR/peerOrganizations/${org_info[1]}/users/Admin@${org_info[1]}/msp
	working_dir: $CLI_WORKING_DIR
	command: /bin/bash
	volumes:
    	- /var/run/:/host/var/run/
    	- $CHAINCODE_DIR:$CLI_CHAINCODE_DIR
    	- $CRYPTO_CONFIG_DIR:$CLI_CRYPTO_CONFIG_DIR
    	- $CHANNEL_ARTIFACTS_DIR:$CLI_CHANNEL_ARTIFACTS_DIR
    	- ./scripts:/opt/gopath/src/github.com/hyperledger/fabric/peer/scripts/
	networks:
  	`gen_networks_container cli.${BL_DOMAIN} "    	"`
	`gen_extra_host $(get_host_id cli) "	"`
EOF
} #}}}

gen_channel_artifacts()
{ #{{{
	local org org_info ch ch_profile ch_name

	[ -d $CHANNEL_ARTIFACTS_DIR ] || mkdir $CHANNEL_ARTIFACTS_DIR

	export FABRIC_CFG_PATH=$PWD
	configtxgen -profile $ORDERER_GENESIS_PROFILE -outputBlock ./$CHANNEL_ARTIFACTS_DIR/genesis.block

	for ((ch=1; ch<=CHANNELS; ch++)) ; do
    	ch_profile=`get_channel_info ${ch} PROFILE`
    	ch_name=`get_channel_info ${ch} NAME`
    	configtxgen -profile $ch_profile -outputCreateChannelTx ./$CHANNEL_ARTIFACTS_DIR/channel${ch}.tx -channelID $ch_name

    	for ((org=1; org<=ORGS; org++)) ; do
        	eval "org_info=(\$ORG${org}_INFO)"
        	configtxgen -profile $ch_profile -outputAnchorPeersUpdate ./$CHANNEL_ARTIFACTS_DIR/ch${ch}${org_info[0]}MSPanchors.tx -channelID $ch_name -asOrg ${org_info[0]}MSP
    	done
	done

} #}}}

gen_certs()
{ #{{{
	cryptogen generate --config=$CRYPTO_CONFIG_FILE
} #}}}

gen_config()
{ #{{{
	[ -f $CRYPTO_CONFIG_FILE ] && {
    	err "crypto config file existing!" >&2
    	return 1
	}
	[ -f $CONFIGTX_FILE ] && {
    	err "configtx file existing!" >&2
    	return 1
	}
	[ -d $CRYPTO_CONFIG_DIR ] && {
    	err "crypto config dir $CRYPTO_CONFIG_DIR existing!" >&2
    	return 1
	}
	[ -d $CHANNEL_ARTIFACTS_DIR ]  && {
    	err "channel artifacts dir $CHANNEL_ARTIFACTS_DIR existing!" >&2
    	return 1
	}
	[ -f $DOCKER_COMPOSE_FILE ] && {
    	err "docker compose file existing!" >&2
    	return 1
	}

	msg "generate crypto config file..."
	gen_crypto_config || {
    	err "generate crypto config file failed!" >&2
    	return 1
	}

	msg "generate configtx file..."
	gen_configtx || {
    	err "generate configtx file failed!" >&2
    	return 1
	}

	msg "generate crypto certificates..."
	gen_certs || {
    	err "generate crypto certificates failed!" >&2
    	return 1
	}

	msg "generate channel artifacts..."
	gen_channel_artifacts || {
    	err "generate channel artifacts failed!" >&2
    	return 1
	}

	msg "generate docker compose file..."
	gen_docker_compose_file || {
    	err "generate docker compose file failed!" >&2
    	return 1
	}

} #}}}

clean_config()
{ #{{{
	[ -f $CRYPTO_CONFIG_FILE ] && rm -f $CRYPTO_CONFIG_FILE
	[ -f $CONFIGTX_FILE ] && rm -f $CONFIGTX_FILE
	[ -d $CHANNEL_ARTIFACTS_DIR ] && rm -fr $CHANNEL_ARTIFACTS_DIR
	[ -d $CRYPTO_CONFIG_DIR ] && rm -fr $CRYPTO_CONFIG_DIR
	[ -f $DOCKER_COMPOSE_FILE ] && rm -f $DOCKER_COMPOSE_FILE
	:
} #}}}

################################################################################

create_channel()
{ #{{{
	local ch ch_name
	local orderer_addr=`get_domain_name orderer`:`get_connect_port cli orderer`

	for ((ch=1; ch<=CHANNELS; ch++)) ; do
    	echo "$ch total :$CHANNELS"
    	ch_name=`get_channel_info ${ch} NAME`
    	docker exec -i cli.$BL_DOMAIN bash -c \
        	"peer channel create -o $orderer_addr -c $ch_name -f $CLI_CHANNEL_ARTIFACTS_DIR/channel${ch}.tx --tls \$CORE_PEER_TLS_ENABLED --cafile `CLI_ORDERER_TLSCA`"
	done
} #}}}

join_channel()
{ #{{{
	local org peer env org_info ch ch_name ch_peers retries=0 result

	for ((ch=1; ch<=CHANNELS; ch++)) ; do
    	ch_name=`get_channel_info ${ch} NAME`
    	ch_peers=`get_channel_info ${ch} PEERS`

    	for peer in $ch_peers ; do
        	org=${peer#*.}
        	org=${org##*[^0-9]}
        	peer=${peer%.*}
        	peer=${peer##*[^0-9]}
        	eval "org_info=(\$ORG${org}_INFO)"

        	env="-e CORE_PEER_ADDRESS=peer$peer.${org_info[1]}:`get_connect_port cli "peer $peer $org"`"
        	env="-e CORE_PEER_LOCALMSPID=${org_info[0]}MSP $env"
        	env="-e CORE_PEER_TLS_ROOTCERT_FILE=$CLI_CRYPTO_CONFIG_DIR/peerOrganizations/${org_info[1]}/peers/peer$peer.${org_info[1]}/tls/ca.crt $env"
        	env="-e CORE_PEER_MSPCONFIGPATH=$CLI_CRYPTO_CONFIG_DIR/peerOrganizations/${org_info[1]}/users/Admin@${org_info[1]}/msp $env"

        	retries=0
        	while [ $retries -lt 5 ] ; do
set -x
            	docker exec -i $env cli.$BL_DOMAIN peer channel join -b $ch_name.block
            	result=$?
set +x
            	[ $result = 0 ] && break
            	((retries++))
            	sleep $CLI_DELAY
        	done
       	 
    	done
	done
} #}}}

update_anchor_peers()
{ #{{{
	local org peer=0 env org_info ch_name orderer_addr

	for ((org=1; org<=ORGS; org++)) ; do
    	eval "org_info=(\$ORG${org}_INFO)"
    	env="-e CORE_PEER_ADDRESS=peer$peer.${org_info[1]}:`get_connect_port cli "peer $peer $org"`"
    	env="-e CORE_PEER_LOCALMSPID=${org_info[0]}MSP $env"
    	env="-e CORE_PEER_TLS_ROOTCERT_FILE=$CLI_CRYPTO_CONFIG_DIR/peerOrganizations/${org_info[1]}/peers/peer$peer.${org_info[1]}/tls/ca.crt $env"
    	env="-e CORE_PEER_MSPCONFIGPATH=$CLI_CRYPTO_CONFIG_DIR/peerOrganizations/${org_info[1]}/users/Admin@${org_info[1]}/msp $env"

    	orderer_addr=`get_domain_name orderer`:`get_connect_port cli orderer`

    	for ((ch=1; ch<=CHANNELS; ch++)) ; do
        	ch_name=`get_channel_info ${ch} NAME`
        	local anchors_file="$CLI_CHANNEL_ARTIFACTS_DIR/ch${ch}${org_info[0]}MSPanchors.tx"
set -x
        	docker exec -i $env cli.$BL_DOMAIN bash -c \
            	"peer channel update -o $orderer_addr -c $ch_name -f $anchors_file --tls \$CORE_PEER_TLS_ENABLED --cafile `CLI_ORDERER_TLSCA`"
set +x
    	done
	done
} #}}}

install_chaincode()
{ #{{{
	local org peer env org_info cli_cc_path=$CLI_CHAINCODE_DIR
	[ $CHAINCODE_LANG = golang ] && cli_cc_path=${CLI_CHAINCODE_DIR#/opt/gopath/src/}

	for ((org=1; org<=ORGS; org++)) ; do
    	eval "org_info=(\$ORG${org}_INFO)"
    	for ((peer=0; peer<org_info[2]; peer ++)) ; do
        	env="-e CORE_PEER_ADDRESS=peer$peer.${org_info[1]}:`get_connect_port cli "peer $peer $org"`"
        	env="-e CORE_PEER_LOCALMSPID=${org_info[0]}MSP $env"
        	env="-e CORE_PEER_TLS_ROOTCERT_FILE=$CLI_CRYPTO_CONFIG_DIR/peerOrganizations/${org_info[1]}/peers/peer$peer.${org_info[1]}/tls/ca.crt $env"
        	env="-e CORE_PEER_MSPCONFIGPATH=$CLI_CRYPTO_CONFIG_DIR/peerOrganizations/${org_info[1]}/users/Admin@${org_info[1]}/msp $env"
set -x
        	docker exec -i $env cli.$BL_DOMAIN peer chaincode install -n $CHAINCODE_NAME -v $CHAINCODE_VER -l $CHAINCODE_LANG -p $cli_cc_path/$CHAINCODE_LANG/
set +x
        	sleep $CLI_DELAY
    	done
	done
} #}}}

instantiate_chaincode()
{ #{{{
	local org peer env org_info policy policy_list ch ch_name ch_peers
	local orderer_addr=`get_domain_name orderer`:`get_connect_port cli orderer`

	for ((exc=1; exc<=ORGS; exc++)) ; do
    	policy=
    	for ((org=1; org<=ORGS; org++)) ; do
        	[ $org = $exc -a $ORGS -gt 1 ] && continue
        	eval "org_info=(\$ORG${org}_INFO)"
        	policy="$policy${policy:+,}'${org_info[0]}MSP.peer'"
    	done
    	[ $ORGS -gt 1 ] && policy_list="${policy_list}${policy_list:+,} AND ($policy)" || policy_list=$policy
	done
	[ $ORGS -gt 1 ] && policy_list="OR ($policy_list)" || policy_list="AND ($policy_list)"

	for ((ch=1; ch<=CHANNELS; ch++)) ; do
    	ch_name=`get_channel_info ${ch} NAME`
    	ch_peers=`get_channel_info ${ch} PEERS`

    	for peer in $ch_peers ; do
        	org=${peer#*.}
        	org=${org##*[^0-9]}
        	peer=${peer%.*}
        	peer=${peer##*[^0-9]}
        	eval "org_info=(\$ORG${org}_INFO)"

        	env="-e CORE_PEER_ADDRESS=peer$peer.${org_info[1]}:`get_connect_port cli "peer $peer $org"`"
        	env="-e CORE_PEER_LOCALMSPID=${org_info[0]}MSP $env"
        	env="-e CORE_PEER_TLS_ROOTCERT_FILE=$CLI_CRYPTO_CONFIG_DIR/peerOrganizations/${org_info[1]}/peers/peer$peer.${org_info[1]}/tls/ca.crt $env"
        	env="-e CORE_PEER_MSPCONFIGPATH=$CLI_CRYPTO_CONFIG_DIR/peerOrganizations/${org_info[1]}/users/Admin@${org_info[1]}/msp $env"
set -x
        	docker exec -i $env cli.$BL_DOMAIN \
            	peer chaincode instantiate -o $orderer_addr \
                	--tls $PEER_TLS_ENABLED --cafile `CLI_ORDERER_TLSCA` -C $ch_name \
                	-n $CHAINCODE_NAME -l $CHAINCODE_LANG -v $CHAINCODE_VER -c '{"Args":["init","a","100","b","200"]}' -P "$policy_list"
set +x
        	break
    	done
	done
} #}}}


# --peer=... --org=... --channel=... func arg1 arg2...
query_chaincode()
{ #{{{
	local peer=0 org=1 channel=1 arg env org_info ch_name
	while [ $# -gt 0 ] ; do
    	case "$1" in
    	--peer=?*|--org=?*|--channel=?*)
        	eval "${1#--}"
        	;;
    	-?*)
        	msg "usage: $FUNCNAME [--peer=[0]] [--org=[1]] [--channel=[1]] func arg1 arg2..."
        	exit 1
        	;;
    	*)
        	arg="$arg${arg:+,}\"$1\""
        	;;
    	esac
    	shift
	done

	arg="{\"Args\":[$arg]}"

	ch_name=`get_channel_info ${channel} NAME`
	eval "org_info=(\$ORG${org}_INFO)"

	env="-e CORE_PEER_ADDRESS=peer$peer.${org_info[1]}:`get_connect_port cli "peer $peer $org"`"
	env="-e CORE_PEER_LOCALMSPID=${org_info[0]}MSP $env"
	env="-e CORE_PEER_TLS_ROOTCERT_FILE=$CLI_CRYPTO_CONFIG_DIR/peerOrganizations/${org_info[1]}/peers/peer$peer.${org_info[1]}/tls/ca.crt $env"
	env="-e CORE_PEER_MSPCONFIGPATH=$CLI_CRYPTO_CONFIG_DIR/peerOrganizations/${org_info[1]}/users/Admin@${org_info[1]}/msp $env"
set -x
	docker exec -i $env cli.$BL_DOMAIN peer chaincode query -C $ch_name -n $CHAINCODE_NAME -c "$arg"
set +x
} #}}}

# --channel=... func arg1 arg2...
invoke_chaincode()
{ #{{{
	local peer org channel=1 arg= org_info ch_name
	local orderer_addr=`get_domain_name orderer`:`get_connect_port cli orderer`
	local peer_addr peer_tlsca
	local peer_params
	local -A orgs

	while [ $# -gt 0 ] ; do
    	case "$1" in
    	--channel=?*)
        	eval "${1#--}"
        	;;
    	-?*)
        	msg "usage: XXX [--channel=[1] func arg1 arg2..."
        	exit 1
        	;;
    	*)
        	arg="$arg${arg:+,}\"$1\""
        	;;
    	esac
    	shift
	done

	arg="{\"Args\":[$arg]}"

	ch_name=`get_channel_info ${channel} NAME`
	ch_peers=`get_channel_info ${channel} PEERS`

	for peer in $ch_peers ; do
    	org=${peer#*.}
    	org=${org##*[^0-9]}
    	peer=${peer%.*}
    	peer=${peer##*[^0-9]}

    	[ -n "${orgs[$org]}" ] && continue

    	orgs[$org]=$peer
	done

	for org in ${!orgs[@]} ; do
    	eval "org_info=(\$ORG${org}_INFO)"
    	peer=${orgs[$org]}

    	peer_addr=peer$peer.${org_info[1]}:`get_connect_port cli "peer $peer $org"`
    	peer_tlsca=`CLI_PEER_TLSCA $peer $org`

    	peer_params="$peer_params${peer_params:+ }--peerAddresses $peer_addr --tlsRootCertFiles $peer_tlsca"
	done

set -x
	docker exec -i cli.$BL_DOMAIN peer chaincode invoke \
    	-o $orderer_addr --tls $PEER_TLS_ENABLED --cafile `CLI_ORDERER_TLSCA` \
    	-C $ch_name -n $CHAINCODE_NAME $peer_params \
    	-c "$arg"
set +x
} #}}}

# --peer=... --org=... --cmd=...
run_cli_cmd()
{ #{{{
	local peer=0 org=1 cmd env org_info
	while [ $# -gt 0 ] ; do
    	case "$1" in
    	--peer=?*|--org=?*)
        	eval "${1#--}"
        	;;
    	--cmd=?*)
        	cmd=${1#*=}
        	;;
    	esac
    	shift
	done

	eval "org_info=(\$ORG${org}_INFO)"
	env="-e CORE_PEER_ADDRESS=peer$peer.${org_info[1]}:`get_connect_port cli "peer $peer $org"`"
	env="-e CORE_PEER_LOCALMSPID=${org_info[0]}MSP $env"
	env="-e CORE_PEER_TLS_ROOTCERT_FILE=$CLI_CRYPTO_CONFIG_DIR/peerOrganizations/${org_info[1]}/peers/peer$peer.${org_info[1]}/tls/ca.crt $env"
	env="-e CORE_PEER_MSPCONFIGPATH=$CLI_CRYPTO_CONFIG_DIR/peerOrganizations/${org_info[1]}/users/Admin@${org_info[1]}/msp $env"
set -x
	docker exec -i $env cli.$BL_DOMAIN $cmd
set +x
} #}}}

################################################################################

OP=
HOST_ID=

RC_FILE=~/.fabricrc

do_deploy()
{ #{{{
	local dockers docker org_info
	local ups

	[ -z "$HOST_ID" ] && {
    	usage
    	exit 1
	}

	[ ! -d $CRYPTO_CONFIG_DIR -o ! -d $CHANNEL_ARTIFACTS_DIR -o ! -f $CONFIGTX_FILE -o ! -f $DOCKER_COMPOSE_FILE ] && {
    	err "configuration not generated!"
    	exit 1
	}

	eval "dockers=\$HOST${HOST_ID}_DOCKERS"
	for docker in $dockers ; do
    	type=${docker%%[0-9.]*}

    	case $type in
    	orderer|cli)
        	ups="$ups $type.$BL_DOMAIN"
        	;;
    	peer|couchdb)
        	peer=${docker%%.*}
        	peer=${peer##*[^0-9]}
        	org=${docker##*.}
        	org=${org##*[^0-9]}
        	eval "org_info=(\$ORG${org}_INFO)"
        	ups="$ups $type$peer.${org_info[1]}"
        	;;
    	ca)
        	org=${docker##*.}
        	org=${org##*[^0-9]}
        	eval "org_info=(\$ORG${org}_INFO)"
        	ups="$ups $type.${org_info[1]}"
        	;;
    	esac
	done

	msg "bringing up dockers..."
	[ $NETWORK_MODE = swarm ] && \
	docker-compose -f $DOCKER_COMPOSE_FILE up -d $ups


	[ $HOST_ID = `get_host_id cli` ] && {
    	msg "creating channel..."
    	create_channel

    	msg "joining channel..."
    	join_channel

    	msg "updating anchor peer..."
    	update_anchor_peers

    	msg "installing chaincode..."
    	install_chaincode

    	msg "instantiating chaincode..."
    	instantiate_chaincode

    	msg "all done!"
	}
} #}}}

do_undeploy()
{ #{{{
	docker-compose -f $DOCKER_COMPOSE_FILE down --volumes --remove-orphans

	local CONTAINER_IDS=$(docker ps -a | awk '($2 ~ /dev-peer.*.'$CHAINCODE_NAME'.*/) {print $1}')
	if [ -n "${CONTAINER_IDS// /}" ]; then
    	docker rm -f $CONTAINER_IDS
	fi

	local DOCKER_IMAGE_IDS=$(docker images | awk '($1 ~ /dev-peer.*.'$CHAINCODE_NAME'.*/) {print $3}')
	if [ -n "${DOCKER_IMAGE_IDS// /}" ]; then
    	docker rmi -f $DOCKER_IMAGE_IDS
	fi
} #}}}

do_generate()
{
	echo $CONFIG_FILE >.config
	gen_config
}

do_clean()
{
	clean_config
}

usage()
{
	msg "$0 generate --config=FILE | clean | deploy --host-id=[1|2..] | undeploy"
}

case $1 in
generate|clean|deploy|undeploy)
	OP=$1
	;;
-*)
	usage
	exit 1
	;;
*)
	[ "$(type -t $1)" != function ] && {
    	err "unknown op $1" >&2
    	exit 1
	}
	[ -f .config ] && read CONFIG_FILE <.config || CONFIG_FILE=$DEFAULT_CONFIG_FILE
	. $CONFIG_FILE
	cmd=
	for ((i=1;i<=$#;i++)) ; do
    	cmd="$cmd${cmd:+ }\"\$$i\""
	done
	eval "$cmd"
	exit
esac
shift

for arg in $* ; do
	case $arg in
	--host-id=?*)
    	HOST_ID=${arg#*=}
    	;;
	--config=?*)
    	CONFIG_FILE=${arg#*=}
    	;;
	*)
    	err "unknown parameter $arg" >&2
    	exit 1
	esac
done

[ -z "$CONFIG_FILE" ] && {
	[ -f .config ] && read CONFIG_FILE <.config || CONFIG_FILE=$DEFAULT_CONFIG_FILE
}

[ -f "$CONFIG_FILE" ] || {
	err "config file $CONFIG_FILE not existing!"
	exit 1
}

. $CONFIG_FILE

check || exit
do_$OP
