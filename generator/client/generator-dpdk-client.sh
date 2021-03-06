#!/bin/bash -x
# set -o errexit

# Install dir
BUILD_DIR=${BUILD_DIR:-/root}
DPDK_INSTALL_DIR=${DPDK_INSTALL_DIR, ${BUILD_DIR}/dpdk/x86_64-native-linuxapp-gcc}
ODP_INSTALL_DIR=${ODP_INSTALL_DIR:-${BUILD_DIR}/install_dir}
RUN_DIR=${RUN_DIR:-.}

# name of the VLAND used
VLAND_NAME=${VLAND_NAME:-vlan_one}

# IP addresses
LOCAL_IP=${LOCAL_IP:-"192.168.100.2"}
REMOTE_IP=${REMOTE_IP:-"192.168.100.1"}

# UDP ports
LOCAL_PORT=${LOCAL_PORT:-5001}
REMOTE_PORT=${REMOTE_PORT:-5000}

# Cores mask
CORES_MASK=${CORES_MASK:-"0x8"}

# Packet Count
PACKET_CNT=${PACKET_CNT:-600000000}

# Echo parameters
echo "BUILD_DIR = ${BUILD_DIR}"
echo "ODP_INSTALL_DIR = ${ODP_INSTALL_DIR}"
echo "DPDK_INSTALL_DIR = ${DPDK_INSTALL_DIR}"
echo "RUN_DIR = ${RUN_DIR}"

echo "VLAND_NAME = ${VLAND_NAME}"

echo "LOCAL_IP = ${LOCAL_IP}"
echo "REMOTE_IP = ${REMOTE_IP}"

echo "LOCAL_PORT = ${LOCAL_PORT}"
echo "REMOTE_PORT = ${REMOTE_PORT}"

echo "CORES_MASK = ${CORES_MASK}"

echo "PACKET_CNT= ${PACKET_CNT}"
echo "PKTIO= ${PKTIO}"

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

# Setup DPDK
sysctl -w vm.nr_hugepages=1024
sh -c 'echo 1024 > /sys/devices/system/node/node0/hugepages/hugepages-2048kB/nr_hugepages' || true
mkdir ${RUN_DIR}/huge || true
mount -t hugetlbfs nodev ${RUN_DIR}/huge || true

depmod
modprobe uio
insmod ${DPDK_INSTALL_DIR}/kmod/igb_uio.ko || true

# Setup DPDK interface
dev=$(what_vland_interface ${VLAND_NAME})
echo "dev = ${dev}"

# DEV_PCI=`${BUILD_DIR}/dpdk/usertools/dpdk-devbind.py --status | grep $dev | awk '{print $1}'`
# echo "DEV_PCI = ${DEV_PCI}"

LOCAL_MAC=$(what_vland_MAC ${VLAND_NAME})
echo "LOCAL_MAC = ${LOCAL_MAC}"


echo ">> SEND client_ready"
lava-send client_ready
echo "<< Wait server_ready"
lava-wait server_ready

ifconfig ${dev} 1.1.1.2 up
ping -c 30 1.1.1.1
ifconfig -a

if [ "${PKTIO}" = "dpdk" ]; then
	depmod
	lsmod
	modprobe uio
	insmod ${DPDK_INSTALL_DIR}/kmod/igb_uio.ko || true

	ifconfig ${dev} down
	# Setup DPDK interface
	DEV_PCI=`${BUILD_DIR}/dpdk/usertools/dpdk-devbind.py --status | grep $dev | awk '{print $1}'`
	echo "DEV_PCI = ${DEV_PCI}"

	${BUILD_DIR}/dpdk/usertools/dpdk-devbind.py -u ${DEV_PCI}
	${BUILD_DIR}/dpdk/usertools/dpdk-devbind.py --bind=igb_uio ${DEV_PCI}
	${BUILD_DIR}/dpdk/usertools/dpdk-devbind.py -s
	${BUILD_DIR}/dpdk/usertools/dpdk-devbind.py --status
	dev="0"
elif [ "${PKTIO}" = "socket" ]; then
	export ODP_PKTIO_DISABLE_DPDK=1
else
	echo "UNKNOWN PKTIO ${PKTIO}"
	ifconfig ${dev} up
fi

REMOTE_MAC=$(cat /tmp/lava_multi_node_cache.txt | cut -d = -f 2)
echo "REMOTE_MAC = ${REMOTE_MAC}"
if [ "${REMOTE_MAC}" = "" ]; then
	cat /tmp/lava_multi_node_cache.txt || true
	ifconfig -a
	REMOTE_MAC="11:22:33:44:55:66"
	echo "Using fake REMOTE_MAC = ${REMOTE_MAC}"
fi

echo "Test start..."
GEN_UDP_TX_BURST_SIZE=512
echo taskset 0xfe ${ODP_INSTALL_DIR}/bin/odp_generator -I $dev --srcmac ${LOCAL_MAC} --dstmac ${REMOTE_MAC} \
                --srcip ${LOCAL_IP} --dstip ${REMOTE_IP} -m u -i 0 -c ${CORES_MASK} -p 18 \
                -e ${LOCAL_PORT} -f ${REMOTE_PORT} -n ${PACKET_CNT} -x ${GEN_UDP_TX_BURST_SIZE}

dmesg -c > /dev/null

echo "<< Wait server_start_generator"
lava-send  client_start_generator
lava-wait  server_start_generator


export ODP_PKTIO_DPDK_PARAMS="-m 1024"
taskset 0xfe ${ODP_INSTALL_DIR}/bin/odp_generator -I $dev --srcmac ${LOCAL_MAC} --dstmac ${REMOTE_MAC} \
                --srcip ${LOCAL_IP} --dstip ${REMOTE_IP} -m u -i 0 -c ${CORES_MASK} -p 18 \
                -e ${LOCAL_PORT} -f ${REMOTE_PORT} -n ${PACKET_CNT} -x ${GEN_UDP_TX_BURST_SIZE} 2>&1 |tee  /tmp/generator_client.data

MAX_SEND_RATE=`cat /tmp/generator_client.data | grep "max send rate:" | tail -n 1 | awk '{print $12}'`
echo "MAX_SEND_RATE = ${MAX_SEND_RATE}"

cat /tmp/generator_client.data
dmesg

git clone https://github.com/muvarov/odp_perf_reports.git
python odp_perf_reports/odpt_add_result.py generator-${ODP_BRANCH} TX $MAX_SEND_RATE
pushd /root/odp
GIT_COMMIT=`git log -1 --format="%H"`
popd
python odp_perf_reports/odpt_post_results.py \
	http://muvarov.ddns.net:5000/githubemail/testresults.py \
	${GIT_COMMIT} Maxim


echo ">> SEND client_done"
lava-send client_done

echo "<< Wait server_done"
lava-wait server_done

echo "A10"
