#!/bin/bash -x
# set -o errexit

# Install dir
BUILD_DIR=${BUILD_DIR:-/root}
echo "BUILD_DIR = ${BUILD_DIR}"
ODP_INSTALL_DIR=${ODP_INSTALL_DIR:-${BUILD_DIR}/install_dir}
echo "ODP_INSTALL_DIR = ${ODP_INSTALL_DIR}"
DPDK_INSTALL_DIR=${DPDK_INSTALL_DIR, ${BUILD_DIR}/dpdk/x86_64-native-linuxapp-gcc}
echo "DPDK_INSTALL_DIR = ${DPDK_INSTALL_DIR}"
RUN_DIR=${RUN_DIR:-.}
echo "RUN_DIR = ${RUN_DIR}"

# name of the VLAND used
VLAND_NAME=${VLAND_NAME:-vlan_one}
echo "VLAND_NAME = ${VLAND_NAME}"

# Cores mask
CORES_MASK=${CORES_MASK:-0x4}
echo "CORES_MASK = ${CORES_MASK}"

function exit_error {
	echo "-- SERVER ERROR"
	lava-test-case server_up --status fail
}
trap exit_error ERR

function what_vland_entry {
	lava-vland-names | grep "^$1" | cut -d , -f 2
}

function what_vland_sys_path {
	lava-vland-self | grep "$(what_vland_entry $1)" | cut -d , -f 3
}

function what_vland_MAC {
        lava-vland-self | grep "$(what_vland_entry $1)" | cut -d , -f 2
}

dev=$(what_vland_interface ${VLAND_NAME})
echo "dev = ${dev}"

LOCAL_MAC=$(what_vland_MAC ${VLAND_NAME})
echo "LOCAL_MAC = ${LOCAL_MAC}"


if [ "${PKTIO}" = "dpdk" ]; then
	dev="0"
elif [ "${PKTIO}" = "socket" ]; then
	export ODP_PKTIO_DISABLE_DPDK=1
else
	echo "UNKNOWN PKTIO ${PKTIO}"
	ifconfig $dev up
fi

echo "Test start..."
cd ${RUN_DIR}

echo ${ODP_INSTALL_DIR}/bin/odp_generator -I $dev -m r -c ${CORES_MASK}
echo ">> SEND server_start_generator"

GEN_UDP_TX_BURST_SIZE=4096
taskset 0xfe ${ODP_INSTALL_DIR}/bin/odp_generator -I $dev -m r -c ${CORES_MASK} -x {GEN_UDP_TX_BURST_SIZE}|tee /tmp/app.data &
#taskset 0xfe ${ODP_INSTALL_DIR}/bin/odp_l2fwd -i $dev |tee /tmp/app.data &
echo $! > /tmp/app.pid

echo "<< WAIT client_done"
lava-wait client_done

sync || true
kill -9 `cat /tmp/app.pid`

RESULT=`cat /tmp/app.data | tail -n 1  | grep "sent:"`
RESULT_RATE=`echo $RESULT | awk '{print $23}'`
RESULT_UNIT=`echo $RESULT | awk '{print $24}'`


git clone https://github.com/muvarov/odp_perf_reports.git
python odp_perf_reports/odpt_add_result.py generator RX $RESULT_RATE
GIT_COMMIT=`git log -1 --format="%H"`
python odp_perf_reports/odpt_post_results.py \
	http://localhost:5000/githubemail/testresults.py \
	$GIT_COMMIT Maxim

ifconfig -a

lava-test-case RX_rate --result pass --measurement $RESULT_RATE --units $RESULT_UNIT
