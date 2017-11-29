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

# what_vland_interface
# returns ethX assigned to VLAND_NAME
function what_vland_interface {
	ls $(what_vland_sys_path $1)
}

if ! which lava-wait &>/dev/null; then
	echo "This script must be executed in LAVA"
	exit
fi

sysctl -w vm.nr_hugepages=1024
sh -c 'echo 1024 > /sys/devices/system/node/node0/hugepages/hugepages-2048kB/nr_hugepages' || true
mkdir ${RUN_DIR}/huge || true
mount -t hugetlbfs nodev ${RUN_DIR}/huge || true

dev=$(what_vland_interface ${VLAND_NAME})
echo "dev = ${dev}"

LOCAL_MAC=$(what_vland_MAC ${VLAND_NAME})
echo "LOCAL_MAC = ${LOCAL_MAC}"

if [ "${PKTIO}" = "dpdk" ]; then
	# Setup DPDK
	depmod
	modprobe uio
	insmod ${DPDK_INSTALL_DIR}/kmod/igb_uio.ko || true

	# Setup DPDK interface
	DEV_PCI=`${BUILD_DIR}/dpdk/usertools/dpdk-devbind.py --status | grep $dev | awk '{print $1}'`
	echo "DEV_PCI = ${DEV_PCI}"

	${BUILD_DIR}/dpdk/usertools/dpdk-devbind.py -u ${DEV_PCI}
	dev="0"
elif [ "${PKTIO}" = "socket" ]; then
	ifconfig ${dev} 1.1.1.1 up
	export ODP_PKTIO_DISABLE_DPDK=1
	ifconfig -a
else
	echo "UNKNOWN PKTIO ${PKTIO}"
	ifconfig $dev up
fi

echo "<< WAIT client_ready"
lava-wait client_ready

ping -c 30 1.1.1.2

echo "Test start..."
cd ${RUN_DIR}

echo ${ODP_INSTALL_DIR}/bin/odp_generator -I $dev -m r -c ${CORES_MASK}
echo ">> SEND server_start_generator"
lava-send  server_start_generator

taskset 0xff ${ODP_INSTALL_DIR}/bin/odp_generator -I $dev -m r -c ${CORES_MASK} |tee /tmp/app.data &
echo $! > /tmp/app.pid

echo ">> SEND server_ready"
lava-send server_ready peer_mac=${LOCAL_MAC}

echo "<< WAIT client_done"
lava-wait client_done

sync || true
kill -9 `cat /tmp/app.pid`

RESULT=`cat /tmp/app.data | tail -n 1  | grep "sent:"`
RESULT_RATE=`echo $RESULT | awk '{print $23}'`
RESULT_UNIT=`echo $RESULT | awk '{print $24}'`

ifconfig -a

lava-test-case RX_rate --result pass --measurement $RESULT_RATE --units $RESULT_UNIT

echo ">> SEND server_done"
lava-send server_done
echo "A10"
