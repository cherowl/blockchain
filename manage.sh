#!/bin/bash
SSH_KEY=~/ygn_ihpc_key.pem
HOSTS=( 172.20.98.137
    	172.20.98.138
    	172.20.98.149
    	172.20.98.150
)

CLIENTS=( 172.20.98.137
    	172.20.98.138
    	172.20.98.149
    	172.20.98.150
)


USER_TYPE=eugene

START_RPS=100
END_RPS=200
STEP_RPS=20

START_CONCURRENT_SERIALS=4
END_CONCURRENT_SERIALS=7
STEP_CONCURRENT_SERIALS=1

UBUNTU_CLIENT_INSTRUCTIONS='sudo apt install -y git python sysstat;
sudo apt-get install build-essential;
curl -o- https://raw.githubusercontent.com/creationix/nvm/v0.34.0/install.sh | bash;
export NVM_DIR="$HOME/.nvm";
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh";
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion";
nvm install --lts=carbon;
node --version;
cd bus-trip;
npm i;'

UBUNTU_HOST_INSTRUCTIONS='sudo apt install -y docker git go python sysstat;
sudo usermod -aG docker $USER;
sudo su $USER;
sudo service docker restart;
sudo curl -L "https://github.com/docker/compose/releases/download/1.23.2/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose;
sudo chmod +x /usr/local/bin/docker-compose;
sudo ln -s /usr/local/bin/docker-compose /usr/bin/docker-compose;
sudo su $USER;
curl -sSL http://bit.ly/2ysbOFE | bash -s 1.3.0;
echo "export PATH=$PWD/fabric-samples/bin:$PATH" >> ~/.bashrc;
source ~/.bashrc;
docker --version;
docker-compose --version;
go version;
peer version;
fabric-ca-client version;'

RHEL_CLIENT_INSTRUCTIONS='sudo yum install -y git python sysstat;
sudo yum group install -y "Development Tools";
curl -o- https://raw.githubusercontent.com/creationix/nvm/v0.34.0/install.sh | bash;
export NVM_DIR="$HOME/.nvm";
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh";
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion";
nvm install --lts=carbon;
node --version;
cd bus-trip;
npm i;'

RHEL_HOST_INSTRUCTIONS='sudo yum install -y docker git go python sysstat;
sudo usermod -aG docker $USER;
sudo su $USER;
sudo service docker restart;
sudo curl -L "https://github.com/docker/compose/releases/download/1.23.2/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose;
sudo chmod +x /usr/local/bin/docker-compose;
sudo ln -s /usr/local/bin/docker-compose /usr/bin/docker-compose;
sudo su $USER;
curl -sSL http://bit.ly/2ysbOFE | bash -s 1.3.0;
echo "export PATH=$PWD/fabric-samples/bin:$PATH" >> ~/.bashrc;
source ~/.bashrc;
docker --version;
docker-compose --version;
go version;
peer version;
fabric-ca-client version;'



change_user_number()
{
	sed -i "s/'user[[:digit:]]'/'user$1'/g" test/test.js
	echo "user Changed to $1"
}

change_channel_numbers()
{
	sed -i "s/CHANNELS=[[:digit:]]*/CHANNELS=$1/" config/4org.js
	echo "CHANNELS Changed to $1"
}

change_tps()
{
	sed -i "s/TEST_TARGET_TPS[[:space:]]=[[:space:]][[:digit:]]*;/TEST_TARGET_TPS = $1;/" test/test.js
	echo "TPS Changed to $1"
}


change_concurrent_serials()
{
	sed -i "s/TEST_CONCURRENT_SERIALS[[:space:]]=[[:space:]]TEST_CHANNELS.length[[:space:]]\*[[:space:]][[:digit:]]*;/TEST_CONCURRENT_SERIALS = TEST_CHANNELS.length * $1;/" test/test.js
	echo "Concurrent serials changed to $1"
}


setup()
{
	for host in ${HOSTS[@]} ${CLIENTS[@]} ; do
    	ssh -o "StrictHostKeyChecking no" -i $SSH_KEY $USER_TYPE@$host mkdir "bus-trip" &
	done
	wait
	upload
	if [[ $USER_TYPE == 'ubuntu' ]]; then
    	for host in ${HOSTS[@]} ; do
        	ssh -i $SSH_KEY $USER_TYPE@$host bash -l -c "'$UBUNTU_HOST_INSTRUCTIONS'" &
    	done
    	wait
    	for host in ${CLIENTS[@]} ; do
        	ssh -i $SSH_KEY $USER_TYPE@$host bash -l -c "'$UBUNTU_CLIENT_INSTRUCTIONS'" &
    	done
    	wait
	elif [[ $USER_TYPE == 'ec2-user' ]]; then
    	for host in ${HOSTS[@]} ; do
        	ssh -i $SSH_KEY $USER_TYPE@$host bash -l -c "'$RHEL_HOST_INSTRUCTIONS'" &
    	done
    	wait
    	for host in ${CLIENTS[@]} ; do
        	ssh -i $SSH_KEY $USER_TYPE@$host bash -l -c "'$RHEL_CLIENT_INSTRUCTIONS'" &
    	done
    	wait
	fi
}

undeploy()
{
	for host in ${HOSTS[@]} ; do
    	ssh -o "stricthostkeychecking no" -i $SSH_KEY $USER_TYPE@$host bash -l -c "'cd bus-trip; ./script/fabric undeploy'" &
    	wait
	done
}

deploy()
{
	for ((i=0; i<${#HOSTS[@]}; i++)) ; do
    	[ $i = 0 ] && continue
    	ssh -i $SSH_KEY $USER_TYPE@${HOSTS[$i]} bash -l -c "'cd bus-trip; ./script/fabric deploy --host-id=$((i+1)) $*'"
	done

	for ((i=0; i<${#HOSTS[@]}; i++)) ; do
    	[ $i != 0 ] && continue
    	ssh -i $SSH_KEY $USER_TYPE@${HOSTS[$i]} bash -l -c "'cd bus-trip; ./script/fabric deploy --host-id=$((i+1)) $*'"
	done
}

upload_test()
{
	for ((i=1; i<=${#CLIENTS[@]}; i++)) ; do
    	scp -i $SSH_KEY -r test/ $USER_TYPE@${HOSTS[${i}-1]}:bus-trip/ &
	done
}


enroll_client()
{
	local invoke=false
	for ((i=1; i<=${#CLIENTS[@]}; i++)) ; do
    	ssh -i $SSH_KEY $USER_TYPE@${CLIENTS[${i}-1]} bash -l -c "'cd bus-trip; rm -rf hfc-key-store; node ./client/enrollAdmin.js; node ./client/registerUser.js user$i'"
    	[ $invoke = false ] && ssh -i $SSH_KEY $USER_TYPE@${CLIENTS[${i}-1]} bash -l -c "'cd bus-trip; node ./client/invoke.js user$i'"
    	invoke=true
	done
	wait
}

redeploy()
{
	undeploy
	deploy
	enroll_client
}

clean()
{
	for host in ${HOSTS[@]} ; do
    	ssh -i $SSH_KEY $USER_TYPE@$host bash -l -c "'cd bus-trip; ./script/fabric clean'" &
	done
	wait
	for host in ${CLIENTS[@]} ; do
    	ssh -i $SSH_KEY $USER_TYPE@$host bash -l -c "'cd bus-trip; ./script/fabric clean_config'" &
    	ssh -i $SSH_KEY $USER_TYPE@$host bash -l -c "'cd bus-trip; rm -fr hfc-key-store'" &
	done
	wait
}

launch_resourse_monitors()
{
	echo "Launching system resource monitors..."
	for host in ${HOSTS[@]} ; do
    	ssh -i $SSH_KEY $USER_TYPE@$host bash -l -c "'bash ~/bus-trip/monitoring/monitor.sh'" &
    	echo "$host HOST system resource monitor launched"
	done
	for host in ${CLIENTS[@]} ; do
    	echo "Test started..."
    	ssh -i $SSH_KEY $USER_TYPE@$host bash -l -c "'bash ~/bus-trip/monitoring/monitorClient.sh'" &
    	echo "$host CLIENT system resource monitor launched"
	done
}

stop_resourse_monitors()
{
	for host in ${CLIENTS[@]} ; do
    	ssh -i $SSH_KEY $USER_TYPE@$host bash -l -c "'bash ./bus-trip/monitoring/stopClientMonitor.sh'"
	done
 
	echo "Stopping system resource monitors..."
	for host in ${HOSTS[@]} ; do
    	ssh -i $SSH_KEY $USER_TYPE@$host bash -l -c "'bash ./bus-trip/monitoring/stopMonitor.sh'"
	done
}

start_testing()
{
	echo "Start performance evaluations on client"
	for ((i=1; i<=${#CLIENTS[@]}; i++)) ; do
    	echo "${CLIENTS[${i}-1]} host started"
    	ssh -i $SSH_KEY $USER_TYPE@${CLIENTS[${i}-1]} bash -l -c "'cd ~/bus-trip/; node ./test/test.js user$i channel$i > result.json'" &
	done
	wait
}

copy_test_results()
{
	RPS=$1
	CONCURRENT_SERIALS=$2
	date=`date +"%Y-%m-%d&%T"`
	RESULTS_DIR=monitoring_results/RPS\=$RPS/CONC_SERIALS\=$CONCURRENT_SERIALS/$date
	for host in ${CLIENTS[@]} ; do
    	mkdir -p $RESULTS_DIR/CLIENT$host
    	scp -i $SSH_KEY -r $USER_TYPE@$host:bus-trip/monitoring/*Stat $RESULTS_DIR/CLIENT$host &&
    	scp -i $SSH_KEY -r $USER_TYPE@$host:bus-trip/result.json $RESULTS_DIR/CLIENT$host &&
    	echo "Test data copied from host"
	done

	for host in ${HOSTS[@]} ; do
    	mkdir -p $RESULTS_DIR/HOST$host
    	scp -i $SSH_KEY -r $USER_TYPE@$host:bus-trip/monitoring/*Stat $RESULTS_DIR/HOST$host &&
    	echo "Test data copied from host"
	done
}

upload ()
{
	files=$*
	[ -z "$files" ] && files="* .config"

	for host in ${HOSTS[@]} ${CLIENTS[@]} ; do
    	scp -i $SSH_KEY -r $files $USER_TYPE@$host:bus-trip/ &
	done
	wait
}

start_round_test()
{
	local RPS CONCURRENT_SERIALS
	echo "Values: start_tps = $START_RPS end_tps = $END_RPS step_tps = $STEP_RPS start_con_mul = $START_CONCURRENT_SERIALS end_con_mul = $END_CONCURRENT_SERIALS con_mul_step=$STEP_CONCURRENT_SERIALS"
	for((CONCURRENT_SERIALS=$START_CONCURRENT_SERIALS; CONCURRENT_SERIALS<=END_CONCURRENT_SERIALS; CONCURRENT_SERIALS+=STEP_CONCURRENT_SERIALS)); do
    	change_concurrent_serials $CONCURRENT_SERIALS
    	for((RPS=$START_RPS; RPS<=END_RPS; RPS+=STEP_RPS)); do
        	redeploy && wait
        	change_tps $RPS
        	upload_test &&
        	launch_resourse_monitors
        	start_testing && stop_resourse_monitors
        	copy_test_results $RPS $CONCURRENT_SERIALS
    	done
	done
	echo "TEST ROUND DONE"
}
cmd=$1
shift
case $cmd in
setup)
	func="setup"
	;;

upload)
	func="upload $*"
	;;

start_round_test)
	func="start_round_test"
   ;;

start_test)
	func="start_testing"
   ;;

stop_monitor)
	func="stop_resourse_monitors && wait"
   ;;

enroll)
	func="enroll_client"
	;;

deploy)
	func="deploy"
	;;

undeploy)
	func="undeploy"
	;;

clean)
	func="clean"
	;;

redeploy)
	func="redeploy"
	;;
esac
for arg in $* ; do
	case $arg in
	--start-rps=?*)
    	START_RPS=${arg#*=}
    	;;
	--end-rps=?*)
    	END_RPS=${arg#*=}
    	;;
	--rps-step=?*)
    	STEP_RPS=${arg#*=}
    	;;
	--start-cs=?*)
    	START_CONCURRENT_SERIALS=${arg#*=}
    	;;
	--end-cs=?*)
    	END_CONCURRENT_SERIALS=${arg#*=}
    	;;
	--cs-step=?*)
    	STEP_CONCURRENT_SERIALS=${arg#*=}
    	;;
	esac
done
eval "$func"
